# Loki

[![Build Status](https://github.com/farrellm/Loki.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/farrellm/Loki.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![Dev docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://farrellm.github.io/Loki.jl/dev/)

An interactive environment for time-series analysis built on
[CausalFrames](https://github.com/farrellm/CausalFrames.jl). You build a graph
of `CausalPipeline`s and time-series operators (differencing, EMA, MACD, AR,
ARMA, …), inspect each node's output through diagnostics such as ACF, PACF and
residual tests, and export the graph as a plain Julia script. The same session
can be driven from a browser or by an agent over MCP.

Loki is under construction; [DESIGN.md](DESIGN.md) describes the design and its
milestones. The time-series operators, in-sample fits, the graph and the engine
are in place and usable from the REPL.

## Operators

Loki's operators are CausalFrames transforms, so they compose with `|>`:

```julia
using CausalFrames, Loki, DataFrames
using Loki.Acausal   # in-sample fits look ahead, so they are an explicit opt-in

df = DataFrame(time = 1:500, close = 100 .+ cumsum(randn(500)))

p = readtable(df) |>
    logtransform(:close) |>                                  # appends close_log
    difference(:close_log) |>                                # appends close_log_diff
    insample(FitARMA(:close_log_diff; order = (1, 0, 1)))    # fitted values and residuals

frame = load(Context(0, 501), p)
```

## A headless session

The same analysis as a graph, evaluated by the engine — cached, cancellable, with
errors attributed to the node that raised them:

```julia
s = Loki.Session(; tables = (prices = df,), contexts = (analysis = Context(0, 501),))

src = Loki.addnode!(s, "table", Dict("table" => "prices"))
logc = Loki.addnode!(s, "logtransform", Dict("column" => "close"))
dlog = Loki.addnode!(s, "difference", Dict("column" => "close_log"))
fit = Loki.addnode!(s, "fit",
    Dict("family" => "arma", "column" => "close_log_diff", "order" => [1, 0, 1]))
Loki.connect!(s, (src, :out), (logc, :in))
Loki.connect!(s, (logc, :out), (dlog, :in))
Loki.connect!(s, (dlog, :out), (fit, :in))

wait(Loki.run!(s, [(fit, :insample)]))
Loki.status(s, fit)                      # :ok
Loki.result(s, fit; port = :insample)    # the frame, with close_log_diff_residual
Loki.isacausal(s, fit; port = :insample) # true: residuals over the fit window
```

## Export and save

A session is not a black box. It exports as a plain Julia script that runs
without Loki's server, and saves as a JSON file that opens again:

```julia
exportjulia("analysis.jl", s)              # the graph as a script, tables beside it
Loki.savesession("analysis.loki.json", s)  # contexts, prelude, graph, tables
s2 = Loki.opensession("analysis.loki.json")
```

The script carries the prelude, the named contexts and one binding per node
output, and snapshots the session's tables next to itself, so **including it
reproduces the session's frames** — which is a test, not a hope:

```julia
using CausalFrames, Loki, Dates, Statistics
using DataFrames, Parquet2
using Loki.Acausal: insample

const analysis = Context(0, 501)

const SCRIPTDIR = @__DIR__
tables = (;
    prices = DataFrame(Parquet2.Dataset(joinpath(SCRIPTDIR, "prices.parquet")); copycols = false),
)

p_n1 = readtable(tables.prices)
p_n2 = p_n1 |> logtransform(:close)
p_n3 = p_n2 |> difference(:close_log)
p_n4_insample = p_n3 |> insample(FitARMA(:close_log_diff; order = (1, 0, 1)))

frame_n4_insample = load(analysis, p_n4_insample)
```
