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
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_vhost_limit).

-behaviour(rabbit_runtime_parameter).

-include("rabbit.hrl").

-export([register/0]).
-export([parse_set/2, set/2, clear/1]).
-export([list/0, list/1]).
-export([update_limit/3, clear_limit/2, get_limit/2]).
-export([validate/5, notify/4, notify_clear/3]).
-export([connection_limit/1, queue_limit/1,
         is_over_queue_limit/1, is_over_connection_limit/1]).

-import(rabbit_misc, [pget/2, pget/3]).

-rabbit_boot_step({?MODULE,
                   [{description, "vhost limit parameters"},
                    {mfa, {rabbit_vhost_limit, register, []}},
                    {requires, rabbit_registry},
                    {enables, recovery}]}).

%%----------------------------------------------------------------------------

register() ->
    rabbit_registry:register(runtime_parameter, <<"vhost-limits">>, ?MODULE).

validate(_VHost, <<"vhost-limits">>, Name, Term, _User) ->
    rabbit_parameter_validation:proplist(
      Name, vhost_limit_validation(), Term).

notify(VHost, <<"vhost-limits">>, <<"limits">>, Limits) ->
    rabbit_event:notify(vhost_limits_set, [{name, <<"limits">>} | Limits]),
    update_vhost(VHost, Limits).

notify_clear(VHost, <<"vhost-limits">>, <<"limits">>) ->
    rabbit_event:notify(vhost_limits_cleared, [{name, <<"limits">>}]),
    update_vhost(VHost, undefined).

connection_limit(VirtualHost) ->
    get_limit(VirtualHost, <<"max-connections">>).

queue_limit(VirtualHost) ->
    get_limit(VirtualHost, <<"max-queues">>).

-spec list() -> [{rabbit_types:vhost(), rabbit_types:infos()}].

list() ->
    case rabbit_runtime_parameters:list_component(<<"vhost-limits">>) of
        []     -> [];
        Params -> [ {pget(vhost, Param), pget(value, Param)}
                    || Param <- Params,
                       pget(value, Param) =/= undefined,
                       pget(name, Param) == <<"limits">> ]
    end.

-spec list(rabbit_types:vhost()) -> rabbit_types:infos().

list(VHost) ->
    rabbit_runtime_parameters:value(VHost, <<"vhost-limits">>, <<"limits">>, []).

-spec is_over_connection_limit(rabbit_types:vhost()) -> {true, non_neg_integer()} | false.

is_over_connection_limit(VirtualHost) ->
    case rabbit_vhost_limit:connection_limit(VirtualHost) of
        %% no limit configured
        undefined                                            -> false;
        %% with limit = 0, no connections are allowed
        {ok, 0}                                              -> {true, 0};
        {ok, Limit} when is_integer(Limit) andalso Limit > 0 ->
            ConnectionCount = rabbit_connection_tracking:count_connections_in(VirtualHost),
            case ConnectionCount >= Limit of
                false -> false;
                true  -> {true, Limit}
            end;
        %% any negative value means "no limit". Note that parameter validation
        %% will replace negative integers with 'undefined', so this is to be
        %% explicit and extra defensive
        {ok, Limit} when is_integer(Limit) andalso Limit < 0 -> false;
        %% ignore non-integer limits
        {ok, _Limit}                                         -> false
    end.


-spec is_over_queue_limit(rabbit_types:vhost()) -> {true, non_neg_integer()} | false.

is_over_queue_limit(VirtualHost) ->
    case queue_limit(VirtualHost) of
        %% no limit configured
        undefined                                            -> false;
        %% with limit = 0, no queues can be declared (perhaps not very
        %% useful but consistent with the connection limit)
        {ok, 0}                                              -> {true, 0};
        {ok, Limit} when is_integer(Limit) andalso Limit > 0 ->
            QueueCount = rabbit_amqqueue:count(VirtualHost),
            case QueueCount >= Limit of
                false -> false;
                true  -> {true, Limit}
            end;
        %% any negative value means "no limit". Note that parameter validation
        %% will replace negative integers with 'undefined', so this is to be
        %% explicit and extra defensive
        {ok, Limit} when is_integer(Limit) andalso Limit < 0 -> false;
        %% ignore non-integer limits
        {ok, _Limit}                                         -> false
    end.

%%----------------------------------------------------------------------------

parse_set(VHost, Defn) ->
    case rabbit_misc:json_decode(Defn) of
        {ok, JSON} ->
            set(VHost, rabbit_misc:json_to_term(JSON));
        error ->
            {error_string, "JSON decoding error"}
    end.

set(VHost, Defn) ->
    rabbit_runtime_parameters:set_any(VHost, <<"vhost-limits">>,
                                      <<"limits">>, Defn, none).

clear(VHost) ->
    rabbit_runtime_parameters:clear_any(VHost, <<"vhost-limits">>,
                                        <<"limits">>).

update_limit(VHost, Name, Value) ->
    OldDef = case rabbit_runtime_parameters:list(VHost, <<"vhost-limits">>) of
        []      -> [];
        [Param] -> pget(value, Param, [])
    end,
    NewDef = [{Name, Value} | lists:keydelete(Name, 1, OldDef)],
    set(VHost, NewDef).

clear_limit(VHost, Name) ->
    OldDef = case rabbit_runtime_parameters:list(VHost, <<"vhost-limits">>) of
        []      -> [];
        [Param] -> pget(value, Param, [])
    end,
    NewDef = lists:keydelete(Name, 1, OldDef),
    set(VHost, NewDef).

vhost_limit_validation() ->
    [{<<"max-connections">>, fun rabbit_parameter_validation:integer/2, optional},
     {<<"max-queues">>,      fun rabbit_parameter_validation:integer/2, optional}].

update_vhost(VHostName, Limits) ->
    rabbit_misc:execute_mnesia_transaction(
      fun() ->
              rabbit_vhost:update(VHostName,
                                  fun(VHost) ->
                                          rabbit_vhost:set_limits(VHost, Limits)
                                  end)
      end),
    ok.

get_limit(VirtualHost, Limit) ->
    case rabbit_runtime_parameters:list(VirtualHost, <<"vhost-limits">>) of
        []      -> undefined;
        [Param] -> case pget(value, Param) of
                       undefined -> undefined;
                       Val       -> case pget(Limit, Val) of
                                        undefined     -> undefined;
                                        %% no limit
                                        N when N < 0  -> undefined;
                                        N when N >= 0 -> {ok, N}
                                    end
                   end
    end.
