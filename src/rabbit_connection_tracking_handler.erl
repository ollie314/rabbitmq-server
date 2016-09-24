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

-module(rabbit_connection_tracking_handler).

%% This module keeps track of connection creation and termination events
%% on its local node. The primary goal here is to decouple connection
%% tracking from rabbit_reader in rabbit_common.
%%
%% Events from other nodes are ignored.

-behaviour(gen_event).

-export([init/1, handle_call/2, handle_event/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("rabbit.hrl").
-import(rabbit_misc, [pget/2]).

-rabbit_boot_step({?MODULE,
                   [{description, "connection tracking event handler"},
                    {mfa,         {gen_event, add_handler,
                                   [rabbit_event, ?MODULE, []]}},
                    {cleanup,     {gen_event, delete_handler,
                                   [rabbit_event, ?MODULE, []]}},
                    {requires,    [rabbit_event, rabbit_node_monitor]},
                    {enables,     recovery}]}).


%%
%% API
%%

init([]) ->
    {ok, []}.

handle_event(#event{type = connection_created, props = Details}, State) ->
    ThisNode = node(),
    case pget(node, Details) of
      ThisNode ->
          rabbit_connection_tracking:register_connection(
            rabbit_connection_tracking:tracked_connection_from_connection_created(Details)
          );
      _OtherNode ->
        %% ignore
        ok
    end,
    {ok, State};
handle_event(#event{type = connection_closed, props = Details}, State) ->
    ThisNode = node(),
    case pget(node, Details) of
      ThisNode ->
          %% [{name,<<"127.0.0.1:64078 -> 127.0.0.1:5672">>},
          %%  {pid,<0.1774.0>},
          %%  {node, rabbit@hostname}]
          rabbit_connection_tracking:unregister_connection(
            {pget(node, Details),
             pget(name, Details)});
      _OtherNode ->
        %% ignore
        ok
    end,
    {ok, State};
handle_event(#event{type = vhost_deleted, props = Details}, State) ->
    VHost = pget(name, Details),
    rabbit_log_connection:info("Closing all connections in vhost '~s' because it's being deleted", [VHost]),
    [close_connection(Conn, rabbit_misc:format("vhost '~s' is deleted", [VHost]))
     || Conn <- rabbit_connection_tracking:list(VHost)],
    {ok, State};
handle_event(#event{type = user_deleted, props = Details}, State) ->
    _Username = pget(name, Details),
    %% TODO: force close and unregister connections from
    %%       this user. Moved to rabbitmq/rabbitmq-server#628.
    {ok, State};
%% A node had been deleted from the cluster.
handle_event(#event{type = node_deleted, props = Details}, State) ->
    Node = pget(node, Details),
    rabbit_log_connection:info("Node '~s' was removed from the cluster, deleting its connection tracking tables...", [Node]),
    rabbit_connection_tracking:delete_tracked_connections_table_for_node(Node),
    rabbit_connection_tracking:delete_per_vhost_tracked_connections_table_for_node(Node),
    {ok, State};
handle_event(_Event, State) ->
    {ok, State}.

handle_call(_Request, State) ->
    {ok, not_understood, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Arg, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

close_connection(#tracked_connection{pid = Pid, type = network}, Message) ->
    rabbit_networking:close_connection(Pid, Message);
close_connection(#tracked_connection{pid = Pid, type = direct}, Message) ->
    %% Do an RPC call to the node running the direct client.
    Node = node(Pid),
    rpc:call(Node, amqp_direct_connection, server_close, [Pid, 320, Message]).
