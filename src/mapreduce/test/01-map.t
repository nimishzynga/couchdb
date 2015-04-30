#!/usr/bin/env escript
%% -*- Mode: Erlang; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */
%%! -smp enable

% @copyright 2012 Couchbase, Inc.
%
% @author Filipe Manana  <filipe@couchbase.com>
%
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

-define(etap_match(Got, Expected, Desc),
        etap:fun_is(fun(XXXXXX) ->
            case XXXXXX of Expected -> true; _ -> false end
        end, Got, Desc)).

main(_) ->
    test_util:init_code_path(),
    etap:plan(126),
    case (catch test()) of
        ok ->
            etap:end_tests();
        Other ->
            etap:diag(io_lib:format("Test died abnormally: ~p", [Other])),
            etap:bail(Other)
    end,
    ok.


test() ->
    test_map_function_bad_syntax(),
    test_map_function_throw_exception(),
    test_map_function_runtime_error(),
    test_multiple_map_functions_runtime_errors(),
    test_empty_results_single_function(),
    test_log_function(),
    test_multi_log_function(),
    test_long_log_function(),
    test_diffent_log_type_function(),
    test_empty_results_multiple_functions(),
    test_single_results_single_function(),
    test_single_results_single_function_meta(),
    test_single_results_multiple_functions(),
    test_multiple_results_single_function(),
    test_multiple_results_multiple_functions(),
    test_consecutive_maps(),
    test_utf8(),
    test_too_much_emit_kv_data_per_doc(),
    test_too_much_emit_key_data_per_doc(),
    test_burst(1000),
    test_burst(10000),
    test_burst(100000),
    test_parallel_burst_maps(25000, 5),
    test_parallel_burst_maps(25000, 10),
    test_parallel_burst_maps(25000, 20),
    ok = mapreduce:set_timeout(1000),
    test_context_is_usable_after_timeout(),
    test_many_timeouts(1),
    test_many_timeouts(5),
    test_many_timeouts(10),
    test_half_timeouts(10),
    ok.


test_map_function_bad_syntax() ->
    Result = start_map_context([<<"function(doc) { emit(doc._id, 1); ">>]),
    etap:is(element(1, Result), error, "Got error when specifying map function with bad syntax"),
    etap:is(is_binary(element(2, Result)), true, "Error reason is a binary"),
    ok.


test_map_function_throw_exception() ->
    {ok, Ctx} = start_map_context([<<"function(doc) { throw('foobar'); }">>]),
    Results = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    etap:is(Results, {ok, [{error, <<"foobar">>}]},
            "Got error when map function throws exception").


test_map_function_runtime_error() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { emit(doc.foo.bar.z, null); }">>
    ]),
    Results = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    % {error,<<"TypeError: Cannot read property 'bar' of undefined">>}
    ?etap_match(Results, {ok, [{error, _}]}, "Got an error when map function applied over doc"),
    {ok, [{error, Reason}]} = Results,
    etap:is(is_binary(Reason), true, "Error reason is a binary"),

    {ok, Ctx2} = start_map_context([
        <<"function(doc, meta) { if (jsonType == 'player') { emit(meta.id, doc); } }">>
    ]),
    Results2 = map_doc(Ctx2, <<"{\"value\": 1}">>, <<"{}">>),
    ?etap_match(Results2, {ok, [{error, _}]}, "Got error mapping document"),
    {ok, [{error, Reason2}]} = Results2,
    etap:is(is_binary(Reason2), true, "Error reason is a binary").


test_multiple_map_functions_runtime_errors() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { if (doc.value % 2 == 0) { emit(doc.foo.bar.z, null); } else { emit(doc.value, null); } }">>,
        <<"function(doc) { emit(doc.value * 3, null); }">>,
        <<"function(doc) { if (doc.value % 3 == 0) { throw('foobar'); } else { emit(doc.value * 2, 1); } }">>
    ]),
    Result1 = map_doc(Ctx, <<"{\"value\":1}">>, <<"{}">>),
    etap:is(Result1,
            {ok, [[{<<"1">>, <<"null">>}], [{<<"3">>, <<"null">>}], [{<<"2">>, <<"1">>}]]},
            "Got expected result for doc 1"),
    Result2 = map_doc(Ctx, <<"{\"value\":2}">>, <<"{}">>),
    ?etap_match(Result2,
                {ok, [{error, _}, [{<<"6">>, <<"null">>}], [{<<"4">>, <<"1">>}]]},
                "Got expected result for doc 2"),
    Result3 = map_doc(Ctx, <<"{\"value\":3}">>, <<"{}">>),
    ?etap_match(Result3,
                {ok, [[{<<"3">>, <<"null">>}], [{<<"9">>, <<"null">>}], {error, <<"foobar">>}]},
                "Got expected result for doc 3"),
    Result4 = map_doc(Ctx, <<"{\"value\":4}">>, <<"{}">>),
    ?etap_match(Result4,
                {ok, [{error, _}, [{<<"12">>, <<"null">>}], [{<<"8">>, <<"1">>}]]},
                "Got expected result for doc 4"),
    Result12 = map_doc(Ctx, <<"{\"value\":12}">>, <<"{}">>),
    ?etap_match(Result12,
                {ok, [{error, _}, [{<<"36">>, <<"null">>}], {error, <<"foobar">>}]},
                "Got expected result for doc 12"),
    ok.


test_empty_results_single_function() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { if (doc.type === 'foobar') { emit(doc._id, null); } }">>
    ]),
    Results = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    etap:is(Results, {ok, [[]]}, "Map function didn't emit any key").

test_log_function() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { log(doc._id);emit(doc._id, null); }">>
    ]),
    Results = map_doc_with_log(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    etap:is(Results, {ok,[[{<<"\"doc1\"">>,<<"null">>}]],[<<"doc1">>]}, "Log was correct").

test_multi_log_function() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) {log(\"this is log\" + doc._id);emit(doc._id, null);"
            "log(\"this is second log\")}">>
    ]),
    Results = map_doc_with_log(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    Expected =  {ok,[[{<<"\"doc1\"">>,<<"null">>}]],
                     [<<"this is logdoc1">>,<<"this is second log">>]},
    etap:is(Results, Expected, "Multiple logs were correct").

test_long_log_function() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { var d = \"\"; for (i=0;i<1027;i++) { d = d + \"a\";}log(d);}">>
    ]),
    Results = map_doc_with_log(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    Expected = {ok,[[]], [create_msg(1024)]},
    etap:is(Results, Expected, "Long log was correct").

test_diffent_log_type_function() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) {log(\"this is log\" + 4);emit(doc._id, null); log(4)}">>
    ]),
    Results = map_doc_with_log(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    Expected = {ok,[[{<<"\"doc1\"">>,<<"null">>}]],
                     [<<"this is log4">>,
                      <<"Error while logging:Log value is not a string">>]},
    etap:is(Results, Expected, "Different logs type were correct").

test_empty_results_multiple_functions() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { if (doc.type === 'foobar') { emit(doc._id, doc._id); } }">>,
        <<"function(doc) { if (doc.type === '123') { emit(doc._id, 123); } }">>,
        <<"function(doc) { }">>
    ]),
    Results = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    etap:is(Results, {ok, [[], [], []]}, "Map functions didn't emit any keys").


test_single_results_single_function() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { emit(doc._id, null); }">>
    ]),
    Results = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    etap:is(Results, {ok, [[{<<"\"doc1\"">>, <<"null">>}]]}, "Map function emitted 1 key").

test_single_results_single_function_meta() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc, meta) { emit(meta.id, null); }">>
    ]),
    Results = map_doc(Ctx, <<"{\"value\": 1}">>, <<"{\"id\": \"doc1\"}">>),
    etap:is(Results, {ok, [[{<<"\"doc1\"">>, <<"null">>}]]}, "Map function emitted 1 key from meta").

test_single_results_multiple_functions() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { if (doc.type === 'foobar') { emit(doc._id, doc._id); } }">>,
        <<"function(doc) { emit(doc._id, null); }">>,
        <<"function(doc) { if (doc.type === '123') { emit(doc._id, 123); } }">>
    ]),
    Results = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    etap:is(Results, {ok, [[], [{<<"\"doc1\"">>, <<"null">>}], []]}, "Map functions emitted 1 key").


test_multiple_results_single_function() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { emit(doc._id, 1); emit(doc._id, 2); }">>
    ]),
    Results = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    Expected = [[{<<"\"doc1\"">>, <<"1">>}, {<<"\"doc1\"">>, <<"2">>}]],
    etap:is(Results, {ok, Expected}, "Map function emitted 2 keys").


test_multiple_results_multiple_functions() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { emit(doc._id, 1); emit(doc._id, 2); }">>,
        <<"function(doc) { emit(doc._id, null); }">>
    ]),
    Results = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    Expected = [
        [{<<"\"doc1\"">>, <<"1">>}, {<<"\"doc1\"">>, <<"2">>}],
        [{<<"\"doc1\"">>, <<"null">>}]
    ],
    etap:is(Results, {ok, Expected}, "Map function emitted 3 keys").


test_consecutive_maps() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { emit(doc._id, doc.value); }">>,
        <<"function(doc) { emit(doc._id, doc.value * 3); }">>
    ]),
    Results1 = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": 1}">>, <<"{}">>),
    Results2 = map_doc(Ctx, <<"{\"_id\": \"doc2\", \"value\": 2}">>, <<"{}">>),
    Results3 = map_doc(Ctx, <<"{\"_id\": \"doc3\", \"value\": 3}">>, <<"{}">>),
    Expected1 = [[{<<"\"doc1\"">>, <<"1">>}], [{<<"\"doc1\"">>, <<"3">>}]],
    Expected2 = [[{<<"\"doc2\"">>, <<"2">>}], [{<<"\"doc2\"">>, <<"6">>}]],
    Expected3 = [[{<<"\"doc3\"">>, <<"3">>}], [{<<"\"doc3\"">>, <<"9">>}]],
    etap:is(Results1, {ok, Expected1}, "First iteration results are correct"),
    etap:is(Results2, {ok, Expected2}, "Second iteration results are correct"),
    etap:is(Results3, {ok, Expected3}, "Third iteration results are correct").


test_burst(N) ->
    Results = do_burst(N),
    ExpectedResults = [
        [[{list_to_binary(["\"", integer_to_list(I), "\""]), list_to_binary(integer_to_list(I))}]]
            || I <- lists:seq(1, N)
    ],
    etap:is(
        Results,
        ExpectedResults,
        "Correct results after a burst of " ++ integer_to_list(N) ++ " maps").


do_burst(N) ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { emit(doc._id, doc.value); }">>
    ]),
    lists:foldr(
        fun(I, Acc) ->
            Doc = io_lib:format("{\"_id\": \"~p\", \"value\": ~p}", [I, I]),
            {ok, Res} = map_doc(Ctx, Doc, <<"{}">>),
            [Res | Acc]
        end,
        [], lists:seq(1, N)).


test_parallel_burst_maps(N, NumWorkers) ->
    Pids = lists:map(
        fun(_) ->
            spawn_monitor(fun() -> exit({ok, do_burst(N)}) end)
        end, lists:seq(1, NumWorkers)),
    ExpectedResults = [
        [[{list_to_binary(["\"", integer_to_list(I), "\""]), list_to_binary(integer_to_list(I))}]]
            || I <- lists:seq(1, N)
    ],
    lists:foreach(
        fun({Pid, Ref}) ->
            receive
            {'DOWN', Ref, process, Pid, {ok, Value}} ->
                etap:is(
                    Value,
                    ExpectedResults,
                    "Worker returned correct result for a burst of " ++
                        integer_to_list(N) ++ " maps");
            {'DOWN', Ref, process, Pid, _Reason} ->
                etap:bail("Worker died unexpectedly")
            after 120000 ->
                etap:bail("Timeout waiting for worker result")
            end
        end,
        Pids).


test_utf8() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc) { emit(doc._id, doc.value); }">>
    ]),

    Results1 = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": \"\\u00c1\"}">>, <<"{}">>),
    ExpectedResults1 = {ok, [[{<<"\"doc1\"">>, <<"\"", 195, 129, "\"">>}]]},
    Results2 = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": \"", 195, 129, "\"}">>, <<"{}">>),
    ExpectedResults2 = {ok, [[{<<"\"doc1\"">>, <<"\"", 195, 129, "\"">>}]]},
    etap:is(Results1, ExpectedResults1, "Right map value with A with accent"),
    etap:is(Results2, ExpectedResults2, "Right map value with A with accent"),

    Results3 = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": \"\\u0179\"}">>, <<"{}">>),
    ExpectedResults3 = {ok, [[{<<"\"doc1\"">>, <<"\"", 197, 185, "\"">>}]]},
    Results4 = map_doc(Ctx, <<"{\"_id\": \"doc1\", \"value\": \"", 197, 185, "\"}">>, <<"{}">>),
    ExpectedResults4 = {ok, [[{<<"\"doc1\"">>, <<"\"", 197, 185, "\"">>}]]},
    etap:is(Results3, ExpectedResults3, "Right map value with Z with acute"),
    etap:is(Results4, ExpectedResults4, "Right map value with Z with acute"),
    ok.


test_too_much_emit_kv_data_per_doc() ->
    ok = mapreduce:set_max_kv_size_per_doc(500),
    {ok, Ctx} = start_map_context([
        <<"function(doc, meta) {",
          "    for (var i = 0; i < 100; i++) {",
          "        emit(doc.value, doc._id); ",
          "    }",
          "}">>,
        <<"function(doc, meta) {",
          "    emit(doc.value, doc._id); ",
          "}">>
    ]),

    Results = map_doc(
        Ctx, <<"{\"_id\": \"doc1\", \"value\": \"foobar\"}">>, <<"{}">>),
    ExpectedResults = {ok, [
        {error, <<"too much data emitted: 504 bytes">>},
        [{<<"\"foobar\"">>, <<"\"doc1\"">>}]
    ]},
    etap:is(Results, ExpectedResults, "Got max emit kv size reached error"),
    ok = mapreduce:set_max_kv_size_per_doc(1 * 1024 * 1024).

test_too_much_emit_key_data_per_doc() ->
    {ok, Ctx} = start_map_context([
        <<"function(doc, meta) {",
		"var key = doc._id;\n"
                "while (key.length < 4096) {\n"
                "    key = key.concat(key);\n"
                "}\n"
                "emit(key, null);\n"
          "}">>
    ]),

    Results = map_doc(
        Ctx, <<"{\"_id\": \"doc1\", \"value\": \"foobar\"}">>, <<"{}">>),
    ExpectedResults = {ok, [
        {error, <<"too long key emitted: 4098 bytes">>}
    ]},
    etap:is(Results, ExpectedResults, "Got max emit key size reached error").


test_many_timeouts(NumProcesses) ->
    Pids = lists:map(
        fun(_) ->
            spawn_monitor(fun() ->
                {ok, Ctx} = start_map_context([
                    <<"function(doc) { while (true) { }; }">>
                ]),
                Doc = <<"{\"_id\": \"doc1\", \"value\": 1}">>,
                exit({ok, map_doc(Ctx, Doc, <<"{}">>)})
            end)
        end,
        lists:seq(1, NumProcesses)),
    lists:foreach(
        fun({Pid, Ref}) ->
            receive
            {'DOWN', Ref, process, Pid, {ok, Value}} ->
                etap:is(Value, {error, <<"timeout">>}, "Worker got timeout error");
            {'DOWN', Ref, process, Pid, _Reason} ->
                etap:bail("Worker died unexpectedly")
            after 120000 ->
                etap:bail("Timeout waiting for worker result")
            end
        end,
        Pids).

test_context_is_usable_after_timeout() ->
    Doc1 = <<"{\"_id\": \"doc1\", \"value\": 1}">>,
    Doc2 = <<"{\"_id\": \"doc2\", \"value\": 1}">>,
    NumProcesses = 30,
    Pids = lists:map(
        fun(_) ->
            spawn_monitor(fun() ->
                {ok, Ctx} = start_map_context([
                    <<"function(doc) { if (doc._id == \"doc1\") {while (true) { };} else {emit(doc._id, null)} }">>
                ]),
                erlang:bump_reductions(100000),
                RVs = [map_doc(Ctx, D, <<"{}">>) || D <- [Doc1, Doc2]],
                exit({ok, RVs})
            end)
        end,
        lists:seq(1, NumProcesses)),
    lists:foreach(
        fun({Pid, Ref}) ->
            receive
            {'DOWN', Ref, process, Pid, {ok, Value}} ->
                etap:is(Value, [{error, <<"timeout">>}, {ok, [[{<<"\"doc2\"">>, <<"null">>}]]}], "Worker got timeout error and value");
            {'DOWN', Ref, process, Pid, _Reason} ->
                etap:bail("Worker died unexpectedly")
            after 120000 ->
                etap:bail("Timeout waiting for worker result")
            end
        end,
        Pids).


test_half_timeouts(NumProcesses) ->
    Pids = lists:map(
        fun(I) ->
            spawn_monitor(fun() ->
                FunSrc = case I rem 2 of
                0 ->
                    <<"function(doc) { while (true) { }; }">>;
                1 ->
                    <<"function(doc) { emit(doc._id, doc.value); }">>
                end,
                {ok, Ctx} = start_map_context([FunSrc]),
                Doc = <<"{\"_id\": \"doc1\", \"value\": 1}">>,
                exit({ok, map_doc(Ctx, Doc, <<"{}">>)})
            end)
        end,
        lists:seq(1, NumProcesses)),
    lists:foreach(
        fun({I, {Pid, Ref}}) ->
            receive
            {'DOWN', Ref, process, Pid, {ok, Value}} ->
                case I rem 2 of
                0 ->
                    etap:is(Value, {error, <<"timeout">>}, "Worker " ++ integer_to_list(I) ++ " got timeout error");
                1 ->
                    etap:is(Value, {ok, [[{<<"\"doc1\"">>, <<"1">>}]]}, "Worker " ++ integer_to_list(I) ++ " got correct result")
                end;
            {'DOWN', Ref, process, Pid, _Reason} ->
                etap:bail("Worker died unexpectedly")
            after 120000 ->
                etap:bail("Timeout waiting for worker result")
            end
        end,
        lists:zip(lists:seq(1, NumProcesses), Pids)).

map_doc(Ctx, Doc, Meta) ->
    case mapreduce:map_doc(Ctx, Doc, Meta) of
    {ok, Ret, _Log} ->
        {ok, Ret};
    Other ->
        Other
    end.

map_doc_with_log(Ctx, Doc, Meta) ->
    mapreduce:map_doc(Ctx, Doc, Meta).

start_map_context(MapFunSources) ->
    mapreduce:start_map_context(mapreduce_view, MapFunSources).

create_msg(N) ->
    Data = string:copies("a", N),
    list_to_binary(string:concat("Truncated: ", Data)).
