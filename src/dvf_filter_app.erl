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
