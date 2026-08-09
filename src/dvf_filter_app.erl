%%%-------------------------------------------------------------------
%%% @doc DVF real-estate transactions agent.
%%%
%%% Resolves a commune name to an INSEE code (BAN), downloads the Etalab
%%% per-commune DVF CSV, filters transactions by property type and price,
%%% and returns them as embryo maps.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(dvf_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).
-export([extract_params/1]).
-export([type_matches/2]).
-export([parse_csv/1]).
-export([filter_rows/2]).
-export([row_to_embryo/2]).
-export([derive_type/1, derive_commune/2, enrich_criteria/1]).
-export([resolve_insee/2, generate_embryo_list/1]).

-define(BAN_URL,  "https://api-adresse.data.gouv.fr/search/").
-define(DVF_BASE, "https://files.data.gouv.fr/geo-dvf/latest/csv/").

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"dvf">>, <<"real_estate">>,
                                      <<"immobilier">>, <<"foncier">>].

start(_Type, _Args) ->
    case dvf_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(dvf_filter_query_listener),
    catch em_pop_sup:stop_node(dvf_filter),
    ok.

start_pop_and_http() ->
    PopPort   = application:get_env(dvf_filter, pop_port,   9510),
    QueryPort = application:get_env(dvf_filter, query_port, 9511),
    Seeds     = application:get_env(dvf_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(dvf_filter),
    catch cowboy:stop_listener(dvf_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(dvf_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => dvf_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(dvf_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[dvf_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%%-------------------------------------------------------------------
%%% Pipeline: free-text -> commune resolution -> DVF CSV -> embryos
%%%-------------------------------------------------------------------

%% Full pipeline: parse -> enrich (free text) -> resolve INSEE -> fetch CSV per
%% year -> filter -> embryos, capped by max_results.
generate_embryo_list(Body) ->
    Crit = enrich_criteria(extract_params(Body)),
    case resolve_target(Crit) of
        undefined -> [];
        {Insee, Dep} ->
            {Years, MaxResults} = read_config(),
            Timeout = maps:get(timeout, Crit),
            Embryos =
                lists:append(
                  [ [ row_to_embryo(R, source_url(Y, Dep, Insee))
                      || R <- filter_rows(
                                parse_csv(fetch_csv(Y, Dep, Insee, Timeout)),
                                Crit) ]
                    || Y <- Years ]),
            lists:sublist(Embryos, MaxResults)
    end.

%% Explicit code_insee wins; else resolve the commune (or free-text value) via BAN.
resolve_target(Crit) ->
    case maps:get(code_insee, Crit) of
        Insee when is_binary(Insee), Insee =/= <<"">> ->
            {Insee, dep_of(Insee)};
        _ ->
            Name = first_nonempty([maps:get(commune, Crit),
                                   maps:get(value, Crit)]),
            resolve_insee(Name, maps:get(timeout, Crit))
    end.

first_nonempty([B | _]) when is_binary(B), B =/= <<"">> -> B;
first_nonempty([_ | T]) -> first_nonempty(T);
first_nonempty([]) -> <<"">>.

%% BAN commune lookup -> {Insee, Dep} | undefined.
resolve_insee(<<"">>, _Timeout) -> undefined;
resolve_insee(undefined, _Timeout) -> undefined;
resolve_insee(Name, Timeout) ->
    Url = ?BAN_URL ++ "?q=" ++ uri_string:quote(unicode:characters_to_list(Name))
          ++ "&type=municipality&limit=1",
    case http_get(Url, [{"Accept-Language", "fr"}], Timeout) of
        {ok, Body} ->
            try json:decode(Body) of
                #{<<"features">> := [F | _]} ->
                    P = maps:get(<<"properties">>, F, #{}),
                    Insee = maps:get(<<"citycode">>, P, <<>>),
                    Dep   = dep_from_context(maps:get(<<"context">>, P, <<>>)),
                    case Insee of
                        <<>> -> undefined;
                        _    -> {Insee, Dep}
                    end;
                _ -> undefined
            catch _:_ -> undefined end;
        error -> undefined
    end.

%% "24, Dordogne, Nouvelle-Aquitaine" -> <<"24">>
dep_from_context(Ctx) when is_binary(Ctx), Ctx =/= <<>> ->
    case binary:split(Ctx, [<<",">>]) of
        [Dep | _] -> string:trim(Dep);
        _         -> Ctx
    end;
dep_from_context(_) -> <<>>.

%% Fallback: derive department from an INSEE code (overseas = 3 chars).
dep_of(Insee) when is_binary(Insee) ->
    case Insee of
        <<"97", _/binary>> -> binary:part(Insee, 0, 3);
        <<"98", _/binary>> -> binary:part(Insee, 0, 3);
        _ when byte_size(Insee) >= 2 -> binary:part(Insee, 0, 2);
        _ -> Insee
    end.

source_url(Year, Dep, Insee) ->
    unicode:characters_to_list(
      [?DVF_BASE, Year, "/communes/", Dep, "/", Insee, ".csv"]).

fetch_csv(Year, Dep, Insee, Timeout) ->
    case http_get(source_url(Year, Dep, Insee), [], Timeout) of
        {ok, Body} -> Body;
        error      -> <<"">>
    end.

http_get(Url, ExtraHeaders, TimeoutSecs) ->
    Headers = [{"User-Agent", "dvf_filter/0.1 (EmergenceSystem)"} | ExtraHeaders],
    case httpc:request(get, {Url, Headers},
                       [{timeout, TimeoutSecs * 1000},
                        {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} -> {ok, Body};
        _ -> error
    end.

read_config() ->
    Default = {[<<"2024">>, <<"2023">>], 50},
    case file:read_file("dvf_config.json") of
        {ok, Bin} ->
            try json:decode(Bin) of
                Map when is_map(Map) ->
                    Years = case maps:get(<<"years">>, Map, undefined) of
                        L when is_list(L), L =/= [] -> L;
                        _ -> element(1, Default)
                    end,
                    Max = case maps:get(<<"max_results">>, Map, undefined) of
                        N when is_integer(N), N > 0 -> N;
                        _ -> element(2, Default)
                    end,
                    {Years, Max};
                _ -> Default
            catch _:_ -> Default end;
        _ -> Default
    end.

%%%-------------------------------------------------------------------
%%% Query parsing
%%%-------------------------------------------------------------------

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            #{
              value      => get_bin(Map, [<<"value">>, <<"query">>], <<"">>),
              type       => opt_bin(Map, <<"type">>),
              code_insee => opt_bin(Map, <<"code_insee">>),
              commune    => opt_bin(Map, <<"commune">>),
              min_price  => opt_int(Map, <<"min_price">>),
              max_price  => opt_int(Map, <<"max_price">>),
              timeout    => timeout_of(Map)
            };
        _ ->
            base_criteria(JsonBinary)
    catch
        _:_ -> base_criteria(JsonBinary)
    end.

base_criteria(Bin) ->
    #{value => Bin, type => undefined, code_insee => undefined,
      commune => undefined, min_price => undefined, max_price => undefined,
      timeout => 10}.

get_bin(Map, [K | Rest], Default) ->
    case maps:get(K, Map, undefined) of
        V when is_binary(V) -> V;
        _ -> get_bin(Map, Rest, Default)
    end;
get_bin(_Map, [], Default) -> Default.

opt_bin(Map, K) ->
    case maps:get(K, Map, undefined) of
        V when is_binary(V), V =/= <<"">> -> V;
        _ -> undefined
    end.

opt_int(Map, K) ->
    case maps:get(K, Map, undefined) of
        V when is_integer(V) -> V;
        V when is_binary(V) ->
            try binary_to_integer(V) catch _:_ -> undefined end;
        _ -> undefined
    end.

timeout_of(Map) ->
    case maps:get(<<"timeout">>, Map, undefined) of
        undefined            -> 10;
        T when is_integer(T) -> T;
        T when is_binary(T)  ->
            case catch binary_to_integer(T) of
                I when is_integer(I) -> I;
                _ -> 10
            end;
        _                    -> 10
    end.

%%%-------------------------------------------------------------------
%%% Free-text parsing
%%%-------------------------------------------------------------------

%% Ordered so multi-word phrases match before their prefixes.
-define(TYPE_VOCAB, [<<"maison de village"/utf8>>, <<"appartement">>,
                     <<"maison">>, <<"château"/utf8>>, <<"chateau">>,
                     <<"terrain">>, <<"immeuble">>]).

%% Split on whitespace (unicode-aware); drop empties.
tokens(Bin) when is_binary(Bin) ->
    [T || T <- re:split(Bin, "\\s+", [{return, binary}, unicode]), T =/= <<>>].

%% True if Sub occurs as a consecutive sublist of List.
contains_seq(_List, []) -> true;
contains_seq(List, Sub) ->
    starts_with(List, Sub) orelse
    (case List of [] -> false; [_ | T] -> contains_seq(T, Sub) end).

starts_with(_List, []) -> true;
starts_with([X | T1], [X | T2]) -> starts_with(T1, T2);
starts_with(_, _) -> false.

%% Find the first vocabulary term whose (lowercased) tokens appear as a
%% consecutive run of whole tokens in the (lowercased) value.
derive_type(Value) when is_binary(Value) ->
    LowToks = tokens(string:lowercase(Value)),
    find_type(?TYPE_VOCAB, LowToks).

find_type([], _Toks) -> undefined;
find_type([Term | Rest], Toks) ->
    case contains_seq(Toks, tokens(string:lowercase(Term))) of
        true  -> Term;
        false -> find_type(Rest, Toks)
    end.

%% Remove the first consecutive run of tokens matching Type (compared
%% lowercased) from Value's original-case tokens; return the rest joined,
%% or `undefined' if nothing remains.
derive_commune(Value, undefined) when is_binary(Value) ->
    join_commune(tokens(Value));
derive_commune(Value, Type) when is_binary(Value), is_binary(Type) ->
    Orig     = tokens(Value),
    Low      = tokens(string:lowercase(Value)),
    TermToks = tokens(string:lowercase(Type)),
    join_commune(remove_seq(Orig, Low, TermToks)).

%% Walk Orig/Low in lockstep; when Low starts with TermToks, drop that run
%% from Orig too. Only the first occurrence is removed.
remove_seq(Orig, Low, TermToks) ->
    case starts_with(Low, TermToks) of
        true  -> lists:nthtail(length(TermToks), Orig);
        false ->
            case {Orig, Low} of
                {[O | OT], [_ | LT]} -> [O | remove_seq(OT, LT, TermToks)];
                _ -> Orig
            end
    end.

join_commune([]) -> undefined;
join_commune(Toks) ->
    case string:trim(iolist_to_binary(lists:join(<<" ">>, Toks))) of
        <<>> -> undefined;
        Bin  -> Bin
    end.

%% Fill type/commune from the free-text `value' when they were not supplied
%% as structured fields (structured always wins).
enrich_criteria(Crit) ->
    Value = maps:get(value, Crit),
    Type = case maps:get(type, Crit) of
        undefined when is_binary(Value) -> derive_type(Value);
        T -> T
    end,
    Commune = case {maps:get(code_insee, Crit), maps:get(commune, Crit)} of
        {undefined, undefined} when is_binary(Value) -> derive_commune(Value, Type);
        {_, C} -> C
    end,
    Crit#{type => Type, commune => Commune}.

%%%-------------------------------------------------------------------
%%% Property-type vocabulary mapping
%%%-------------------------------------------------------------------

type_matches(undefined, _Row) -> true;
type_matches(Type, Row) ->
    T   = string:lowercase(Type),
    Loc = maps:get(<<"type_local">>, Row, <<>>),
    case T of
        <<"appartement">>          -> Loc =:= <<"Appartement">>;
        <<"maison">>               -> Loc =:= <<"Maison">>;
        <<"maison de village">>    -> Loc =:= <<"Maison">>;
        <<"terrain">>              -> Loc =:= <<>> andalso
                                      maps:get(<<"surface_terrain">>, Row, <<>>) =/= <<>>;
        <<"immeuble">>             -> best_effort(T, Row);
        <<"château"/utf8>>         -> best_effort(<<"chateau">>, Row);
        <<"chateau">>              -> best_effort(<<"chateau">>, Row);
        _                          -> true
    end.

best_effort(_Term, _Row) -> true.

%%%-------------------------------------------------------------------
%%% CSV parsing
%%%-------------------------------------------------------------------

parse_csv(Bin) when is_binary(Bin) ->
    case binary:split(Bin, [<<"\n">>], [global, trim]) of
        [] -> [];
        [Header | DataLines] ->
            Cols = binary:split(Header, [<<",">>], [global]),
            [row_map(Cols, binary:split(Line, [<<",">>], [global]))
             || Line <- DataLines, Line =/= <<>>]
    end.

row_map(Cols, Values) ->
    maps:from_list(zip_pad(Cols, Values)).

zip_pad([C | Cs], [V | Vs]) -> [{C, V} | zip_pad(Cs, Vs)];
zip_pad([C | Cs], [])       -> [{C, <<>>} | zip_pad(Cs, [])];
zip_pad([], _)              -> [].

%%%-------------------------------------------------------------------
%%% Row filtering
%%%-------------------------------------------------------------------

filter_rows(Rows, Crit) ->
    Type = maps:get(type, Crit, undefined),
    Min  = maps:get(min_price, Crit, undefined),
    Max  = maps:get(max_price, Crit, undefined),
    [R || R <- Rows,
          maps:get(<<"nature_mutation">>, R, <<>>) =:= <<"Vente">>,
          type_matches(Type, R),
          price_in_range(price_of(R), Min, Max)].

price_of(Row) ->
    case maps:get(<<"valeur_fonciere">>, Row, <<>>) of
        <<>> -> undefined;
        V    -> to_number(V)
    end.

to_number(Bin) ->
    S = binary_to_list(Bin),
    case string:to_float(S) of
        {error, no_float} ->
            case string:to_integer(S) of
                {error, _} -> undefined;
                {I, _}     -> I
            end;
        {F, _} -> trunc(F)
    end.

price_in_range(undefined, _Min, _Max) -> false;
price_in_range(_P, undefined, undefined) -> true;
price_in_range(P, Min, undefined) -> P >= Min;
price_in_range(P, undefined, Max) -> P =< Max;
price_in_range(P, Min, Max) -> P >= Min andalso P =< Max.

%%%-------------------------------------------------------------------
%%% Embryo building
%%%-------------------------------------------------------------------

row_to_embryo(Row, SourceUrl) ->
    Id      = get_field(Row, <<"id_mutation">>),
    Type    = get_field(Row, <<"type_local">>),
    Price   = get_field(Row, <<"valeur_fonciere">>),
    Surface = get_field(Row, <<"surface_reelle_bati">>),
    Pieces  = get_field(Row, <<"nombre_pieces_principales">>),
    Commune = get_field(Row, <<"nom_commune">>),
    Dep     = get_field(Row, <<"code_departement">>),
    Date    = get_field(Row, <<"date_mutation">>),
    Url    = unicode:characters_to_binary([SourceUrl, "#", Id]),
    Resume = unicode:characters_to_binary(
        io_lib:format("~ts ~ts m² ~ts pièces — ~ts € — ~ts (~ts) — ~ts",
            [b2l(Type), b2l(Surface), b2l(Pieces), b2l(Price),
             b2l(Commune), b2l(Dep), b2l(Date)])),
    Props = #{<<"url">> => Url, <<"resume">> => Resume,
              <<"price">> => Price, <<"type">> => Type,
              <<"location">> => unicode:characters_to_binary(
                                  [b2l(Commune), " (", b2l(Dep), ")"]),
              <<"surface">> => Surface, <<"source">> => <<"dvf.etalab.gouv.fr">>},
    #{<<"properties">> => Props}.

get_field(Row, K) -> maps:get(K, Row, <<>>).
b2l(B) when is_binary(B) -> unicode:characters_to_list(B);
b2l(_) -> "".
