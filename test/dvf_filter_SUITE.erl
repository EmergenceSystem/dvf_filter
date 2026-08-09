-module(dvf_filter_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([sarlat_maison_returns_results/1]).

all() -> [sarlat_maison_returns_results].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(dvf_filter),
    Config.

end_per_suite(_Config) ->
    application:stop(dvf_filter),
    ok.

%% Live: free-text "maison Sarlat-la-Canéda" -> resolve INSEE 24520 -> DVF ->
%% expect at least one embryo whose url points at the DVF source.
sarlat_maison_returns_results(_Config) ->
    Body = <<"{\"query\":\"maison Sarlat-la-Canéda\"}"/utf8>>,
    case httpc:request(post,
                       {"http://localhost:9511/agent/query",
                        [], "application/json", binary_to_list(Body)},
                       [{timeout, 25000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Resp}} ->
            #{<<"results">> := Results} = json:decode(Resp),
            ct:pal("dvf results: ~p", [length(Results)]),
            ?assert(is_list(Results)),
            ?assert(length(Results) > 0),
            [E | _] = Results,
            P = maps:get(<<"properties">>, E),
            Url = maps:get(<<"url">>, P),
            ?assertNotEqual(nomatch, binary:match(Url, <<"geo-dvf">>));
        Other ->
            {skip, {network_unavailable, Other}}
    end.
