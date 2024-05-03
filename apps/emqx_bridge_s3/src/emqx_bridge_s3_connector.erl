%%--------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_s3_connector).

-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/trace.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("emqx/include/emqx_trace.hrl").
-include_lib("emqx_connector_aggregator/include/emqx_connector_aggregator.hrl").
-include("emqx_bridge_s3.hrl").

-behaviour(emqx_resource).
-export([
    callback_mode/0,
    on_start/2,
    on_stop/2,
    on_add_channel/4,
    on_remove_channel/3,
    on_get_channels/1,
    on_query/3,
    on_batch_query/3,
    on_get_status/2,
    on_get_channel_status/3
]).

-behaviour(emqx_connector_aggreg_delivery).
-export([
    init_transfer_state/2,
    process_append/2,
    process_write/1,
    process_complete/1,
    process_format_status/1,
    process_terminate/1
]).

-behaviour(emqx_template).
-export([lookup/2]).

-type config() :: #{
    access_key_id => string(),
    secret_access_key => emqx_secret:t(string()),
    host := string(),
    port := pos_integer(),
    transport_options => emqx_s3:transport_options()
}.

-type channel_config() :: #{
    bridge_type := binary(),
    parameters := s3_upload_parameters() | s3_aggregated_upload_parameters()
}.

-type s3_upload_parameters() :: #{
    bucket := string(),
    key := string(),
    content := string(),
    acl => emqx_s3:acl()
}.

-type s3_aggregated_upload_parameters() :: #{
    bucket := string(),
    key := string(),
    acl => emqx_s3:acl(),
    aggregation => #{
        time_interval := emqx_schema:duration_s(),
        max_records := pos_integer()
    },
    container := #{
        type := csv,
        column_order => [string()]
    },
    min_part_size := emqx_schema:bytesize(),
    max_part_size := emqx_schema:bytesize()
}.

-type channel_state() :: #{
    bucket := emqx_template:str(),
    key := emqx_template:str(),
    upload_options => emqx_s3_client:upload_options()
}.

-type state() :: #{
    pool_name := resource_id(),
    pool_pid => pid(),
    client_config := emqx_s3_client:config(),
    channels := #{channel_id() => channel_state()}
}.

%%

-spec callback_mode() -> callback_mode().
callback_mode() ->
    always_sync.

%% Management

-spec on_start(_InstanceId :: resource_id(), config()) ->
    {ok, state()} | {error, _Reason}.
on_start(InstId, Config) ->
    PoolName = InstId,
    S3Config = Config#{url_expire_time => 0},
    State = #{
        pool_name => PoolName,
        client_config => emqx_s3_profile_conf:client_config(S3Config, PoolName),
        channels => #{}
    },
    HttpConfig = emqx_s3_profile_conf:http_config(Config),
    _ = ehttpc_sup:stop_pool(PoolName),
    case ehttpc_sup:start_pool(PoolName, HttpConfig) of
        {ok, Pid} ->
            ?SLOG(info, #{msg => "s3_connector_start_http_pool_success", pool_name => PoolName}),
            {ok, State#{pool_pid => Pid}};
        {error, Reason} = Error ->
            ?SLOG(error, #{
                msg => "s3_connector_start_http_pool_fail",
                pool_name => PoolName,
                http_config => HttpConfig,
                reason => Reason
            }),
            Error
    end.

-spec on_stop(_InstanceId :: resource_id(), state()) ->
    ok.
on_stop(InstId, _State = #{pool_name := PoolName}) ->
    case ehttpc_sup:stop_pool(PoolName) of
        ok ->
            ?tp(s3_bridge_stopped, #{instance_id => InstId}),
            ok;
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "s3_connector_http_pool_stop_fail",
                pool_name => PoolName,
                reason => Reason
            }),
            ok
    end.

-spec on_get_status(_InstanceId :: resource_id(), state()) ->
    health_check_status().
on_get_status(_InstId, State = #{client_config := Config}) ->
    case emqx_s3_client:aws_config(Config) of
        {error, Reason} ->
            {?status_disconnected, State, Reason};
        AWSConfig ->
            try erlcloud_s3:list_buckets(AWSConfig) of
                Props when is_list(Props) ->
                    ?status_connected
            catch
                error:{aws_error, {http_error, _Code, _, Reason}} ->
                    {?status_disconnected, State, Reason};
                error:{aws_error, {socket_error, Reason}} ->
                    {?status_disconnected, State, Reason}
            end
    end.

-spec on_add_channel(_InstanceId :: resource_id(), state(), channel_id(), channel_config()) ->
    {ok, state()} | {error, _Reason}.
on_add_channel(_InstId, State = #{channels := Channels}, ChannelId, Config) ->
    ChannelState = start_channel(State, Config),
    {ok, State#{channels => Channels#{ChannelId => ChannelState}}}.

-spec on_remove_channel(_InstanceId :: resource_id(), state(), channel_id()) ->
    {ok, state()}.
on_remove_channel(_InstId, State = #{channels := Channels}, ChannelId) ->
    ok = stop_channel(maps:get(ChannelId, Channels, undefined)),
    {ok, State#{channels => maps:remove(ChannelId, Channels)}}.

-spec on_get_channels(_InstanceId :: resource_id()) ->
    [_ChannelConfig].
on_get_channels(InstId) ->
    emqx_bridge_v2:get_channels_for_connector(InstId).

-spec on_get_channel_status(_InstanceId :: resource_id(), channel_id(), state()) ->
    channel_status().
on_get_channel_status(_InstId, ChannelId, State = #{channels := Channels}) ->
    case maps:get(ChannelId, Channels, undefined) of
        ChannelState = #{} ->
            channel_status(ChannelState, State);
        undefined ->
            ?status_disconnected
    end.

start_channel(_State, #{
    bridge_type := ?BRIDGE_TYPE_UPLOAD,
    parameters := Parameters = #{
        bucket := Bucket,
        key := Key,
        content := Content
    }
}) ->
    #{
        type => ?ACTION_UPLOAD,
        bucket => emqx_template:parse(Bucket),
        key => emqx_template:parse(Key),
        content => emqx_template:parse(Content),
        upload_options => upload_options(Parameters)
    };
start_channel(State, #{
    bridge_type := Type = ?BRIDGE_TYPE_AGGREGATED_UPLOAD,
    bridge_name := Name,
    parameters := Parameters = #{
        aggregation := #{
            time_interval := TimeInterval,
            max_records := MaxRecords
        },
        container := Container,
        bucket := Bucket
    }
}) ->
    AggregOpts = #{
        time_interval => TimeInterval,
        max_records => MaxRecords,
        work_dir => work_dir(Type, Name)
    },
    DeliveryOpts = #{
        bucket => Bucket,
        key => emqx_bridge_s3_aggreg_upload:mk_key_template(Parameters),
        container => Container,
        upload_options => emqx_bridge_s3_aggreg_upload:mk_upload_options(Parameters),
        callback_module => ?MODULE,
        client_config => maps:get(client_config, State),
        uploader_config => maps:with([min_part_size, max_part_size], Parameters)
    },
    _ = emqx_connector_aggreg_sup:delete_child({Type, Name}),
    {ok, SupPid} = emqx_connector_aggreg_sup:start_child(#{
        id => {Type, Name},
        start => {emqx_connector_aggreg_upload_sup, start_link, [Name, AggregOpts, DeliveryOpts]},
        type => supervisor,
        restart => permanent
    }),
    #{
        type => ?ACTION_AGGREGATED_UPLOAD,
        name => Name,
        bucket => Bucket,
        supervisor => SupPid,
        on_stop => fun() -> emqx_connector_aggreg_sup:delete_child({Type, Name}) end
    }.

upload_options(Parameters) ->
    #{acl => maps:get(acl, Parameters, undefined)}.

work_dir(Type, Name) ->
    filename:join([emqx:data_dir(), bridge, Type, Name]).

stop_channel(#{on_stop := OnStop}) ->
    OnStop();
stop_channel(_ChannelState) ->
    ok.

channel_status(#{type := ?ACTION_UPLOAD}, _State) ->
    %% TODO
    %% Since bucket name may be templated, we can't really provide any additional
    %% information regarding the channel health.
    ?status_connected;
channel_status(#{type := ?ACTION_AGGREGATED_UPLOAD, name := Name, bucket := Bucket}, State) ->
    %% NOTE: This will effectively trigger uploads of buffers yet to be uploaded.
    Timestamp = erlang:system_time(second),
    ok = emqx_connector_aggregator:tick(Name, Timestamp),
    ok = check_bucket_accessible(Bucket, State),
    ok = check_aggreg_upload_errors(Name),
    ?status_connected.

check_bucket_accessible(Bucket, #{client_config := Config}) ->
    case emqx_s3_client:aws_config(Config) of
        {error, Reason} ->
            throw({unhealthy_target, Reason});
        AWSConfig ->
            try erlcloud_s3:list_objects(Bucket, [{max_keys, 1}], AWSConfig) of
                Props when is_list(Props) ->
                    ok
            catch
                error:{aws_error, {http_error, 404, _, _Reason}} ->
                    throw({unhealthy_target, "Bucket does not exist"});
                error:{aws_error, {socket_error, Reason}} ->
                    throw({unhealthy_target, emqx_utils:format(Reason)})
            end
    end.

check_aggreg_upload_errors(Name) ->
    case emqx_connector_aggregator:take_error(Name) of
        [Error] ->
            %% TODO
            %% This approach means that, for example, 3 upload failures will cause
            %% the channel to be marked as unhealthy for 3 consecutive health checks.
            ErrorMessage = emqx_utils:format(Error),
            throw({unhealthy_target, ErrorMessage});
        [] ->
            ok
    end.

%% Queries

-type query() :: {_Tag :: channel_id(), _Data :: emqx_jsonish:t()}.

-spec on_query(_InstanceId :: resource_id(), query(), state()) ->
    {ok, _Result} | {error, _Reason}.
on_query(InstId, {Tag, Data}, #{client_config := Config, channels := Channels}) ->
    case maps:get(Tag, Channels, undefined) of
        ChannelState = #{type := ?ACTION_UPLOAD} ->
            run_simple_upload(InstId, Tag, Data, ChannelState, Config);
        ChannelState = #{type := ?ACTION_AGGREGATED_UPLOAD} ->
            run_aggregated_upload(InstId, [Data], ChannelState);
        undefined ->
            {error, {unrecoverable_error, {invalid_message_tag, Tag}}}
    end.

-spec on_batch_query(_InstanceId :: resource_id(), [query()], state()) ->
    {ok, _Result} | {error, _Reason}.
on_batch_query(InstId, [{Tag, Data0} | Rest], #{channels := Channels}) ->
    case maps:get(Tag, Channels, undefined) of
        ChannelState = #{type := ?ACTION_AGGREGATED_UPLOAD} ->
            Records = [Data0 | [Data || {_, Data} <- Rest]],
            run_aggregated_upload(InstId, Records, ChannelState);
        undefined ->
            {error, {unrecoverable_error, {invalid_message_tag, Tag}}}
    end.

run_simple_upload(
    InstId,
    ChannelID,
    Data,
    #{
        bucket := BucketTemplate,
        key := KeyTemplate,
        content := ContentTemplate,
        upload_options := UploadOpts
    },
    Config
) ->
    Bucket = render_bucket(BucketTemplate, Data),
    Client = emqx_s3_client:create(Bucket, Config),
    Key = render_key(KeyTemplate, Data),
    Content = render_content(ContentTemplate, Data),
    emqx_trace:rendered_action_template(ChannelID, #{
        bucket => Bucket,
        key => Key,
        content => #emqx_trace_format_func_data{
            function = fun unicode:characters_to_binary/1,
            data = Content
        }
    }),
    case emqx_s3_client:put_object(Client, Key, UploadOpts, Content) of
        ok ->
            ?tp(s3_bridge_connector_upload_ok, #{
                instance_id => InstId,
                bucket => Bucket,
                key => Key
            }),
            ok;
        {error, Reason} ->
            {error, map_error(Reason)}
    end.

run_aggregated_upload(InstId, Records, #{name := Name}) ->
    Timestamp = erlang:system_time(second),
    case emqx_connector_aggregator:push_records(Name, Timestamp, Records) of
        ok ->
            ?tp(s3_bridge_aggreg_push_ok, #{instance_id => InstId, name => Name}),
            ok;
        {error, Reason} ->
            {error, {unrecoverable_error, Reason}}
    end.

map_error({socket_error, _} = Reason) ->
    {recoverable_error, Reason};
map_error(Reason = {aws_error, Status, _, _Body}) when Status >= 500 ->
    %% https://docs.aws.amazon.com/AmazonS3/latest/API/ErrorResponses.html#ErrorCodeList
    {recoverable_error, Reason};
map_error(Reason) ->
    {unrecoverable_error, Reason}.

render_bucket(Template, Data) ->
    case emqx_template:render(Template, {emqx_jsonish, Data}) of
        {Result, []} ->
            iolist_to_string(Result);
        {_, Errors} ->
            erlang:error({unrecoverable_error, {bucket_undefined, Errors}})
    end.

render_key(Template, Data) ->
    %% NOTE: ignoring errors here, missing variables will be rendered as `"undefined"`.
    {Result, _Errors} = emqx_template:render(Template, {emqx_jsonish, Data}),
    iolist_to_string(Result).

render_content(Template, Data) ->
    %% NOTE: ignoring errors here, missing variables will be rendered as `"undefined"`.
    {Result, _Errors} = emqx_template:render(Template, {emqx_jsonish, Data}),
    Result.

iolist_to_string(IOList) ->
    unicode:characters_to_list(IOList).

%% `emqx_connector_aggreg_delivery` APIs

-spec init_transfer_state(buffer(), map()) -> emqx_s3_upload:t().
init_transfer_state(Buffer, Opts) ->
    #{
        bucket := Bucket,
        upload_options := UploadOpts,
        client_config := Config,
        uploader_config := UploaderConfig
    } = Opts,
    Client = emqx_s3_client:create(Bucket, Config),
    Key = mk_object_key(Buffer, Opts),
    emqx_s3_upload:new(Client, Key, UploadOpts, UploaderConfig).

mk_object_key(Buffer, #{action := Name, key := Template}) ->
    emqx_template:render_strict(Template, {?MODULE, {Name, Buffer}}).

process_append(Writes, Upload0) ->
    {ok, Upload} = emqx_s3_upload:append(Writes, Upload0),
    Upload.

process_write(Upload0) ->
    case emqx_s3_upload:write(Upload0) of
        {ok, Upload} ->
            {ok, Upload};
        {cont, Upload} ->
            process_write(Upload);
        {error, Reason} ->
            _ = emqx_s3_upload:abort(Upload0),
            {error, Reason}
    end.

process_complete(Upload) ->
    case emqx_s3_upload:complete(Upload) of
        {ok, Completed} ->
            {ok, Completed};
        {error, Reason} ->
            _ = emqx_s3_upload:abort(Upload),
            exit({upload_failed, Reason})
    end.

process_format_status(Upload) ->
    emqx_s3_upload:format(Upload).

process_terminate(Upload) ->
    emqx_s3_upload:abort(Upload).

%% `emqx_template` APIs

-spec lookup(emqx_template:accessor(), {_Name, buffer()}) ->
    {ok, integer() | string()} | {error, undefined}.
lookup([<<"action">>], {Name, _Buffer}) ->
    {ok, mk_fs_safe_string(Name)};
lookup(Accessor, {_Name, Buffer = #buffer{}}) ->
    lookup_buffer_var(Accessor, Buffer);
lookup(_Accessor, _Context) ->
    {error, undefined}.

lookup_buffer_var([<<"datetime">>, Format], #buffer{since = Since}) ->
    {ok, format_timestamp(Since, Format)};
lookup_buffer_var([<<"datetime_until">>, Format], #buffer{until = Until}) ->
    {ok, format_timestamp(Until, Format)};
lookup_buffer_var([<<"sequence">>], #buffer{seq = Seq}) ->
    {ok, Seq};
lookup_buffer_var([<<"node">>], #buffer{}) ->
    {ok, mk_fs_safe_string(atom_to_binary(erlang:node()))};
lookup_buffer_var(_Binding, _Context) ->
    {error, undefined}.

format_timestamp(Timestamp, <<"rfc3339utc">>) ->
    String = calendar:system_time_to_rfc3339(Timestamp, [{unit, second}, {offset, "Z"}]),
    mk_fs_safe_string(String);
format_timestamp(Timestamp, <<"rfc3339">>) ->
    String = calendar:system_time_to_rfc3339(Timestamp, [{unit, second}]),
    mk_fs_safe_string(String);
format_timestamp(Timestamp, <<"unix">>) ->
    Timestamp.

mk_fs_safe_string(String) ->
    unicode:characters_to_binary(string:replace(String, ":", "_", all)).
