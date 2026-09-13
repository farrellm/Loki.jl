# Loki.jl

Interactive time-series analysis on CausalFrames: a graph of `CausalPipeline`s
and time-series operators, diagnostics, a browser UI and MCP server, and export
of the graph as a plain Julia script.

**DESIGN.md is the source of truth for the design and must be kept in sync
with any API or semantics change.** Its "Milestones" section is the roadmap;
Milestone 0 (package scaffolding) is done, Milestone 1 is next.

## Commands

- Run tests: `julia --project -e 'using Pkg; Pkg.test()'` (Aqua, and on
  released Julia versions the targeted JET checks in `test/jet.jl`)
- Build docs: `julia --project=docs docs/make.jl` (one-time setup:
  `julia --project=docs -e 'using Pkg; Pkg.instantiate()'`; `docs/Project.toml`
  sources Loki from `..`). Documenter runs strict — a docstring not in a
  `@docs` block fails the build. The home page is **generated from
  `README.md`**; `docs/src/index.md` is gitignored, so edit the README
- Formatting is automatic: a `Stop` hook in `.claude/settings.json` formats
  modified `.jl` files once per turn (config in `.JuliaFormatter.toml`; CI
  pins JuliaFormatter v2, so don't format with a v1 install)
- Run one Julia process at a time — concurrent test/docs runs race on the
  precompile cache and fail transiently
- Add a dependency: `julia --project -e 'using Pkg; Pkg.add("Name")'`, then a
  `[compat]` entry (Aqua checks it). Test-only deps go in `[extras]` and
  `[targets]` instead. Only add a dependency in the commit that first uses
  it — Aqua's stale-deps check fails on an unused one
- CI tests Julia 1.10 (minimum supported), 1.12, and pre-release — don't use
  post-1.10 language or stdlib features
- The default branch is `master`, not `main` — target PRs there

## CausalFrames dependency

CausalFrames (`../CausalFrames`, github.com/farrellm/CausalFrames.jl) is not
registered. `Project.toml` names it in `[sources]` by URL, which Julia 1.11+
reads; Julia 1.10 ignores `[sources]`, so the 1.10 CI job runs
`Pkg.add(url=…)` before building. To work against a local CausalFrames
checkout, `Pkg.develop(path="../CausalFrames")` (this only touches the
gitignored Manifest).

Loki takes CausalFrames' optional dependencies — DuckDB, Parquet2,
MLJModelInterface — as hard dependencies, so loading Loki loads all three
CausalFrames extensions (`test/runtests.jl` checks this). `MLJModelInterface`
is `import`ed, never `using`'d: its `Count` clashes with CausalFrames'.

## Invariants and conventions

- Depend only on CausalFrames' **exported** API. The one known exception is
  reading `CausalPipeline`'s `run` field to wrap a pipeline (`tagged`,
  `cachedsource`); don't add others without recording them in DESIGN.md.
- Every operator is a CausalFrames source or curried transform —
  `difference(:x)` returns `CausalPipeline -> CausalPipeline`, with the
  uncurried `difference(p, :x)` a thin wrapper — and is *causal*: output at
  time `t` depends only on input at time `<= t`. Forward-looking operators go
  in `Loki.Acausal` (`src/acausal.jl`), which is never re-exported.
- Output columns are named by suffixing the input column (`x_diff`, `x_ema_12`,
  `x_residual`), with a `name` keyword to override.
- Naming is Julian: lowercase, no camelCase, no shadowing of Base functions.
- Summarizers follow CausalFrames' interface and typing rules: concrete state
  fields typed from the input schema, per-row work behind a function barrier,
  and a `JET.@test_opt` check in `test/jet.jl` for each new kernel.
- A new exported name also goes in DESIGN.md's export list, an `@docs` block
  under `docs/src/`, and `src/precompile.jl`'s workload.
