%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc Userspace implementation of the OpenFlow Switch logic.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_switch_userspace).

-behaviour(gen_switch).

%% Switch API
-export([route/1]).

%% gen_switch callbacks
-export([init/1, modify_flow/2, modify_table/2, modify_port/2, modify_group/2,
         echo_request/2, get_desc_stats/2, get_flow_stats/2,
         get_aggregate_stats/2, get_table_stats/2, get_port_stats/2,
         get_queue_stats/2, get_group_stats/2, get_group_desc_stats/2,
         get_group_features_stats/2, terminate/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include("of_switch_userspace.hrl").

-record(state, {}).

-type state() :: #state{}.
-type route_result() :: drop | controller | output.

%%%-----------------------------------------------------------------------------
%%% Switch API
%%%-----------------------------------------------------------------------------

-spec route(#ofs_pkt{}) -> route_result().
route(Pkt) ->
    do_route(Pkt, 0).

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Initialize switch state.
-spec init(any()) -> {ok, state()}.
init(_Opts) ->
    flow_tables = ets:new(flow_tables, [named_table,
                                        {keypos, #flow_table.id},
                                        {read_concurrency, true}]),
    flow_entry_counters = ets:new(flow_entry_counters,
                                  [named_table,
                                   {keypos, #flow_entry_counter.key},
                                   {read_concurrency, true}]),
    InitialTable = #flow_table{id = 0, entries = [], config = drop},
    ets:insert(flow_tables, InitialTable),
    {ok, #state{}}.

%% @doc Modify flow entry in the flow table.
-spec modify_flow(state(), flow_mod()) -> any().
modify_flow(State, #flow_mod{table_id = TID} = FlowMod) ->
    [Table] = ets:lookup(flow_tables, TID),
    case apply_flow_mod(Table, FlowMod) of
        {ok, NewTable} ->
            ets:insert(flow_tables, NewTable);
        {error, _Err} ->
            %% XXX: send error reply
            send_error_reply
    end,
    % XXX: look at buffer_id
    State.

%% @doc Modify flow table configuration.
-spec modify_table(state(), table_mod()) -> any().
modify_table(#state{} = _State, #table_mod{} = _TableMod) ->
    ok.

%% @doc Modify port configuration.
-spec modify_port(state(), port_mod()) -> any().
modify_port(#state{} = _State, #port_mod{} = _PortMod) ->
    ok.

%% @doc Modify group entry in the group table.
-spec modify_group(state(), group_mod()) -> any().
modify_group(#state{} = _State, #group_mod{} = _GroupMod) ->
    ok.

%% @doc Reply to echo request.
-spec echo_request(state(), echo_request()) -> any().
echo_request(#state{} = _State, #echo_request{} = _EchoRequest) ->
    ok.

%% @doc Get switch description statistics.
-spec get_desc_stats(state(), desc_stats_request()) -> {ok, desc_stats_reply()}.
get_desc_stats(#state{} = _State, #desc_stats_request{} = _StatsRequest) ->
    {ok, #desc_stats_reply{}}.

%% @doc Get flow entry statistics.
-spec get_flow_stats(state(), flow_stats_request()) -> {ok, flow_stats_reply()}.
get_flow_stats(#state{} = _State, #flow_stats_request{} = _StatsRequest) ->
    {ok, #flow_stats_reply{}}.

%% @doc Get aggregated flow statistics.
-spec get_aggregate_stats(state(), aggregate_stats_request()) ->
                                 {ok, aggregate_stats_reply()}.
get_aggregate_stats(#state{} = _State,
                    #aggregate_stats_request{} = _StatsRequest) ->
    {ok, #aggregate_stats_reply{}}.

%% @doc Get flow table statistics.
-spec get_table_stats(state(), table_stats_request()) ->
                             {ok, table_stats_reply()}.
get_table_stats(#state{} = _State, #table_stats_request{} = _StatsRequest) ->
    {ok, #table_stats_reply{}}.

%% @doc Get port statistics.
-spec get_port_stats(state(), port_stats_request()) -> {ok, port_stats_reply()}.
get_port_stats(#state{} = _State, #port_stats_request{} = _StatsRequest) ->
    {ok, #port_stats_reply{}}.

%% @doc Get queue statistics.
-spec get_queue_stats(state(), queue_stats_request()) ->
                             {ok, queue_stats_reply()}.
get_queue_stats(#state{} = _State, #queue_stats_request{} = _StatsRequest) ->
    {ok, #queue_stats_reply{}}.

%% @doc Get group statistics.
-spec get_group_stats(state(), group_stats_request()) ->
                             {ok, group_stats_reply()}.
get_group_stats(#state{} = _State, #group_stats_request{} = _StatsRequest) ->
    {ok, #group_stats_reply{}}.

%% @doc Get group description statistics.
-spec get_group_desc_stats(state(), group_desc_stats_request()) ->
                                  {ok, group_desc_stats_reply()}.
get_group_desc_stats(#state{} = _State,
                     #group_desc_stats_request{} = _StatsRequest) ->
    {ok, #group_desc_stats_reply{}}.

%% @doc Get group features statistics.
-spec get_group_features_stats(state(), group_features_stats_request()) ->
                                      {ok, group_features_stats_reply()}.
get_group_features_stats(#state{} = _State,
                         #group_features_stats_request{} = _StatsRequest) ->
    {ok, #group_features_stats_reply{}}.

%% @doc Terminate the switch.
-spec terminate(state()) -> any().
terminate(#state{} = _State) ->
    ets:delete(flow_tables),
    ok.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

apply_flow_mod(#flow_table{id = Id, entries = Entries} = Table,
               #flow_mod{command = add,
                         priority = Priority,
                         flags = Flags} = FlowMod) ->
    case has_priority_overlap(Flags, Priority, Entries) of
        true ->
            {error, overflow};
        false ->
            NewEntries = lists:keymerge(#flow_entry.priority,
                                        [flow_mod_to_entry(FlowMod, Id)],
                                        Entries),
            {ok, Table#flow_table{entries = NewEntries}}
    end.

flow_mod_to_entry(#flow_mod{priority = Priority,
                            match = Match,
                            instructions = Instructions},
                  FlowTableId) ->
    FlowEntry = #flow_entry{priority = Priority,
                            match = Match,
                            instructions = Instructions},
    ets:insert(flow_entry_counter,
               #flow_entry_counter{key = {FlowTableId, FlowEntry},
                                   install_time = erlang:universaltime()}),
    FlowEntry.

has_priority_overlap(Flags, Priority, Entries) ->
    lists:member(check_overlap, Flags)
    andalso
    lists:keymember(Priority, #flow_entry.priority, Entries).

-spec do_route(#ofs_pkt{}, integer()) -> route_result().
do_route(Pkt, FlowId) ->
    case apply_flow(Pkt, FlowId) of
        {match, goto, NextFlowId, NewPkt} ->
            do_route(NewPkt, NextFlowId);
        {match, output, NewPkt} ->
            case lists:keymember(action_output, 1, NewPkt#ofs_pkt.actions) of
                true ->
                    apply_action_set(NewPkt#ofs_pkt.actions, NewPkt),
                    output;
                false ->
                    drop
            end;
        {table_miss, controller} ->
            route_to_controller(Pkt),
            controller;
        {table_miss, drop} ->
            drop;
        {table_miss, continue, NextFlowId} ->
            do_route(Pkt, NextFlowId)
    end.

-spec get_flow_table(integer()) -> #flow_table{} | noflow.
get_flow_table(FlowId) ->
    case ets:lookup(flow_tables, FlowId) of
        [] ->
            noflow;
        [FlowTable] ->
            FlowTable
    end.

-spec apply_flow(#ofs_pkt{}, #flow_entry{}) -> tuple().
apply_flow(Pkt, FlowId) ->
    case get_flow_table(FlowId) of
        noflow ->
            {nomatch, drop};
        FlowTable ->
            case match_flow_entries(Pkt,
                                    FlowTable#flow_table.id,
                                    FlowTable#flow_table.entries) of
                {match, goto, NextFlowId, NewPkt} ->
                    update_flow_table_match_counters(FlowTable#flow_table.id),
                    {match, goto, NextFlowId, NewPkt};
                {match, output, NewPkt} ->
                    update_flow_table_match_counters(FlowTable#flow_table.id),
                    {match, output, NewPkt};
                table_miss when FlowTable#flow_table.config == drop ->
                    update_flow_table_miss_counters(FlowTable#flow_table.id),
                    {table_miss, drop};
                table_miss when FlowTable#flow_table.config == controller ->
                    update_flow_table_miss_counters(FlowTable#flow_table.id),
                    {table_miss, controller};
                table_miss when FlowTable#flow_table.config == continue ->
                    update_flow_table_miss_counters(FlowTable#flow_table.id),
                    {table_miss, continue, FlowId + 1}
            end
    end.

-spec update_flow_table_match_counters(integer()) -> ok.
update_flow_table_match_counters(FlowTableId) ->
    ets:udpate_counter(flow_tables, FlowTableId, [{packet_lookups, 1},
                                                  {packet_matches, 1}]).

-spec update_flow_table_miss_counters(integer()) -> ok.
update_flow_table_miss_counters(FlowTableId) ->
    ets:udpate_counter(flow_tables, FlowTableId, [{packet_lookups, 1}]).

-spec update_flow_entry_counters(integer(), #flow_entry{}, integer()) -> ok.
update_flow_entry_counters(FlowTableId, FlowEntry, PktSize) ->
    ets:update_counter(flow_entry_counters,
                       {FlowTableId, FlowEntry},
                       [{received_packets, 1},
                        {received_bytes, PktSize}]).

-spec match_flow_entries(#ofs_pkt{}, integer(), list(#flow_entry{}))
                        -> tuple() | nomatch.
match_flow_entries(Pkt, FlowTableId, [FlowEntry | Rest]) ->
    case match_flow_entry(Pkt, FlowEntry) of
        {match, goto, NextFlowId, NewPkt} ->
            update_flow_entry_counters(FlowTableId,
                                       FlowEntry,
                                       Pkt#ofs_pkt.size),
            {match, goto, NextFlowId, NewPkt};
        {match, output, NewPkt} ->
            update_flow_entry_counters(FlowTableId,
                                       FlowEntry,
                                       Pkt#ofs_pkt.size),
            {match, output, NewPkt};
        nomatch ->
            match_flow_entries(Pkt, FlowTableId, Rest)
    end;
match_flow_entries(_Pkt, _FlowTableId, []) ->
    table_miss.

-spec match_flow_entry(#ofs_pkt{}, #flow_entry{}) -> match | nomatch.
match_flow_entry(Pkt, FlowEntry) ->
    case match_fields(Pkt#ofs_pkt.fields#match.oxm_fields,
                      FlowEntry#flow_entry.match#match.oxm_fields) of
        match ->
            case apply_instructions(FlowEntry#flow_entry.instructions,
                                    Pkt,
                                    output) of
                {NewPkt, goto, NextFlowId} ->
                    {match, goto, NextFlowId, NewPkt};
                {NewPkt, output} ->
                    {match, output, NewPkt}
            end;
        nomatch ->
            nomatch
    end.

-spec match_fields(list(#oxm_field{}), list(#oxm_field{})) -> match | nomatch.
match_fields(PktFields, [FlowField | FlowRest]) ->
    case has_field(FlowField, PktFields) of
        true ->
            match_fields(PktFields, FlowRest);
        false ->
            nomatch
    end;
match_fields(_PktFields, []) ->
    match.

-spec has_field(#oxm_field{}, list(#oxm_field{})) -> boolean().
has_field(Field, List) ->
    lists:member(Field, List).

-spec apply_instructions(list(of_protocol:instruction()),
                         #ofs_pkt{},
                         output | {goto, integer()}) -> tuple().
apply_instructions([#instruction_apply_actions{actions = Actions} | Rest],
                   Pkt,
                   NextStep) ->
    NewPkt = apply_action_list(Actions, Pkt),
    apply_instructions(Rest, NewPkt, NextStep);
apply_instructions([#instruction_clear_actions{} | Rest], Pkt, NextStep) ->
    apply_instructions(Rest, Pkt#ofs_pkt{actions = []}, NextStep);
apply_instructions([#instruction_write_actions{actions = Actions} | Rest],
                   #ofs_pkt{actions = OldActions} = Pkt,
                   NextStep) ->
    UActions = lists:ukeysort(2, Actions),
    NewActions = lists:ukeymerge(2, UActions, OldActions),
    apply_instructions(Rest, Pkt#ofs_pkt{actions = NewActions}, NextStep);
apply_instructions([#instruction_write_metadata{metadata = Metadata,
                                                metadata_mask = Mask} | Rest],
                   Pkt,
                   NextStep) ->
    MaskedMetadata = apply_mask(Metadata, Mask),
    apply_instructions(Rest, Pkt#ofs_pkt{metadata = MaskedMetadata}, NextStep);
apply_instructions([#instruction_goto_table{table_id = Id} | Rest],
                   Pkt,
                   _NextStep) ->
    apply_instructions(Rest, Pkt, {goto, Id});
apply_instructions([], Pkt, output) ->
    {Pkt, output};
apply_instructions([], Pkt, {goto, Id}) ->
    {Pkt, goto, Id}.

-spec apply_mask(binary(), binary()) -> binary().
apply_mask(Metadata, Mask) ->
    Metadata.

-spec apply_action_list(list(ofp_structures:action()), #ofs_pkt{}) -> #ofs_pkt{}.
apply_action_list([#action_output{} = Output | Rest], Pkt) ->
    route_to_output(Output, Pkt),
    apply_action_list(Rest, Pkt);
apply_action_list([#action_group{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_set_queue{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_set_mpls_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_dec_mpls_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_set_nw_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_dec_nw_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_copy_ttl_out{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_copy_ttl_in{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_push_vlan{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_pop_vlan{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_push_mpls{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_pop_mpls{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_set_field{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_experimenter{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([], Pkt) ->
    Pkt.

-spec apply_action_set(ordsets:ordset(ofp_structures:action()), #ofs_pkt{})
                      -> #ofs_pkt{}.
apply_action_set([Action | Rest], Pkt) ->
    NewPkt = apply_action_list([Action], Pkt),
    apply_action_set(Rest, NewPkt);
apply_action_set([], Pkt) ->
    Pkt.

-spec route_to_controller(#ofs_pkt{}) -> ok.
route_to_controller(Pkt) ->
    of_channel:send(Pkt).

-spec route_to_output(#action_output{}, #ofs_pkt{}) -> ok.
route_to_output(Output, Pkt) ->
    ok.