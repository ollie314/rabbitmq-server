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

-module(dynamic_ha_SUITE).

%% rabbit_tests:test_dynamic_mirroring() is a unit test which should
%% test the logic of what all the policies decide to do, so we don't
%% need to exhaustively test that here. What we need to test is that:
%%
%% * Going from non-mirrored to mirrored works and vice versa
%% * Changing policy can add / remove mirrors and change the master
%% * Adding a node will create a new mirror when there are not enough nodes
%%   for the policy
%% * Removing a node will not create a new mirror even if the policy
%%   logic wants it (since this gives us a good way to lose messages
%%   on cluster shutdown, by repeated failover to new nodes)
%%
%% The first two are change_policy, the last two are change_cluster

-include_lib("common_test/include/ct.hrl").
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-compile(export_all).

-define(QNAME, <<"ha.test">>).
-define(POLICY, <<"^ha.test$">>). %% " emacs
-define(VHOST, <<"/">>).

all() ->
    [
      {group, unclustered},
      {group, clustered}
    ].

groups() ->
    [
      {unclustered, [], [
          {cluster_size_5, [], [
              change_cluster
            ]}
        ]},
      {clustered, [], [
          {cluster_size_2, [], [
              vhost_deletion,
              promote_on_shutdown
            ]},
          {cluster_size_3, [], [
              change_policy,
              rapid_change
              % FIXME: Re-enable those tests when the know issues are
              % fixed.
              %failing_random_policies,
              %random_policy
            ]}
        ]}
    ].

%% -------------------------------------------------------------------
%% Testsuite setup/teardown.
%% -------------------------------------------------------------------

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    rabbit_ct_helpers:run_setup_steps(Config).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(unclustered, Config) ->
    rabbit_ct_helpers:set_config(Config, [{rmq_nodes_clustered, false}]);
init_per_group(clustered, Config) ->
    rabbit_ct_helpers:set_config(Config, [{rmq_nodes_clustered, true}]);
init_per_group(cluster_size_2, Config) ->
    rabbit_ct_helpers:set_config(Config, [{rmq_nodes_count, 2}]);
init_per_group(cluster_size_3, Config) ->
    rabbit_ct_helpers:set_config(Config, [{rmq_nodes_count, 3}]);
init_per_group(cluster_size_5, Config) ->
    rabbit_ct_helpers:set_config(Config, [{rmq_nodes_count, 5}]).

end_per_group(_, Config) ->
    Config.

init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase),
    ClusterSize = ?config(rmq_nodes_count, Config),
    TestNumber = rabbit_ct_helpers:testcase_number(Config, ?MODULE, Testcase),
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, Testcase},
        {tcp_ports_base, {skip_n_nodes, TestNumber * ClusterSize}}
      ]),
    rabbit_ct_helpers:run_steps(Config1,
      rabbit_ct_broker_helpers:setup_steps() ++
      rabbit_ct_client_helpers:setup_steps()).

end_per_testcase(Testcase, Config) ->
    Config1 = rabbit_ct_helpers:run_steps(Config,
      rabbit_ct_client_helpers:teardown_steps() ++
      rabbit_ct_broker_helpers:teardown_steps()),
    rabbit_ct_helpers:testcase_finished(Config1, Testcase).

%% -------------------------------------------------------------------
%% Testcases.
%% -------------------------------------------------------------------

change_policy(Config) ->
    [A, B, C] = rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    ACh = rabbit_ct_client_helpers:open_channel(Config, A),

    %% When we first declare a queue with no policy, it's not HA.
    amqp_channel:call(ACh, #'queue.declare'{queue = ?QNAME}),
    assert_slaves(A, ?QNAME, {A, ''}),

    %% Give it policy "all", it becomes HA and gets all mirrors
    rabbit_ct_broker_helpers:set_ha_policy(Config, A, ?POLICY, <<"all">>),
    assert_slaves(A, ?QNAME, {A, [B, C]}),

    %% Give it policy "nodes", it gets specific mirrors
    rabbit_ct_broker_helpers:set_ha_policy(Config, A, ?POLICY,
      {<<"nodes">>, [rabbit_misc:atom_to_binary(A),
                     rabbit_misc:atom_to_binary(B)]}),
    assert_slaves(A, ?QNAME, {A, [B]}),

    %% Now explicitly change the mirrors
    rabbit_ct_broker_helpers:set_ha_policy(Config, A, ?POLICY,
      {<<"nodes">>, [rabbit_misc:atom_to_binary(A),
                     rabbit_misc:atom_to_binary(C)]}),
    assert_slaves(A, ?QNAME, {A, [C]}, [{A, [B, C]}]),

    %% Clear the policy, and we go back to non-mirrored
    ok = rabbit_ct_broker_helpers:clear_policy(Config, A, ?POLICY),
    assert_slaves(A, ?QNAME, {A, ''}),

    %% Test switching "away" from an unmirrored node
    rabbit_ct_broker_helpers:set_ha_policy(Config, A, ?POLICY,
      {<<"nodes">>, [rabbit_misc:atom_to_binary(B),
                     rabbit_misc:atom_to_binary(C)]}),
    assert_slaves(A, ?QNAME, {A, [B, C]}, [{A, [B]}, {A, [C]}]),

    ok.

change_cluster(Config) ->
    [A, B, C, D, E] = rabbit_ct_broker_helpers:get_node_configs(Config,
      nodename),
    rabbit_ct_broker_helpers:cluster_nodes(Config, [A, B, C]),
    ACh = rabbit_ct_client_helpers:open_channel(Config, A),

    amqp_channel:call(ACh, #'queue.declare'{queue = ?QNAME}),
    assert_slaves(A, ?QNAME, {A, ''}),

    %% Give it policy exactly 4, it should mirror to all 3 nodes
    rabbit_ct_broker_helpers:set_ha_policy(Config, A, ?POLICY,
      {<<"exactly">>, 4}),
    assert_slaves(A, ?QNAME, {A, [B, C]}),

    %% Add D and E, D joins in
    rabbit_ct_broker_helpers:cluster_nodes(Config, [A, D, E]),
    assert_slaves(A, ?QNAME, {A, [B, C, D]}),

    %% Remove D, E joins in
    rabbit_ct_broker_helpers:stop_node(Config, D),
    assert_slaves(A, ?QNAME, {A, [B, C, E]}),

    ok.

rapid_change(Config) ->
    A = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    ACh = rabbit_ct_client_helpers:open_channel(Config, A),
    {_Pid, MRef} = spawn_monitor(
                     fun() ->
                             [rapid_amqp_ops(ACh, I) || I <- lists:seq(1, 100)]
                     end),
    rapid_loop(Config, A, MRef),
    ok.

rapid_amqp_ops(Ch, I) ->
    Payload = list_to_binary(integer_to_list(I)),
    amqp_channel:call(Ch, #'queue.declare'{queue = ?QNAME}),
    amqp_channel:cast(Ch, #'basic.publish'{exchange = <<"">>,
                                           routing_key = ?QNAME},
                      #amqp_msg{payload = Payload}),
    amqp_channel:subscribe(Ch, #'basic.consume'{queue    = ?QNAME,
                                                no_ack   = true}, self()),
    receive #'basic.consume_ok'{} -> ok
    end,
    receive {#'basic.deliver'{}, #amqp_msg{payload = Payload}} ->
            ok
    end,
    amqp_channel:call(Ch, #'queue.delete'{queue = ?QNAME}).

rapid_loop(Config, Node, MRef) ->
    receive
        {'DOWN', MRef, process, _Pid, normal} ->
            ok;
        {'DOWN', MRef, process, _Pid, Reason} ->
            exit({amqp_ops_died, Reason})
    after 0 ->
            rabbit_ct_broker_helpers:set_ha_policy(Config, Node, ?POLICY,
              <<"all">>),
            ok = rabbit_ct_broker_helpers:clear_policy(Config, Node, ?POLICY),
            rapid_loop(Config, Node, MRef)
    end.

%% Vhost deletion needs to successfully tear down policies and queues
%% with policies. At least smoke-test that it doesn't blow up.
vhost_deletion(Config) ->
    A = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    rabbit_ct_broker_helpers:set_ha_policy_all(Config),
    ACh = rabbit_ct_client_helpers:open_channel(Config, A),
    amqp_channel:call(ACh, #'queue.declare'{queue = <<"vhost_deletion-q">>}),
    ok = rpc:call(A, rabbit_vhost, delete, [<<"/">>]),
    ok.

promote_on_shutdown(Config) ->
    [A, B] = rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    rabbit_ct_broker_helpers:set_ha_policy(Config, A, <<"^ha.promote">>,
      <<"all">>, [{<<"ha-promote-on-shutdown">>, <<"always">>}]),
    rabbit_ct_broker_helpers:set_ha_policy(Config, A, <<"^ha.nopromote">>,
      <<"all">>),

    ACh = rabbit_ct_client_helpers:open_channel(Config, A),
    [begin
         amqp_channel:call(ACh, #'queue.declare'{queue   = Q,
                                                 durable = true}),
         rabbit_ct_client_helpers:publish(ACh, Q, 10)
     end || Q <- [<<"ha.promote.test">>, <<"ha.nopromote.test">>]],
    ok = rabbit_ct_broker_helpers:restart_node(Config, B),
    ok = rabbit_ct_broker_helpers:stop_node(Config, A),
    BCh = rabbit_ct_client_helpers:open_channel(Config, B),
    #'queue.declare_ok'{message_count = 0} =
        amqp_channel:call(
          BCh, #'queue.declare'{queue   = <<"ha.promote.test">>,
                                durable = true}),
    ?assertExit(
       {{shutdown, {server_initiated_close, 404, _}}, _},
       amqp_channel:call(
         BCh, #'queue.declare'{queue   = <<"ha.nopromote.test">>,
                               durable = true})),
    ok = rabbit_ct_broker_helpers:start_node(Config, A),
    ACh2 = rabbit_ct_client_helpers:open_channel(Config, A),
    #'queue.declare_ok'{message_count = 10} =
        amqp_channel:call(
          ACh2, #'queue.declare'{queue   = <<"ha.nopromote.test">>,
                                 durable = true}),
    ok.

random_policy(Config) ->
    run_proper(fun prop_random_policy/1, [Config]).

failing_random_policies(Config) ->
    [A, B | _] = Nodes = rabbit_ct_broker_helpers:get_node_configs(Config,
      nodename),
    %% Those set of policies were found as failing by PropEr in the
    %% `random_policy` test above. We add them explicitely here to make
    %% sure they get tested.
    ?assertEqual(true, test_random_policy(Config, Nodes,
        [{nodes, [A, B]}, {nodes, [A]}])),
    ?assertEqual(true, test_random_policy(Config, Nodes,
        [{exactly, 3}, undefined, all, {nodes, [B]}])),
    ?assertEqual(true, test_random_policy(Config, Nodes,
        [all, undefined, {exactly, 2}, all, {exactly, 3}, {exactly, 3},
          undefined, {exactly, 3}, all])).

%%----------------------------------------------------------------------------

assert_slaves(RPCNode, QName, Exp) ->
    assert_slaves(RPCNode, QName, Exp, []).

assert_slaves(RPCNode, QName, Exp, PermittedIntermediate) ->
    assert_slaves0(RPCNode, QName, Exp,
                  [{get(previous_exp_m_node), get(previous_exp_s_nodes)} |
                   PermittedIntermediate]).

assert_slaves0(RPCNode, QName, {ExpMNode, ExpSNodes}, PermittedIntermediate) ->
    Q = find_queue(QName, RPCNode),
    Pid = proplists:get_value(pid, Q),
    SPids = proplists:get_value(slave_pids, Q),
    ActMNode = node(Pid),
    ActSNodes = case SPids of
                    '' -> '';
                    _  -> [node(SPid) || SPid <- SPids]
                end,
    case ExpMNode =:= ActMNode andalso equal_list(ExpSNodes, ActSNodes) of
        false ->
            %% It's an async change, so if nothing has changed let's
            %% just wait - of course this means if something does not
            %% change when expected then we time out the test which is
            %% a bit tedious
            case [found || {PermMNode, PermSNodes} <- PermittedIntermediate,
                           PermMNode =:= ActMNode,
                           equal_list(PermSNodes, ActSNodes)] of
                [] -> ct:fail("Expected ~p / ~p, got ~p / ~p~nat ~p~n",
                              [ExpMNode, ExpSNodes, ActMNode, ActSNodes,
                               get_stacktrace()]);
                _  -> timer:sleep(100),
                      assert_slaves0(RPCNode, QName, {ExpMNode, ExpSNodes},
                                     PermittedIntermediate)
            end;
        true ->
            put(previous_exp_m_node, ExpMNode),
            put(previous_exp_s_nodes, ExpSNodes),
            ok
    end.

equal_list('',    '')   -> true;
equal_list('',    _Act) -> false;
equal_list(_Exp,  '')   -> false;
equal_list([],    [])   -> true;
equal_list(_Exp,  [])   -> false;
equal_list([],    _Act) -> false;
equal_list([H|T], Act)  -> case lists:member(H, Act) of
                               true  -> equal_list(T, Act -- [H]);
                               false -> false
                           end.

find_queue(QName, RPCNode) ->
    Qs = rpc:call(RPCNode, rabbit_amqqueue, info_all, [?VHOST], infinity),
    case find_queue0(QName, Qs) of
        did_not_find_queue -> timer:sleep(100),
                              find_queue(QName, RPCNode);
        Q -> Q
    end.

find_queue0(QName, Qs) ->
    case [Q || Q <- Qs, proplists:get_value(name, Q) =:=
                   rabbit_misc:r(?VHOST, queue, QName)] of
        [R] -> R;
        []  -> did_not_find_queue
    end.

get_stacktrace() ->
    try
        throw(e)
    catch
        _:e ->
            erlang:get_stacktrace()
    end.

%%----------------------------------------------------------------------------
run_proper(Fun, Args) ->
    ?assertEqual(true,
      proper:counterexample(erlang:apply(Fun, Args),
        [{numtests, 25},
          {on_output, fun(F, A) -> ct:pal(?LOW_IMPORTANCE, F, A) end}])).

prop_random_policy(Config) ->
    Nodes = rabbit_ct_broker_helpers:get_node_configs(
              Config, nodename),
    ?FORALL(
       Policies, non_empty(list(policy_gen(Nodes))),
       test_random_policy(Config, Nodes, Policies)).

test_random_policy(Config, Nodes, Policies) ->
    [NodeA | _] = Nodes,
    Ch = rabbit_ct_client_helpers:open_channel(Config, NodeA),
    amqp_channel:call(Ch, #'queue.declare'{queue = ?QNAME}),
    %% Add some load so mirrors can be busy synchronising
    rabbit_ct_client_helpers:publish(Ch, ?QNAME, 100000),
    %% Apply policies in parallel on all nodes
    apply_in_parallel(Config, Nodes, Policies),
    %% Give it some time to generate all internal notifications
    timer:sleep(2000),
    %% Check the result
    Result = wait_for_last_policy(?QNAME, NodeA, Policies, 30),
    %% Cleanup
    amqp_channel:call(Ch, #'queue.delete'{queue = ?QNAME}),
    _ = rabbit_ct_broker_helpers:clear_policy(Config, NodeA, ?POLICY),
    Result.

apply_in_parallel(Config, Nodes, Policies) ->
    Self = self(),
    [spawn_link(fun() ->
                        [begin
                             apply_policy(Config, N, Policy)
                         end || Policy <- Policies],
                        Self ! parallel_task_done
                end) || N <- Nodes],
    [receive
         parallel_task_done ->
             ok
     end || _ <- Nodes].

%% Proper generators
policy_gen(Nodes) ->
    %% Stop mirroring needs to be called often to trigger rabbitmq-server#803
    frequency([{3, undefined},
               {1, all},
               {1, {nodes, nodes_gen(Nodes)}},
               {1, {exactly, choose(1, 3)}}
              ]).

nodes_gen(Nodes) ->
    ?LET(List, non_empty(list(oneof(Nodes))),
         sets:to_list(sets:from_list(List))).

%% Checks
wait_for_last_policy(QueueName, NodeA, TestedPolicies, Tries) ->
    %% Ensure the owner/master is able to process a call request,
    %% which means that all pending casts have been processed.
    %% Use the information returned by owner/master to verify the
    %% test result
    Info = find_queue(QueueName, NodeA),
    Pid = proplists:get_value(pid, Info),
    Node = node(Pid),
    %% Gets owner/master
    case rpc:call(Node, gen_server, call, [Pid, info], 5000) of
        {badrpc, _} ->
            %% The queue is probably being migrated to another node.
            %% Let's wait a bit longer.
            timer:sleep(1000),
            wait_for_last_policy(QueueName, NodeA, TestedPolicies, Tries - 1);
        FinalInfo ->
            %% The last policy is the final state
            LastPolicy = lists:last(TestedPolicies),
            case verify_policy(LastPolicy, FinalInfo) of
                true ->
                    true;
                false when Tries =:= 1 ->
                    Policies = rpc:call(Node, rabbit_policy, list, [], 5000),
                    ct:pal(
                      "Last policy not applied:~n"
                      "  Queue node:          ~s (~p)~n"
                      "  Queue info:          ~p~n"
                      "  Configured policies: ~p~n"
                      "  Tested policies:     ~p",
                      [Node, Pid, FinalInfo, Policies, TestedPolicies]),
                    false;
                false ->
                    timer:sleep(1000),
                    wait_for_last_policy(QueueName, NodeA, TestedPolicies,
                      Tries - 1)
            end
    end.

verify_policy(undefined, Info) ->
    %% If the queue is not mirrored, it returns ''
    '' == proplists:get_value(slave_pids, Info);
verify_policy(all, Info) ->
    2 == length(proplists:get_value(slave_pids, Info));
verify_policy({exactly, 1}, Info) ->
    %% If the queue is mirrored, it returns a list
    [] == proplists:get_value(slave_pids, Info);
verify_policy({exactly, N}, Info) ->
    (N - 1) == length(proplists:get_value(slave_pids, Info));
verify_policy({nodes, Nodes}, Info) ->
    Master = node(proplists:get_value(pid, Info)),
    Slaves = [node(P) || P <- proplists:get_value(slave_pids, Info)],
    lists:sort(Nodes) == lists:sort([Master | Slaves]).

%% Policies
apply_policy(Config, N, undefined) ->
    _ = rabbit_ct_broker_helpers:clear_policy(Config, N, ?POLICY);
apply_policy(Config, N, all) ->
    rabbit_ct_broker_helpers:set_ha_policy(
      Config, N, ?POLICY, <<"all">>,
      [{<<"ha-sync-mode">>, <<"automatic">>}]);
apply_policy(Config, N, {nodes, Nodes}) ->
    NNodes = [rabbit_misc:atom_to_binary(Node) || Node <- Nodes],
    rabbit_ct_broker_helpers:set_ha_policy(
      Config, N, ?POLICY, {<<"nodes">>, NNodes},
      [{<<"ha-sync-mode">>, <<"automatic">>}]);
apply_policy(Config, N, {exactly, Exactly}) ->
    rabbit_ct_broker_helpers:set_ha_policy(
      Config, N, ?POLICY, {<<"exactly">>, Exactly},
      [{<<"ha-sync-mode">>, <<"automatic">>}]).
