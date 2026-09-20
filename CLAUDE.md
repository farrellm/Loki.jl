# Loki.jl

Interactive time-series analysis on CausalFrames: a graph of `CausalPipeline`s
and time-series operators, diagnostics, a browser UI and MCP server, and export
of the graph as a plain Julia script.

**DESIGN.md is the source of truth for the design and must be kept in sync
with any API or semantics change.** Its "Milestones" section is the roadmap;
Milestones 0 (scaffolding), 1 (operators, `insample`, graph, engine), 2
(`emit`, `exportjulia`, table snapshots, `.loki.json`), 3 (diagnostics, events,
the HTTP server and WebSocket, and the web app) and 4 (MCP mode) are done;
Milestone 5 (breadth) is next.

## Layout

- `src/timeseries/`: operators (`operators.jl`) and their summarizer kernels
  (`summarizers.jl`: Lags, EMA, ARMA); `src/acausal.jl` is the opt-in
  `Loki.Acausal` module
- `src/registry.jl`: the node-kind interface (ports, `Param` specs, `build`)
  and the JSON Schema the inspector and MCP tools share; `src/nodes/` holds the
  kinds: `causalframes.jl` wraps CausalFrames' operators one to one,
  `timeseries.jl` Loki's operators and the fit node
- `src/graph.jl` (nodes, edges), `compile.jl` (pipelines per node, cache
  substitution, `NodeError`), `engine.jl` (result cache, runs on a worker
  task), `session.jl` (the session and its lock), `usercode.jl`
- `src/events.jl`: session events, broadcast under the lock with a monotonic
  `seq`; `src/server.jl`: static bundle, REST API, WebSocket, access control;
  `src/mcp.jl`: the MCP tools and resources, and `serve_mcp`
- `src/export.jl` (`exportjulia` and its printer), `persist.jl` (`.loki.json`),
  `tables.jl` (table snapshots)
- `web/src/`: React app: `api.ts` REST client, `ws.ts` event socket,
  `store.ts` state, `components/`; `web/tests/server.jl` is the seeded session
  Playwright drives

## Commands

- Run tests: `julia --project -e 'using Pkg; Pkg.test()'` (Aqua, and on
  released Julia versions the targeted JET checks in `test/jet.jl`)
- A test file cannot be `include`d on its own: `persist.jl` needs `simulate`
  from `arma.jl` and `comparable` from `export.jl`, and all of them need
  `fixtures.jl`. Run the whole suite — it takes about five minutes
- Build docs: `julia --project=docs docs/make.jl` (one-time setup:
  `julia --project=docs -e 'using Pkg; Pkg.instantiate()'`; `docs/Project.toml`
  sources Loki from `..`, so after adding a dependency run
  `julia --project=docs -e 'using Pkg; Pkg.resolve()'` or the build fails to
  load Loki). Documenter runs strict — **any** docstring, exported or not, that
  is not in a `@docs` block fails the build, and an `@ref` to a CausalFrames
  name does not resolve. The home page is **generated from `README.md`**;
  `docs/src/index.md` is gitignored, so edit the README
- Formatting is automatic: a `Stop` hook in `.claude/settings.json` formats
  modified `.jl` files once per turn (config in `.JuliaFormatter.toml`; CI
  pins JuliaFormatter v2, so don't format with a v1 install)
- Run one Julia process at a time — concurrent test/docs runs race on the
  precompile cache and fail transiently
- Golden files live in `test/golden/` and end in `.jl.txt`, not `.jl`: the
  formatting hook rewrites every modified `*.jl`, and a golden script has to
  stay exactly as the exporter printed it. Regenerate with
  `LOKI_UPDATE_GOLDEN=1 julia --project -e 'using Pkg; Pkg.test()'`
- Add a dependency: `julia --project -e 'using Pkg; Pkg.add("Name")'`, then a
  `[compat]` entry (Aqua checks it). Julia 1.12's `Pkg.add` writes its own
  `[compat]` line too — remove the duplicate. Test-only deps go in `[extras]`
  and `[targets]` instead. Only add a dependency in the commit that first uses
  it — Aqua's stale-deps check fails on an unused one
- CI tests Julia 1.12 (minimum supported) and pre-release — don't use
  post-1.12 language or stdlib features
- The default branch is `master`, not `main` — target PRs there
- Web app: `cd web && npm ci`, then `npm run build` (writes `assets/web`, which
  is gitignored — build it or the server serves a "not built" page), `npm test`
  (vitest) and `npm run test:e2e` (Playwright: desktop Chromium and WebKit on an
  iPhone profile, against a live `Loki.serve()` that `playwright.config.ts`
  starts). The `web` CI job runs all three, plus lint and format:check. WebKit
  needs system libraries that `npx playwright install --with-deps` installs
  with root; without them, run the desktop project only. For hot reload, run
  `npm run dev` next to a `Loki.serve()` on its default port 8712: Vite proxies
  `/api` and `/ws` to it
- The web sources are formatted by Prettier and linted by ESLint, both from
  `web/`: `npm run format` / `npm run format:check` (`printWidth` 90, no
  semicolons, single quotes — `web/.prettierrc.json`) and `npm run lint`
  (`eslint . --max-warnings=0`). A second `Stop` hook in
  `.claude/settings.json` prettifies modified web files once per turn, as the
  first one does `.jl` files. `npm run build` still runs `tsc --noEmit` first,
  so it is the typecheck too
- `web/eslint.config.js` is deliberately light, and two choices there are not
  obvious: `@typescript-eslint/no-explicit-any` is off because every `any` in
  the tree is the untyped server-JSON boundary, and react-hooks' two core
  rules are listed by hand because v7's own `recommended` bundles the React
  Compiler rules, which this app's state-syncing effects fail. The
  type-checked `typescript-eslint` sets are not enabled either.
  `eslint-plugin-react-refresh` is absent on purpose: `Plot.tsx` exports its
  trace builders beside the component
- To look at a change in a real browser: `npm run build`, then
  `LOKI_TEST_PORT=8719 LOKI_TEST_TOKEN=dev julia --project web/tests/server.jl`
  — the seeded session, on a port of its own. The server reads `assets/web`
  from disk, so rebuild before reloading
- Playwright runs `workers: 1`, `fullyParallel: false`, and both projects share
  one `Loki.serve()`: a spec must not assume session state its own `open(page)`
  did not reset — that helper deletes nodes and nothing else
- `serve`'s `public_url` defaults to `ENV["LOKI_PUBLIC_URL"]`; it is the
  address (e.g. a `tailscale serve` URL) added to the allowed `Origin`/`Host`,
  so remote access fails the checks without it

## CausalFrames dependency

CausalFrames (`../CausalFrames`, github.com/farrellm/CausalFrames.jl) is not
registered. `Project.toml` names it in `[sources]` by URL, which every
supported Julia reads. To work against a local CausalFrames checkout,
`Pkg.develop(path="../CausalFrames")` (this only touches the gitignored
Manifest).

Loki takes CausalFrames' optional dependencies — DuckDB, Parquet2,
MLJModelInterface — as hard dependencies, so loading Loki loads all three
CausalFrames extensions (`test/runtests.jl` checks this). `MLJModelInterface`
is `import`ed, never `using`'d: its `Count` clashes with CausalFrames'. For the
same reason StateSpaceModels is `import StateSpaceModels as SSM`: its
`LinearRegression` clashes.

## Invariants and conventions

- Diagnostics read a frame through `Tables.schema`, `nrow`, `Base.names`,
  `context` and `Tables.partitions` only. `frame.chunks` is private to
  CausalFrames; every diagnostic is tested against a multi-chunk frame and a
  single-chunk one holding the same rows, which is what keeps it that way.
- Anything a diagnostic reports is sanitized where it is built: `JSON3.write`
  refuses `NaN` and `Inf`, and degenerate input produces both.
- Depend only on CausalFrames' **exported** API. The known exceptions are
  recorded in DESIGN.md's "Relationship to CausalFrames": reading
  `CausalPipeline`'s `run` field (`tagged`, `cachedsource`, `fitonce`,
  `insample`, the engine's chunk drain), and reading `LinearRegression`'s and
  `FitModel`'s type parameters and fields (`applyfit`, `fitinput`). Don't add
  others without recording them there.
- Every operator is a CausalFrames source or curried transform —
  `difference(:x)` returns `CausalPipeline -> CausalPipeline`, with the
  uncurried `difference(p, :x)` a thin wrapper — and is *causal*: output at
  time `t` depends only on input at time `<= t`. Forward-looking operators go
  in `Loki.Acausal` (`src/acausal.jl`), which is never re-exported.
- Output columns are named by suffixing the input column (`x_diff`, `x_ema_12`,
  `x_residual`), with a `name` keyword to override. Intermediate columns an
  operator adds and drops again use a private `#`-prefixed name.
- Naming is Julian: lowercase, no camelCase, no shadowing of Base functions.
- Summarizers follow CausalFrames' interface and typing rules: concrete state
  fields typed from the input schema, per-row work behind a function barrier,
  and a `JET.@test_opt` check in `test/jet.jl` for each new kernel. Row
  functions are callable structs with their column names as type parameters.
- A new exported name also goes in DESIGN.md's export list, an `@docs` block
  under `docs/src/`, and `src/precompile.jl`'s workload.
- `web/src/theme.css` and `app.css`'s header are the design contract: six
  functional colour tokens, hairlines rather than cards, exactly one shadow
  (the bottom sheet) and one animation (the run sweep), 3px radii. New UI
  extends it rather than adding tokens or floating a card.
- Every operator gets a node kind in `src/nodes/` (an `OpKind` with `Param`
  specs; JSON-like values, Julia values as source text).
- Source-text parameters are evaluated in the session's `UserCode` module, so
  the functions they define are newer than any caller: the engine runs under
  `Base.invokelatest` once per run, and tests that load such pipelines
  directly must too.
- Operators get the streaming-property check (`streamequalsload` in
  `test/fixtures.jl`) across chunk sizes.
