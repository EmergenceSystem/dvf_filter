-module(dvf_filter_tests).
-include_lib("eunit/include/eunit.hrl").

extract_params_structured_test() ->
    Json = <<"{\"value\":\"maison Sarlat\",\"type\":\"maison\","
             "\"code_insee\":\"24520\",\"min_price\":\"100000\","
             "\"max_price\":\"300000\",\"timeout\":15}">>,
    C = dvf_filter_app:extract_params(Json),
    ?assertEqual(<<"maison Sarlat">>, maps:get(value, C)),
    ?assertEqual(<<"maison">>,        maps:get(type, C)),
    ?assertEqual(<<"24520">>,         maps:get(code_insee, C)),
    ?assertEqual(100000,              maps:get(min_price, C)),
    ?assertEqual(300000,              maps:get(max_price, C)),
    ?assertEqual(15,                  maps:get(timeout, C)).

extract_params_freetext_only_test() ->
    Json = <<"{\"query\":\"château Dordogne\"}"/utf8>>,
    C = dvf_filter_app:extract_params(Json),
    ?assertEqual(<<"château Dordogne"/utf8>>, maps:get(value, C)),
    ?assertEqual(undefined, maps:get(type, C)),
    ?assertEqual(undefined, maps:get(code_insee, C)),
    ?assertEqual(undefined, maps:get(min_price, C)),
    ?assertEqual(10, maps:get(timeout, C)).

extract_params_bad_json_test() ->
    C = dvf_filter_app:extract_params(<<"not json">>),
    ?assertEqual(<<"not json">>, maps:get(value, C)),
    ?assertEqual(10, maps:get(timeout, C)).

row(TypeLocal, SurfaceTerrain) ->
    #{<<"type_local">> => TypeLocal,
      <<"surface_terrain">> => SurfaceTerrain,
      <<"adresse_nom_voie">> => <<"RUE DU CHATEAU">>,
      <<"nom_commune">> => <<"Sarlat-la-Canéda"/utf8>>}.

type_undefined_matches_all_test() ->
    ?assert(dvf_filter_app:type_matches(undefined, row(<<"Maison">>, <<>>))).

type_maison_test() ->
    ?assert(dvf_filter_app:type_matches(<<"maison">>, row(<<"Maison">>, <<>>))),
    ?assert(dvf_filter_app:type_matches(<<"maison de village">>, row(<<"Maison">>, <<>>))),
    ?assertNot(dvf_filter_app:type_matches(<<"maison">>, row(<<"Appartement">>, <<>>))).

type_appartement_test() ->
    ?assert(dvf_filter_app:type_matches(<<"appartement">>, row(<<"Appartement">>, <<>>))),
    ?assertNot(dvf_filter_app:type_matches(<<"appartement">>, row(<<"Maison">>, <<>>))).

type_terrain_test() ->
    ?assert(dvf_filter_app:type_matches(<<"terrain">>, row(<<>>, <<"1200">>))),
    ?assertNot(dvf_filter_app:type_matches(<<"terrain">>, row(<<"Maison">>, <<>>))).

type_chateau_besteffort_test() ->
    ?assert(dvf_filter_app:type_matches(<<"château"/utf8>>, row(<<"Maison">>, <<>>))).
