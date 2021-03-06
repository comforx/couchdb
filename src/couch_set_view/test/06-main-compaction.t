#!/usr/bin/env escript
%% -*- erlang -*-

% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-define(MAX_WAIT_TIME, 600 * 1000).
-define(i2l(I), integer_to_list(I)).

% from couch_set_view.hrl
-record(set_view_params, {
    max_partitions = 0,
    active_partitions = [],
    passive_partitions = [],
    use_replica_index = false
}).

-record(set_view_index_header, {
    version,
    num_partitions = nil,
    abitmask = 0,
    pbitmask = 0,
    cbitmask = 0,
    seqs = [],
    purge_seqs = [],
    id_btree_state = nil,
    view_states = nil,
    has_replica = false,
    replicas_on_transfer = []
}).

-record(set_view_group, {
    sig = nil,
    fd = nil,
    set_name,
    name,
    def_lang,
    design_options = [],
    views,
    lib,
    id_btree = nil,
    query_server = nil,
    waiting_delayed_commit = nil,
    ref_counter = nil,
    index_header = nil,
    db_set = nil,
    type = main,
    replica_group = nil,
    replica_pid = nil
}).

test_set_name() -> <<"couch_test_set_index_main_compact">>.
num_set_partitions() -> 64.
ddoc_id() -> <<"_design/test">>.
num_docs() -> 123789.


main(_) ->
    test_util:init_code_path(),

    etap:plan(58),
    case (catch test()) of
        ok ->
            etap:end_tests();
        Other ->
            etap:diag(io_lib:format("Test died abnormally: ~p", [Other])),
            etap:bail(Other)
    end,
    ok.


test() ->
    couch_set_view_test_util:start_server(),

    couch_set_view_test_util:delete_set_dbs(test_set_name(), num_set_partitions()),
    couch_set_view_test_util:create_set_dbs(test_set_name(), num_set_partitions()),

    populate_set(),

    etap:diag("Verifying group snapshot before marking partitions [ 8 .. 31 ] for cleanup"),
    #set_view_group{index_header = Header0} = get_group_snapshot(false),
    etap:is(
        [P || {P, _} <- Header0#set_view_index_header.seqs],
        lists:seq(0, 31),
        "Right list of partitions in the header's seq field"),
    etap:is(
        Header0#set_view_index_header.has_replica,
        true,
        "Header has replica support flag set to true"),
    lists:foreach(
        fun({PartId, Seq}) ->
            DocCount = couch_set_view_test_util:doc_count(test_set_name(), [PartId]),
            etap:is(Seq, DocCount, "Right update seq for partition " ++ ?i2l(PartId))
        end,
        Header0#set_view_index_header.seqs),

    DiskSizeBefore = main_index_disk_size(),

    verify_group_info_before_cleanup_request(),
    ok = couch_set_view:set_partition_states(test_set_name(), ddoc_id(), [], [], lists:seq(8, 63)),
    verify_group_info_after_cleanup_request(),

    etap:diag("Triggering main group compaction"),
    {ok, CompactPid} = couch_set_view_compactor:start_compact(test_set_name(), ddoc_id(), main),
    etap:diag("Waiting for main group compaction to finish"),
    Ref = erlang:monitor(process, CompactPid),
    receive
    {'DOWN', Ref, process, CompactPid, normal} ->
        ok;
    {'DOWN', Ref, process, CompactPid, Reason} ->
        etap:bail("Failure compacting main group: " ++ couch_util:to_list(Reason))
    after ?MAX_WAIT_TIME ->
        etap:bail("Timeout waiting for main group compaction to finish")
    end,

    GroupInfo = get_main_group_info(),
    {Stats} = couch_util:get_value(stats, GroupInfo),
    etap:is(couch_util:get_value(compactions, Stats), 1, "Main group had 1 full compaction in stats"),
    etap:is(couch_util:get_value(cleanups, Stats), 1, "Main group had 1 full cleanup in stats"),

    verify_group_info_after_main_compact(),

    DiskSizeAfter = main_index_disk_size(),
    etap:is(DiskSizeAfter < DiskSizeBefore, true, "Index file size is smaller after compaction"),

    etap:diag("Verifying group snapshot after main group compaction"),
    #set_view_group{index_header = Header1} = get_group_snapshot(false),
    etap:is(
        [P || {P, _} <- Header1#set_view_index_header.seqs],
        lists:seq(0, 7),
        "Right list of partitions in the header's seq field"),
    etap:is(
        Header1#set_view_index_header.has_replica,
        true,
        "Header has replica support flag set to true"),
    etap:is(
        Header1#set_view_index_header.num_partitions,
        Header0#set_view_index_header.num_partitions,
        "Compaction preserved header field num_partitions"),
    lists:foreach(
        fun({PartId, Seq}) ->
            DocCount = couch_set_view_test_util:doc_count(test_set_name(), [PartId]),
            etap:is(Seq, DocCount, "Right update seq for partition " ++ ?i2l(PartId))
        end,
        Header1#set_view_index_header.seqs),

    couch_set_view_test_util:delete_set_dbs(test_set_name(), num_set_partitions()),
    ok = timer:sleep(1000),
    couch_set_view_test_util:stop_server(),
    ok.


get_group_snapshot(StaleType) ->
    {ok, Group} = couch_set_view:get_group(test_set_name(), ddoc_id(), StaleType),
    Group.


verify_group_info_before_cleanup_request() ->
    etap:diag("Verifying main group info before marking partitions [ 8 .. 31 ] for cleanup"),
    GroupInfo = get_main_group_info(),
    etap:is(
        couch_util:get_value(active_partitions, GroupInfo),
        lists:seq(0, 31),
        "Main group has [ 0 .. 31 ] as active partitions"),
    etap:is(
        couch_util:get_value(passive_partitions, GroupInfo),
        [],
        "Main group has [ ] as passive partitions"),
    etap:is(
        couch_util:get_value(cleanup_partitions, GroupInfo),
        [],
        "Main group has [ ] as cleanup partitions").


verify_group_info_after_cleanup_request() ->
    etap:diag("Verifying main group info after marking partitions [ 8 .. 31 ] for cleanup"),
    GroupInfo = get_main_group_info(),
    etap:is(
        couch_util:get_value(active_partitions, GroupInfo),
        lists:seq(0, 7),
        "Main group has [ 0 .. 7 ] as active partitions"),
    etap:is(
        couch_util:get_value(passive_partitions, GroupInfo),
        [],
        "Main group has [ ] as passive partitions"),
    CleanupParts = couch_util:get_value(cleanup_partitions, GroupInfo),
    etap:is(
        length(CleanupParts) > 0,
        true,
        "Main group has non-empty set of cleanup partitions"),
    etap:is(
        ordsets:intersection(CleanupParts, lists:seq(0, 7) ++ lists:seq(32, 63)),
        [],
        "Main group doesn't have any cleanup partition with ID in [ 0 .. 7, 32 .. 63 ]").


verify_group_info_after_main_compact() ->
    etap:diag("Verifying main group info after compaction"),
    GroupInfo = get_main_group_info(),
    etap:is(
        couch_util:get_value(active_partitions, GroupInfo),
        lists:seq(0, 7),
        "Main group has [ 0 .. 7 ] as active partitions"),
    etap:is(
        couch_util:get_value(passive_partitions, GroupInfo),
        [],
        "Main group has [ ] as passive partitions"),
    etap:is(
        couch_util:get_value(cleanup_partitions, GroupInfo),
        [],
        "Main group has [ ] as cleanup partitions").


get_main_group_info() ->
    {ok, MainInfo} = couch_set_view:get_group_info(test_set_name(), ddoc_id()),
    MainInfo.


main_index_disk_size() ->
    Info = get_main_group_info(),
    Size = couch_util:get_value(disk_size, Info),
    true = is_integer(Size),
    true = (Size >= 0),
    Size.


populate_set() ->
    couch_set_view:cleanup_index_files(test_set_name()),
    etap:diag("Populating the " ++ ?i2l(num_set_partitions()) ++
        " databases with " ++ ?i2l(num_docs()) ++ " documents"),
    DDoc = {[
        {<<"_id">>, ddoc_id()},
        {<<"language">>, <<"javascript">>},
        {<<"views">>, {[
            {<<"test">>, {[
                {<<"map">>, <<"function(doc) { emit(doc._id, null); }">>},
                {<<"reduce">>, <<"_count">>}
            ]}}
        ]}}
    ]},
    ok = couch_set_view_test_util:update_ddoc(test_set_name(), DDoc),
    DocList = lists:map(
        fun(I) ->
            {[
                {<<"_id">>, iolist_to_binary(["doc", ?i2l(I)])},
                {<<"value">>, I}
            ]}
        end,
        lists:seq(1, num_docs())),
    ok = couch_set_view_test_util:populate_set_sequentially(
        test_set_name(),
        lists:seq(0, num_set_partitions() - 1),
        DocList),
    etap:diag("Configuring set view with partitions [0 .. 31] as active"),
    Params = #set_view_params{
        max_partitions = num_set_partitions(),
        active_partitions = lists:seq(0, 31),
        passive_partitions = [],
        use_replica_index = true
    },
    ok = couch_set_view:define_group(test_set_name(), ddoc_id(), Params).
