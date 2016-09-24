%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2011-2015 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_plugins).
-include("rabbit.hrl").
-include_lib("stdlib/include/zip.hrl").

-export([setup/0, active/0, read_enabled/1, list/1, list/2, dependencies/3]).
-export([ensure/1]).
-export([extract_schemas/1]).
-export([validate_plugins/1, format_invalid_plugins/1]).

% Export for testing purpose.
-export([is_version_supported/2, validate_plugins/2]).
%%----------------------------------------------------------------------------

-type plugin_name() :: atom().

-spec setup() -> [plugin_name()].
-spec active() -> [plugin_name()].
-spec list(string()) -> [#plugin{}].
-spec list(string(), boolean()) -> [#plugin{}].
-spec read_enabled(file:filename()) -> [plugin_name()].
-spec dependencies(boolean(), [plugin_name()], [#plugin{}]) ->
                             [plugin_name()].
-spec ensure(string()) -> {'ok', [atom()], [atom()]} | {error, any()}.

%%----------------------------------------------------------------------------

ensure(FileJustChanged0) ->
    {ok, OurFile0} = application:get_env(rabbit, enabled_plugins_file),
    FileJustChanged = filename:nativename(FileJustChanged0),
    OurFile = filename:nativename(OurFile0),
    case OurFile of
        FileJustChanged ->
            Enabled = read_enabled(OurFile),
            Wanted = prepare_plugins(Enabled),
            rabbit_config:prepare_and_use_config(),
            Current = active(),
            Start = Wanted -- Current,
            Stop = Current -- Wanted,
            rabbit:start_apps(Start),
            %% We need sync_notify here since mgmt will attempt to look at all
            %% the modules for the disabled plugins - if they are unloaded
            %% that won't work.
            ok = rabbit_event:sync_notify(plugins_changed, [{enabled,  Start},
                                                            {disabled, Stop}]),
            rabbit:stop_apps(Stop),
            clean_plugins(Stop),
            rabbit_log:info("Plugins changed; enabled ~p, disabled ~p~n",
                            [Start, Stop]),
            {ok, Start, Stop};
        _ ->
            {error, {enabled_plugins_mismatch, FileJustChanged, OurFile}}
    end.

%% @doc Prepares the file system and installs all enabled plugins.
setup() ->
    {ok, ExpandDir}   = application:get_env(rabbit, plugins_expand_dir),

    %% Eliminate the contents of the destination directory
    case delete_recursively(ExpandDir) of
        ok          -> ok;
        {error, E1} -> throw({error, {cannot_delete_plugins_expand_dir,
                                      [ExpandDir, E1]}})
    end,

    {ok, EnabledFile} = application:get_env(rabbit, enabled_plugins_file),
    Enabled = read_enabled(EnabledFile),
    prepare_plugins(Enabled).

extract_schemas(SchemaDir) ->
    application:load(rabbit),
    {ok, EnabledFile} = application:get_env(rabbit, enabled_plugins_file),
    Enabled = read_enabled(EnabledFile),

    {ok, PluginsDistDir} = application:get_env(rabbit, plugins_dir),

    AllPlugins = list(PluginsDistDir),
    Wanted = dependencies(false, Enabled, AllPlugins),
    WantedPlugins = lookup_plugins(Wanted, AllPlugins),
    [ extract_schema(Plugin, SchemaDir) || Plugin <- WantedPlugins ],
    application:unload(rabbit),
    ok.

extract_schema(#plugin{type = ez, location = Location}, SchemaDir) ->
    {ok, Files} = zip:extract(Location,
                              [memory, {file_filter,
                                        fun(#zip_file{name = Name}) ->
                                            string:str(Name, "priv/schema") > 0
                                        end}]),
    lists:foreach(
        fun({FileName, Content}) ->
            ok = file:write_file(filename:join([SchemaDir,
                                                filename:basename(FileName)]),
                                 Content)
        end,
        Files),
    ok;
extract_schema(#plugin{type = dir, location = Location}, SchemaDir) ->
    PluginSchema = filename:join([Location,
                                  "priv",
                                  "schema"]),
    case rabbit_file:is_dir(PluginSchema) of
        false -> ok;
        true  ->
            PluginSchemaFiles =
                [ filename:join(PluginSchema, FileName)
                  || FileName <- rabbit_file:wildcard(".*\\.schema",
                                                      PluginSchema) ],
            [ file:copy(SchemaFile, SchemaDir)
              || SchemaFile <- PluginSchemaFiles ]
    end.


%% @doc Lists the plugins which are currently running.
active() ->
    {ok, ExpandDir} = application:get_env(rabbit, plugins_expand_dir),
    InstalledPlugins = plugin_names(list(ExpandDir)),
    [App || {App, _, _} <- rabbit_misc:which_applications(),
            lists:member(App, InstalledPlugins)].

%% @doc Get the list of plugins which are ready to be enabled.
list(PluginsDir) ->
    list(PluginsDir, false).

list(PluginsDir, IncludeRequiredDeps) ->
    EZs = [{ez, EZ} || EZ <- filelib:wildcard("*.ez", PluginsDir)],
    FreeApps = [{app, App} ||
                   App <- filelib:wildcard("*/ebin/*.app", PluginsDir)],
    %% We load the "rabbit" application to be sure we can get the
    %% "applications" key. This is required for rabbitmq-plugins for
    %% instance.
    application:load(rabbit),
    {ok, RabbitDeps} = application:get_key(rabbit, applications),
    AllPlugins = [plugin_info(PluginsDir, Plug) || Plug <- EZs ++ FreeApps],
    {AvailablePlugins, Problems} =
        lists:foldl(
            fun ({error, EZ, Reason}, {Plugins1, Problems1}) ->
                    {Plugins1, [{EZ, Reason} | Problems1]};
                (Plugin = #plugin{name = Name},
                 {Plugins1, Problems1}) ->
                    %% Applications RabbitMQ depends on (eg.
                    %% "rabbit_common") can't be considered
                    %% plugins, otherwise rabbitmq-plugins would
                    %% list them and the user may believe he can
                    %% disable them.
                    case IncludeRequiredDeps orelse
                      not lists:member(Name, RabbitDeps) of
                        true  -> {[Plugin|Plugins1], Problems1};
                        false -> {Plugins1, Problems1}
                    end
            end, {[], []},
            AllPlugins),
    case Problems of
        [] -> ok;
        _  -> rabbit_log:warning(
                "Problem reading some plugins: ~p~n", [Problems])
    end,

    Plugins = lists:filter(fun(P) -> not plugin_provided_by_otp(P) end,
                           AvailablePlugins),
    ensure_dependencies(Plugins).

%% @doc Read the list of enabled plugins from the supplied term file.
read_enabled(PluginsFile) ->
    case rabbit_file:read_term_file(PluginsFile) of
        {ok, [Plugins]} -> Plugins;
        {ok, []}        -> [];
        {ok, [_|_]}     -> throw({error, {malformed_enabled_plugins_file,
                                          PluginsFile}});
        {error, enoent} -> [];
        {error, Reason} -> throw({error, {cannot_read_enabled_plugins_file,
                                          PluginsFile, Reason}})
    end.

%% @doc Calculate the dependency graph from <i>Sources</i>.
%% When Reverse =:= true the bottom/leaf level applications are returned in
%% the resulting list, otherwise they're skipped.
dependencies(Reverse, Sources, AllPlugins) ->
    {ok, G} = rabbit_misc:build_acyclic_graph(
                fun ({App, _Deps}) -> [{App, App}] end,
                fun ({App,  Deps}) -> [{App, Dep} || Dep <- Deps] end,
                [{Name, Deps} || #plugin{name         = Name,
                                         dependencies = Deps} <- AllPlugins]),
    Dests = case Reverse of
                false -> digraph_utils:reachable(Sources, G);
                true  -> digraph_utils:reaching(Sources, G)
            end,
    OrderedDests = digraph_utils:postorder(digraph_utils:subgraph(G, Dests)),
    true = digraph:delete(G),
    OrderedDests.

%% For a few known cases, an externally provided plugin can be trusted.
%% In this special case, it overrides the plugin.
plugin_provided_by_otp(#plugin{name = eldap}) ->
    %% eldap was added to Erlang/OTP R15B01 (ERTS 5.9.1). In this case,
    %% we prefer this version to the plugin.
    rabbit_misc:version_compare(erlang:system_info(version), "5.9.1", gte);
plugin_provided_by_otp(_) ->
    false.

%% Make sure we don't list OTP apps in here, and also that we detect
%% missing dependencies.
ensure_dependencies(Plugins) ->
    Names = plugin_names(Plugins),
    NotThere = [Dep || #plugin{dependencies = Deps} <- Plugins,
                       Dep                          <- Deps,
                       not lists:member(Dep, Names)],
    {OTP, Missing} = lists:partition(fun is_loadable/1, lists:usort(NotThere)),
    case Missing of
        [] -> ok;
        _  -> Blame = [Name || #plugin{name         = Name,
                                       dependencies = Deps} <- Plugins,
                               lists:any(fun (Dep) ->
                                                 lists:member(Dep, Missing)
                                         end, Deps)],
              throw({error, {missing_dependencies, Missing, Blame}})
    end,
    [P#plugin{dependencies = Deps -- OTP}
     || P = #plugin{dependencies = Deps} <- Plugins].

is_loadable(App) ->
    case application:load(App) of
        {error, {already_loaded, _}} -> true;
        ok                           -> application:unload(App),
                                        true;
        _                            -> false
    end.

%%----------------------------------------------------------------------------

prepare_plugins(Enabled) ->
    {ok, PluginsDistDir} = application:get_env(rabbit, plugins_dir),
    {ok, ExpandDir} = application:get_env(rabbit, plugins_expand_dir),

    AllPlugins = list(PluginsDistDir),
    Wanted = dependencies(false, Enabled, AllPlugins),
    WantedPlugins = lookup_plugins(Wanted, AllPlugins),
    {ValidPlugins, Problems} = validate_plugins(WantedPlugins),
    maybe_warn_about_invalid_plugins(Problems),
    case filelib:ensure_dir(ExpandDir ++ "/") of
        ok          -> ok;
        {error, E2} -> throw({error, {cannot_create_plugins_expand_dir,
                                      [ExpandDir, E2]}})
    end,
    [prepare_plugin(Plugin, ExpandDir) || Plugin <- ValidPlugins],

    [prepare_dir_plugin(PluginAppDescPath) ||
        PluginAppDescPath <- filelib:wildcard(ExpandDir ++ "/*/ebin/*.app")],
    Wanted.

maybe_warn_about_invalid_plugins([]) ->
    ok;
maybe_warn_about_invalid_plugins(InvalidPlugins) ->
    %% TODO: error message formatting
    rabbit_log:warning(format_invalid_plugins(InvalidPlugins)).


format_invalid_plugins(InvalidPlugins) ->
    lists:flatten(["Failed to enable some plugins: \r\n"
                   | [format_invalid_plugin(Plugin)
                      || Plugin <- InvalidPlugins]]).

format_invalid_plugin({Name, Errors}) ->
    [io_lib:format("    ~p:~n", [Name])
     | [format_invalid_plugin_error(Err) || Err <- Errors]].

format_invalid_plugin_error({missing_dependency, Dep}) ->
    io_lib:format("        Dependency is missing or invalid: ~p~n", [Dep]);
%% a plugin doesn't support the effective broker version
format_invalid_plugin_error({broker_version_mismatch, Version, Required}) ->
    io_lib:format("        Plugin doesn't support current server version."
                  " Actual broker version: ~p, supported by the plugin: ~p~n", [Version, Required]);
%% one of dependencies of a plugin doesn't match its version requirements
format_invalid_plugin_error({{dependency_version_mismatch, Version, Required}, Name}) ->
    io_lib:format("        Version '~p' of dependency '~p' is unsupported."
                  " Version ranges supported by the plugin: ~p~n",
                  [Version, Name, Required]);
format_invalid_plugin_error(Err) ->
    io_lib:format("        Unknown error ~p~n", [Err]).

validate_plugins(Plugins) ->
    application:load(rabbit),
    RabbitVersion = RabbitVersion = case application:get_key(rabbit, vsn) of
                                        undefined -> "0.0.0";
                                        {ok, Val} -> Val
                                    end,
    validate_plugins(Plugins, RabbitVersion).

validate_plugins(Plugins, BrokerVersion) ->
    lists:foldl(
        fun(#plugin{name = Name,
                    broker_version_requirements = BrokerVersionReqs,
                    dependency_version_requirements = DepsVersions} = Plugin,
            {Plugins0, Errors}) ->
            case is_version_supported(BrokerVersion, BrokerVersionReqs) of
                true  ->
                    case BrokerVersion of
                        "0.0.0" ->
                            rabbit_log:warning(
                                "Running development version of the broker."
                                " Requirement ~p for plugin ~p is ignored.",
                                [BrokerVersionReqs, Name]);
                        _ -> ok
                    end,
                    case check_plugins_versions(Name, Plugins0, DepsVersions) of
                        ok           -> {[Plugin | Plugins0], Errors};
                        {error, Err} -> {Plugins0, [{Name, Err} | Errors]}
                    end;
                false ->
                    Error = [{broker_version_mismatch, BrokerVersion, BrokerVersionReqs}],
                    {Plugins0, [{Name, Error} | Errors]}
            end
        end,
        {[],[]},
        Plugins).

check_plugins_versions(PluginName, AllPlugins, RequiredVersions) ->
    ExistingVersions = [{Name, Vsn}
                        || #plugin{name = Name, version = Vsn} <- AllPlugins],
    Problems = lists:foldl(
        fun({Name, Versions}, Acc) ->
            case proplists:get_value(Name, ExistingVersions) of
                undefined -> [{missing_dependency, Name} | Acc];
                Version   ->
                    case is_version_supported(Version, Versions) of
                        true  ->
                            case Version of
                                "" ->
                                    rabbit_log:warning(
                                        "~p plugin version is not defined."
                                        " Requirement ~p for plugin ~p is ignored",
                                        [Versions, PluginName]);
                                _  -> ok
                            end,
                            Acc;
                        false ->
                            [{{dependency_version_mismatch, Version, Versions}, Name} | Acc]
                    end
            end
        end,
        [],
        RequiredVersions),
    case Problems of
        [] -> ok;
        _  -> {error, Problems}
    end.

is_version_supported("", _)        -> true;
is_version_supported("0.0.0", _)   -> true;
is_version_supported(_Version, []) -> true;
is_version_supported(Version, ExpectedVersions) ->
    case lists:any(fun(ExpectedVersion) ->
                       rabbit_misc:version_minor_equivalent(ExpectedVersion, Version)
                       andalso
                       rabbit_misc:version_compare(ExpectedVersion, Version, lte)
                   end,
                   ExpectedVersions) of
        true  -> true;
        false -> false
    end.

clean_plugins(Plugins) ->
    {ok, ExpandDir} = application:get_env(rabbit, plugins_expand_dir),
    [clean_plugin(Plugin, ExpandDir) || Plugin <- Plugins].

clean_plugin(Plugin, ExpandDir) ->
    {ok, Mods} = application:get_key(Plugin, modules),
    application:unload(Plugin),
    [begin
         code:soft_purge(Mod),
         code:delete(Mod),
         false = code:is_loaded(Mod)
     end || Mod <- Mods],
    delete_recursively(rabbit_misc:format("~s/~s", [ExpandDir, Plugin])).

prepare_dir_plugin(PluginAppDescPath) ->
    PluginEbinDir = filename:dirname(PluginAppDescPath),
    Plugin = filename:basename(PluginAppDescPath, ".app"),
    code:add_patha(PluginEbinDir),
    case filelib:wildcard(PluginEbinDir++ "/*.beam") of
        [] ->
            ok;
        [BeamPath | _] ->
            Module = list_to_atom(filename:basename(BeamPath, ".beam")),
            case code:ensure_loaded(Module) of
                {module, _} ->
                    ok;
                {error, badfile} ->
                    rabbit_log:error("Failed to enable plugin \"~s\": "
                                     "it may have been built with an "
                                     "incompatible (more recent?) "
                                     "version of Erlang~n", [Plugin]),
                    throw({plugin_built_with_incompatible_erlang, Plugin});
                Error ->
                    throw({plugin_module_unloadable, Plugin, Error})
            end
    end.

%%----------------------------------------------------------------------------

delete_recursively(Fn) ->
    case rabbit_file:recursive_delete([Fn]) of
        ok                 -> ok;
        {error, {Path, E}} -> {error, {cannot_delete, Path, E}}
    end.

prepare_plugin(#plugin{type = ez, location = Location}, ExpandDir) ->
    zip:unzip(Location, [{cwd, ExpandDir}]);
prepare_plugin(#plugin{type = dir, name = Name, location = Location},
               ExpandDir) ->
    rabbit_file:recursive_copy(Location, filename:join([ExpandDir, Name])).

plugin_info(Base, {ez, EZ0}) ->
    EZ = filename:join([Base, EZ0]),
    case read_app_file(EZ) of
        {application, Name, Props} -> mkplugin(Name, Props, ez, EZ);
        {error, Reason}            -> {error, EZ, Reason}
    end;
plugin_info(Base, {app, App0}) ->
    App = filename:join([Base, App0]),
    case rabbit_file:read_term_file(App) of
        {ok, [{application, Name, Props}]} ->
            mkplugin(Name, Props, dir,
                     filename:absname(
                       filename:dirname(filename:dirname(App))));
        {error, Reason} ->
            {error, App, {invalid_app, Reason}}
    end.

mkplugin(Name, Props, Type, Location) ->
    Version = proplists:get_value(vsn, Props, "0"),
    Description = proplists:get_value(description, Props, ""),
    Dependencies = proplists:get_value(applications, Props, []),
    BrokerVersions = proplists:get_value(broker_version_requirements, Props, []),
    DepsVersions = proplists:get_value(dependency_version_requirements, Props, []),
    #plugin{name = Name, version = Version, description = Description,
            dependencies = Dependencies, location = Location, type = Type,
            broker_version_requirements = BrokerVersions,
            dependency_version_requirements = DepsVersions}.

read_app_file(EZ) ->
    case zip:list_dir(EZ) of
        {ok, [_|ZippedFiles]} ->
            case find_app_files(ZippedFiles) of
                [AppPath|_] ->
                    {ok, [{AppPath, AppFile}]} =
                        zip:extract(EZ, [{file_list, [AppPath]}, memory]),
                    parse_binary(AppFile);
                [] ->
                    {error, no_app_file}
            end;
        {error, Reason} ->
            {error, {invalid_ez, Reason}}
    end.

find_app_files(ZippedFiles) ->
    {ok, RE} = re:compile("^.*/ebin/.*.app$"),
    [Path || {zip_file, Path, _, _, _, _} <- ZippedFiles,
             re:run(Path, RE, [{capture, none}]) =:= match].

parse_binary(Bin) ->
    try
        {ok, Ts, _} = erl_scan:string(binary_to_list(Bin)),
        {ok, Term} = erl_parse:parse_term(Ts),
        Term
    catch
        Err -> {error, {invalid_app, Err}}
    end.

plugin_names(Plugins) ->
    [Name || #plugin{name = Name} <- Plugins].

lookup_plugins(Names, AllPlugins) ->
    % Preserve order of Names
    lists:map(
        fun(Name) ->
            lists:keyfind(Name, #plugin.name, AllPlugins)
        end,
        Names).
