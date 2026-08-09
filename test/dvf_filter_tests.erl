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

sample_csv() ->
    <<"id_mutation,date_mutation,nature_mutation,valeur_fonciere,type_local,"
      "surface_reelle_bati,nombre_pieces_principales,surface_terrain,"
      "nom_commune,code_departement,adresse_nom_voie,longitude,latitude\n"
      "2024-1,2024-01-11,Vente,105000,Maison,57,4,,Sarlat-la-Canéda,24,RUE X,1.22,44.89\n"
      "2024-2,2024-02-02,Vente,240000,Appartement,80,3,,Sarlat-la-Canéda,24,RUE Y,1.23,44.90\n"/utf8>>.

parse_csv_count_test() ->
    Rows = dvf_filter_app:parse_csv(sample_csv()),
    ?assertEqual(2, length(Rows)).

parse_csv_fields_test() ->
    [R1 | _] = dvf_filter_app:parse_csv(sample_csv()),
    ?assertEqual(<<"Maison">>, maps:get(<<"type_local">>, R1)),
    ?assertEqual(<<"105000">>, maps:get(<<"valeur_fonciere">>, R1)),
    ?assertEqual(<<"Vente">>,  maps:get(<<"nature_mutation">>, R1)).

parse_csv_empty_test() ->
    ?assertEqual([], dvf_filter_app:parse_csv(<<"">>)).

crit(Type, Min, Max) ->
    #{type => Type, min_price => Min, max_price => Max}.

filter_rows_by_type_test() ->
    Rows = dvf_filter_app:parse_csv(sample_csv()),
    Out = dvf_filter_app:filter_rows(Rows, crit(<<"maison">>, undefined, undefined)),
    ?assertEqual(1, length(Out)),
    ?assertEqual(<<"Maison">>, maps:get(<<"type_local">>, hd(Out))).

filter_rows_by_price_test() ->
    Rows = dvf_filter_app:parse_csv(sample_csv()),
    Out = dvf_filter_app:filter_rows(Rows, crit(undefined, 150000, 300000)),
    ?assertEqual(1, length(Out)),
    ?assertEqual(<<"240000">>, maps:get(<<"valeur_fonciere">>, hd(Out))).

filter_rows_drops_non_vente_test() ->
    Csv = <<"id_mutation,nature_mutation,valeur_fonciere,type_local,surface_terrain\n"
            "x,Echange,1,Maison,\n">>,
    Rows = dvf_filter_app:parse_csv(Csv),
    ?assertEqual([], dvf_filter_app:filter_rows(Rows, crit(undefined, undefined, undefined))).

embryo_shape_test() ->
    [R1 | _] = dvf_filter_app:parse_csv(sample_csv()),
    Src = "https://files.data.gouv.fr/geo-dvf/latest/csv/2024/communes/24/24520.csv",
    E = dvf_filter_app:row_to_embryo(R1, Src),
    P = maps:get(<<"properties">>, E),
    Url = maps:get(<<"url">>, P),
    ?assert(is_binary(Url)),
    ?assertNotEqual(nomatch, binary:match(Url, <<"2024-1">>)),
    Resume = maps:get(<<"resume">>, P),
    ?assertNotEqual(nomatch, binary:match(Resume, <<"Maison">>)),
    ?assertEqual(<<"105000">>, maps:get(<<"price">>, P)),
    ?assertEqual(<<"Maison">>, maps:get(<<"type">>, P)).

derive_type_maison_test() ->
    ?assertEqual(<<"maison">>, dvf_filter_app:derive_type(<<"maison sarlat">>)).

derive_type_phrase_test() ->
    ?assertEqual(<<"maison de village"/utf8>>,
                 dvf_filter_app:derive_type(<<"maison de village a sarlat"/utf8>>)).

derive_type_appartement_test() ->
    ?assertEqual(<<"appartement">>, dvf_filter_app:derive_type(<<"un appartement bordeaux">>)).

derive_type_none_test() ->
    ?assertEqual(undefined, dvf_filter_app:derive_type(<<"sarlat">>)).

derive_commune_test() ->
    ?assertEqual(<<"Sarlat-la-Canéda"/utf8>>,
                 dvf_filter_app:derive_commune(<<"maison Sarlat-la-Canéda"/utf8>>, <<"maison">>)).

derive_commune_no_type_test() ->
    ?assertEqual(<<"Bordeaux">>, dvf_filter_app:derive_commune(<<"Bordeaux">>, undefined)).

enrich_freetext_test() ->
    C0 = dvf_filter_app:extract_params(<<"maison Sarlat-la-Canéda"/utf8>>),
    C  = dvf_filter_app:enrich_criteria(C0),
    ?assertEqual(<<"maison">>, maps:get(type, C)),
    ?assertEqual(<<"Sarlat-la-Canéda"/utf8>>, maps:get(commune, C)).

enrich_keeps_structured_test() ->
    C0 = dvf_filter_app:extract_params(
           <<"{\"query\":\"x\",\"type\":\"appartement\",\"code_insee\":\"33063\"}">>),
    C  = dvf_filter_app:enrich_criteria(C0),
    ?assertEqual(<<"appartement">>, maps:get(type, C)),
    ?assertEqual(<<"33063">>, maps:get(code_insee, C)).

derive_type_substring_commune_test() ->
    %% Communes that merely contain a type word must NOT be parsed as that type.
    ?assertEqual(undefined, dvf_filter_app:derive_type(<<"Châteaudun"/utf8>>)),
    ?assertEqual(undefined, dvf_filter_app:derive_type(<<"Maisons-Laffitte">>)),
    ?assertEqual(undefined, dvf_filter_app:derive_type(<<"Châteauroux"/utf8>>)).

derive_commune_substring_preserved_test() ->
    ?assertEqual(<<"Châteaudun"/utf8>>,
                 dvf_filter_app:derive_commune(<<"Châteaudun"/utf8>>, undefined)),
    %% With a real leading type token, only that token is stripped:
    ?assertEqual(<<"Châteaudun"/utf8>>,
                 dvf_filter_app:derive_commune(<<"maison Châteaudun"/utf8>>, <<"maison">>)).

derive_type_wholeword_still_works_test() ->
    ?assertEqual(<<"maison">>, dvf_filter_app:derive_type(<<"maison sarlat">>)),
    ?assertEqual(<<"appartement">>, dvf_filter_app:derive_type(<<"appartement bordeaux">>)),
    ?assertEqual(<<"maison de village"/utf8>>,
                 dvf_filter_app:derive_type(<<"maison de village a uzes"/utf8>>)).

derive_commune_wholeword_test() ->
    ?assertEqual(<<"Sarlat-la-Canéda"/utf8>>,
                 dvf_filter_app:derive_commune(<<"maison Sarlat-la-Canéda"/utf8>>, <<"maison">>)),
    ?assertEqual(<<"uzes">>,
                 dvf_filter_app:derive_commune(<<"maison de village uzes">>, <<"maison de village">>)).

timeout_bad_value_test() ->
    C = dvf_filter_app:extract_params(<<"{\"query\":\"x\",\"timeout\":\"abc\"}">>),
    ?assertEqual(10, maps:get(timeout, C)).
