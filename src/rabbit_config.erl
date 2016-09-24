-module(rabbit_config).

-export([
         generate_config_file/5,
         prepare_and_use_config/0,
         prepare_config/1,
         update_app_config/1,
         schema_dir/0,
         config_files/0,
         get_advanced_config/0
        ]).

prepare_and_use_config() ->
    case legacy_erlang_term_config_used() of
        true  ->
            %% Use .config file
            ok;
        false ->
            case prepare_config(get_confs()) of
                ok ->
                    %% No .conf to generate from
                    ok;
                {ok, GeneratedConfigFile} ->
                    %% Generated config file
                    update_app_config(GeneratedConfigFile);
                {error, Err} ->
                    {error, Err}
            end
    end.

%% we support both the classic Erlang term
%% config file (rabbitmq.config) as well as rabbitmq.conf
legacy_erlang_term_config_used() ->
    case init:get_argument(config) of
        error        -> false;
        {ok, [Config | _]} -> 
            ConfigFile = Config ++ ".config",
            rabbit_file:is_file(ConfigFile) 
            andalso 
            get_advanced_config() == none
    end.

get_confs() ->
    case init:get_argument(conf) of
        {ok, Configs} -> Configs;
        _             -> []
    end.

prepare_config(Configs) ->
    case {init:get_argument(conf_dir), init:get_argument(conf_script_dir)} of
        {{ok, ConfDir}, {ok, ScriptDir}} ->
            ConfFiles = [Config ++ ".conf" || [Config] <- Configs,
                                            rabbit_file:is_file(Config ++
                                                                    ".conf")],
            case ConfFiles of
                [] -> ok;
                _  ->
                    case generate_config_file(ConfFiles, ConfDir, ScriptDir) of
                        {ok, GeneratedConfigFile} ->
                            {ok, GeneratedConfigFile};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end;
        _ -> ok
    end.

update_app_config(ConfigFile) ->
    ok = application_controller:change_application_data([], [ConfigFile]).

generate_config_file(ConfFiles, ConfDir, ScriptDir) ->
    generate_config_file(ConfFiles, ConfDir, ScriptDir, 
                         schema_dir(), get_advanced_config()).


generate_config_file(ConfFiles, ConfDir, ScriptDir, SchemaDir, Advanced) ->
    prepare_plugin_schemas(SchemaDir),
    % SchemaFile = filename:join([ScriptDir, "rabbitmq.schema"]),
    Cuttlefish = filename:join([ScriptDir, "cuttlefish"]),
    GeneratedDir = filename:join([ConfDir, "generated"]),

    AdvancedConfigArg = case check_advanced_config(Advanced) of
                            {ok, FileName} -> [" -a ", FileName];
                            none           -> []
                        end,
    rabbit_file:recursive_delete([GeneratedDir]),
    Command = lists:concat(["escript ", "\"", Cuttlefish, "\"",
                            "  -f rabbitmq -s ", "\"", SchemaDir, "\"",
                            " -e ", "\"",  ConfDir, "\"",
                            [[" -c ", ConfFile] || ConfFile <- ConfFiles],
                            AdvancedConfigArg]),
    Result = rabbit_misc:os_cmd(Command),
    case string:str(Result, " -config ") of
        0 -> {error, {generation_error, Result}};
        _ ->
            [OutFile]  = rabbit_file:wildcard("rabbitmq.*.config", GeneratedDir),
            ResultFile = filename:join([GeneratedDir, "rabbitmq.config"]),
            rabbit_file:rename(filename:join([GeneratedDir, OutFile]),
                               ResultFile),
            {ok, ResultFile}
    end.

schema_dir() ->
    case init:get_argument(conf_schema_dir) of
        {ok, SchemaDir} -> SchemaDir;
        _ ->
            case code:priv_dir(rabbit) of
                {error, bad_name} -> filename:join([".", "priv", "schema"]);
                PrivDir           -> filename:join([PrivDir, "schema"])
            end
    end.

check_advanced_config(none) -> none;
check_advanced_config(ConfigName) ->
    case rabbit_file:is_file(ConfigName) of
        true  -> {ok, ConfigName};
        false -> none
    end.

get_advanced_config() ->
    case init:get_argument(conf_advanced) of
        %% There can be only one advanced.config
        {ok, [FileName | _]} ->
            ConfigName = FileName ++ ".config",
            case rabbit_file:is_file(ConfigName) of
                true  -> ConfigName;
                false -> none
            end;
        _ -> none
    end.


prepare_plugin_schemas(SchemaDir) ->
    case rabbit_file:is_dir(SchemaDir) of
        true  -> rabbit_plugins:extract_schemas(SchemaDir);
        false -> ok
    end.


config_files() ->
    Abs = fun (F, Ex) -> filename:absname(filename:rootname(F, Ex) ++ Ex) end,
    case legacy_erlang_term_config_used() of
        true ->
            case init:get_argument(config) of
                {ok, Files} -> [Abs(File, ".config") || [File] <- Files];
                error       -> case config_setting() of
                                   none -> [];
                                   File -> [Abs(File, ".config") 
                                            ++ 
                                            " (not found)"]
                               end
            end;
        false ->
            ConfFiles = [Abs(File, ".conf") || File <- get_confs()],
            AdvancedFiles = case get_advanced_config() of
                none -> [];
                FileName -> [Abs(FileName, ".config")]
            end,
            AdvancedFiles ++ ConfFiles

    end.


%% This is a pain. We want to know where the config file is. But we
%% can't specify it on the command line if it is missing or the VM
%% will fail to start, so we need to find it by some mechanism other
%% than init:get_arguments/0. We can look at the environment variable
%% which is responsible for setting it... but that doesn't work for a
%% Windows service since the variable can change and the service not
%% be reinstalled, so in that case we add a magic application env.
config_setting() ->
    case application:get_env(rabbit, windows_service_config) of
        {ok, File1} -> File1;
        undefined   -> case os:getenv("RABBITMQ_CONFIG_FILE") of
                           false -> none;
                           File2 -> File2
                       end
    end.

