# dvf_filter

em_filter agent for French real-estate transactions (DVF — Demandes de Valeurs
Foncières). Resolves a commune via the BAN address API, downloads Etalab's
per-commune DVF CSV export, and returns matching transactions as embryos.


<!-- emergence-context -->
Part of **[EmergenceSystem](https://github.com/EmergenceSystem)** — a distributed
discovery network of small, single-source agents. This filter joins the em_pop gossip
mesh and answers `POST /agent/query`; Emquest fans each query out to many filters in
parallel and aggregates the results.

## Query

Called over the em-pop `/agent/query` contract with a JSON body `{"query": "<text>"}`.
Because the transport forwards only the `query` string, criteria are parsed from
free text:

- a property-type keyword is detected: appartement, maison, maison de village,
  terrain, immeuble, château (best-effort)
- the remaining words are treated as the commune name and resolved to an INSEE
  code via BAN

Example: `maison Sarlat-la-Canéda`, `appartement Bordeaux`.

A structured JSON body (`type`, `code_insee`, `commune`, `min_price`,
`max_price`) is also honored when a caller bypasses the string-only transport
(e.g. direct testing).

## Config

`dvf_config.json` (copy from `dvf_config.json.sample`):

- `years` — DVF export years to query, e.g. `["2024","2023"]`
- `max_results` — cap on returned embryos

## Note

DVF is **historical sold-transaction** data, not live listings — it provides
market/price context. Live listings are handled separately (see the project's
Feature B: email-alert ingestion).

## Ports

gossip 9510, query 9511.
