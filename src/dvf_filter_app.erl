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
    {[], Memory};
handle(_Body, Memory) ->
    {[], Memory}.

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
        T when is_binary(T)  -> (catch binary_to_integer(T));
        _                    -> 10
    end.

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
