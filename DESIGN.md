# Loki.jl — Design

Loki is an interactive environment for time-series analysis built on
[CausalFrames](../CausalFrames). A user builds a **graph** — a DAG whose edges
carry `CausalPipeline`s and whose nodes are CausalFrames operators or Loki's
time-series operators (differencing, EMA, MACD, AR, ARMA, …) — in a web app
designed for a laptop or desktop browser and usable on an iPhone,
inspects every node's output through diagnostics (ACF, PACF, residual tests,
forecasts), and exports the graph as a plain Julia script. The same session can
be driven by an agent over MCP while the user watches and edits it in the
browser.

Evaluation is CausalFrames evaluation: a node's output is
`load(ctx, pipeline)` over a session `Context`. Loki adds no data model of its
own. What it adds is a graph, a catalog of time-series operators written
against CausalFrames' public API, an engine that caches and attributes errors,
diagnostics, a server, and an exporter. The exported script is the ground
truth of what a graph means:

```julia
using CausalFrames, Loki, Dates

const analysis = Context(DateTime(2015, 1, 1), DateTime(2026, 1, 1))

p1 = readcsv("prices.csv"; types = Dict(:time => DateTime, :close => Float64))
p2 = p1 |> logtransform(:close)                     # appends :close_log
p3 = p2 |> difference(:close_log)                   # appends :close_log_diff
p4 = p1 |> macd(:close; fast = 12, slow = 26, signal = 9)
p5 = p3 |> Loki.Acausal.insample(FitARMA(:close_log_diff; order = (1, 0, 1)))

frame = load(analysis, p5)
acf(frame, :close_log_diff_residual; lags = 40)
```

## Relationship to CausalFrames

Loki depends only on CausalFrames' **exported** API. Every Loki operator is a
source or a curried transform in the CausalFrames sense — `difference(:x)`
returns a `CausalPipeline -> CausalPipeline` function, with the uncurried
`difference(p, :x)` as a thin wrapper — and obeys the same contract: chunks are
non-empty and time-ordered, output at time `t` depends only on input at time
`≤ t`, and the forward-looking exceptions live in a `Loki.Acausal` submodule
that is never re-exported, mirroring `CausalFrames.Acausal`.

Three CausalFrames facilities carry most of the weight:

- **`CausalPipeline(run)`** is exported, so a pipeline whose `run(ctx)` does
  something Loki-specific (serve a cached frame, load a fit over another
  context, tag errors with a node id) is an ordinary pipeline to every
  operator downstream.
- **Custom summarizers under `addsummarycolumns`** are the public route to
  per-row running state. Row lags, EMAs and the ARMA Kalman filter are all
  summarizers; they follow CausalFrames' summarizer interface (`emptyvalue`,
  `fresh`, `fresh!`, `update!`, `value`, `widenstate`) and its typing rules —
  concrete state fields, state typed from the input schema, per-row work behind
  a function barrier.
- **`readtable`** lifts an in-memory table or a loaded `CausalFrame` back into a
  pipeline. Loki uses it for the result cache, for tables handed to a session,
  and to place an in-sample model at the start of its window.

Loki reads the `run` field of a `CausalPipeline` to wrap one (`tagged`,
`cachedsource`) or to serve, from its own `run`, a pipeline built from a frame
it has just materialized (`fitonce`, `insample`), and the engine drains a run's
chunks from it directly. The field is the documented shape of the type, but an
accessor would make that dependence explicit.
`applyfit` and `fitinput` also read CausalFrames' fitting summarizers: the type
parameters of `LinearRegression{P,Y}` and `FitModel{N,P,Y,M}` (predictors,
response, model column) and `LinearRegression`'s `intercept` and `name` fields,
which decide the coefficient column names. Accessors for those would make that
dependence explicit too. Candidates to move upstream once
they have settled: those accessors, the `Lags` and `EMA` summarizers (neither is
time-series-model-specific), and `difference`.

## Core types

### `Graph`

Nodes with stable string ids, and edges from an output port to an input port.
Ports are named per node kind; every port carries a `CausalPipeline`, so the
one type check an edge needs is arity (a single-input port takes one edge, a
variadic port such as `merge`'s takes many, in connection order; an optional
port may be left unconnected). `connect!` rejects an edge that would close a
cycle, and `addnode!`/`setparams!` reject parameters the kind does not accept or
cannot hold, so every edit is checked where it is made. A *missing* required
parameter is not an edit error: a node is placed from the palette before it is
filled in, so an incomplete node is unfinished rather than invalid — it sits
idle until something asks for it, and then fails on itself with the parameter
named. `build` and `emit` still demand a complete node. Ids are `n1`, `e2`, … unless given,
and are never reused. Node positions in the canvas are stored on the graph but
play no part in evaluation.

### `Node` and `NodeKind`

A node is a kind plus a `params` dictionary. A kind is registered with
`register_nodekind!` and declares:

- `inputs(kind)` — `Port`s, each a name and whether it is variadic or optional;
  `outputs(kind)` — output port names;
- `paramschema(kind)` — a JSON Schema for `params`, which the web inspector
  renders as a form and the MCP server publishes as a tool's `input_schema`, so
  the user and an agent edit the same vocabulary;
- `validateparams(kind, params)` — checks the JSON-like values and fills in
  defaults, run on every node edit;
- `build(kind, params, inputs, env) -> NamedTuple` of `CausalPipeline`s, one per
  output port. `inputs[port]` is a pipeline, a vector of them for a variadic
  port, or `nothing` for an unconnected optional one; `env` resolves what
  parameters name — contexts, tables, and source text in the user module;
- `emit(kind, params, inputs) -> NamedTuple` of `Expr`s, one per output port —
  `build`'s shape with an expression in place of each pipeline, reproducing what
  it builds. `inputs[port]` is the script binding a connected input is bound to
  (a vector of them for a variadic port, `nothing` for an unconnected optional
  one), and source text travels as a `Code` value the printer passes through
  verbatim. A kind without `emit` cannot be exported (see "Export");
- `isacausal(kind, params, port) -> Bool` (default `false`), per output port, so
  the fit node's `model` port stays causal while its `insample` port is not;
- `iswrite(kind) -> Bool` (default `false`), marking the file sinks a run never
  evaluates as a side effect.

Most kinds are an `OpKind`: data — a name, a palette category, ports, a list of
`Param` specs, a build function, and the acausal output ports — from which
`paramschema` and `validateparams` are derived. A `Param`'s type is JSON's
(`string`, `integer`, `number`, `boolean`, `enum`, `integers`) or Loki's own —
`column`, `columns`, `code` (source text), `context`, `table` (names in the
session) and `summarizers` — carried in the schema as an `x-loki` annotation
the inspector keys its column pickers and code editors on. Parameter values
stay JSON-like, so a graph saves and travels as data.

`build` calls the real operator constructors, so a bad parameter is reported
eagerly — the `ArgumentError` CausalFrames raises at construction becomes an
error on that node while the user is still editing, not at run time.

### `Session`

One live analysis: a `Graph`, the named contexts, the in-memory tables, the user
code module, the result cache, the current run, and the event subscribers
(browser sockets and the MCP server). Every mutation, from either side, goes
through the session's command layer under one lock and is broadcast as an event
(see "Server"). `opensession!(s, path)` reads a file into a session that is
already running — the object the REPL holds is the one that changes — by reading
it into a throwaway session first, so a file this Loki cannot rebuild leaves the
live one untouched.

The headless session of Milestone 1 has all of this but the subscribers and
events: `Session(; tables, contexts, prelude, cachebytes)`; `setcontext!`,
`removecontext!`, `addtable!` and `setprelude!`; `addnode!`, `updatenode!`, `removenode!`,
`connect!` and `disconnect!`, each invalidating the node it touches and
everything downstream; `run!`, `cancel!`, `write!` and `freeze!`; and `status`,
`nodeerror`, `result` and `isacausal` to read the outcome back.

### Named contexts

`load` needs a `Context`, so contexts are session state rather than something a
node invents. A session always has `analysis`, the window nodes are evaluated
over, and may define more — `train`, `test`, a short `preview` — that node
parameters refer to by name. A context's time type is chosen when it is
created and must match the sources' time type; the UI offers the time type of
the first source added. Any context but `analysis` can be removed; nothing is
invalidated, because results are cached by a context's value rather than its
name, and a node that still names it fails at its next build as it would for a
name that never existed.

## Node catalog

### CausalFrames operators

Every exported CausalFrames operator is a node kind, one to one, with its
keyword arguments as parameters: the sources (`emptyframe`, `clock`,
`concatenate`, `merge`, `readtable`), file I/O (`readcsv`, `writecsv`,
`readparquet`, `writeparquet`, `readjls`, `writejls`), the row and column
transforms (`sortcycles` among them), the summarizing transforms (a summarizer
list is a structured parameter — a list of `{summarizer, columns, options}`
entries), the joins (`asofjoin`, `lookupjoin`), the fills, and the model
operators (`applymodels`, `addpredictions`, `modelreports`). Multi-input
operators become multi-port nodes: `asofjoin`
(`left`, `right`), `intervalize` and `summarizewindows` (`data`, `clock`),
`addrollingcolumns` (`data`, optional `from`), `applymodels` (`data`,
`models`), `merge` and `concatenate` (one variadic port, ordered). `lookupjoin`
joins against a table rather than a pipeline, so it has one port and its
`table` parameter names a session table (see "In-memory tables"); the table
must have no `:time` column, so a frozen frame cannot be one.

Parquet is always available, because Loki takes CausalFrames' optional
dependencies as its own (see "Dependencies"); the `backend` parameter is
exposed for the cases where the choice matters.

Row-function parameters — `filterrows`' predicate, `addcolumns`' function,
`settime`'s spec — are Julia source text (see "User code").

Parameters follow a few conventions, so every kind reads alike:

- Column names are strings; `key` is a name or a list of names.
- Anything that is a Julia *value* rather than a name — an interval, a
  tolerance, a look-back, a predicate, a row function, `readcsv`'s type
  dictionary, `fillmissing`'s values, `addrollingcolumns`' windows, the
  declared `keyset` of `summarizecycles`, `intervalize` and
  `summarizewindows`, an MLJ model — is source text, passed to the operator
  exactly as evaluated.
- `sortcycles`' `by` is split in two, like a column selection: `columns` by
  name or a key `function` (source text), exactly one of them.
- A column selection (`selectcolumns`, `dropcolumns`, `reordercolumns`,
  `forwardfill`) is `columns` by name plus an optional `match` expression, a
  `Regex` or a predicate on the name.
- A summarizer entry is `{summarizer, columns, options}`: the summarizer's
  column arguments, then its remaining arguments by name — `n` for `SumPower`
  and `Moment`, `response` (and `intercept`, `name`) for `LinearRegression`,
  `model` (source text) and `response` for `FitModel` — and Loki's `Lags`,
  `EMA` and `FitARMA` are entries too.
- The file sinks (`writecsv`, `writeparquet`, `writejls`) are write kinds.
- `CausalFrames.Acausal.settime` is the `acausal_settime` kind, `settime` being
  the causal one's name.

The palette's categories are sources, files, rows, columns, summarizing, joins,
time series, models and acausal.

### In-memory tables

A `table` source node is `readtable(tbl; time, sort)` over a table the session
holds by name. Tables arrive four ways:

- a CSV or parquet file uploaded through the browser and read into memory;
- a `DataFrame`, `CausalFrame` or other Tables.jl table passed from the REPL,
  `Loki.serve(; tables = (prices = df,))`;
- the MCP tool `load_table`;
- **freeze output** on any node, which loads it and registers the frame as a
  table — a way to pin an expensive intermediate result and branch from it.

A frozen `CausalFrame` keeps `readtable`'s frame semantics: it refuses to run
over a context outside its own. That is the right behavior — the frame knows
nothing about time outside its window — and the error names the frozen node.

### Acausal operators

`CausalFrames.Acausal`'s `lead`, `futurejoin` and `settime`, and
`Loki.Acausal.insample`, are ordinary node kinds, available by default.
Exploratory analysis needs them; hiding them behind a setting would only
teach people to turn the setting on. What Loki does instead is make acausality
**visible and contagious**: an acausal node is badged, and every node
downstream of one is marked too (see "In-sample fits").

### Loki time-series operators

All of these are exported from `Loki`, curried with uncurried forms, accept a
`key` wherever per-key state makes sense, and name their outputs by suffixing
the input column (the CausalFrames convention), with `name` to override.

#### Row lags: `Lags` and `lags`

`Lags(:x, p)` is a summarizer whose state is a ring buffer of the last `p + 1`
values of `:x`, typed from the column; its value is `x_lag_1, …, x_lag_p`, each
`Union{Missing, T}` because the first rows have no history (`name` replaces the
`x_lag` prefix). `lags(:x, p; key, name)` is
`addsummarycolumns(Lags(:x, p; name); key)`. Because `addsummarycolumns` emits the
summary *after* folding the current row, the buffer's newest entry is `x_t` and
the lags are read from behind it — causal by construction.

These are **row** lags, not time lags. `CausalFrames.lag(offset)` already
shifts by a time offset; `Lags` exists because ARMA-style models are indexed by
observation, and on an irregular series the two differ. `Lags` is a plain
`Summarizer`: it is only ever used under `addsummarycolumns`, where structure is
not consulted.

#### Differencing: `difference`

`difference(:x; order = 1, lag = 1, key)` appends
`Δₛᵈ xₜ = Σₖ (-1)ᵏ C(d, k) xₜ₋ₖₛ` for `d = order`, `s = lag`: `lags(:x, order * lag)`
into an `addcolumns` over the binomial weights, with the lag columns dropped
afterwards. The lags are taken under a private prefix, so an `x_lag_1` the
input already carries does not collide. The output is `x_diff` for `(1, 1)` and
`x_diff_{order}_{lag}` otherwise; it is `missing` for the first `order * lag`
rows of each key.

#### Transforms: `logtransform`, `boxcox`

`addcolumns` wrappers appending `x_log` and `x_boxcox`. `boxcox(:x; lambda)`
takes a fixed `λ`: estimating `λ` looks at the whole window, so that lives in
diagnostics, which can suggest a value to paste in.

#### Exponential moving average: `EMA` and `ema`

`EMA(:x; span)` folds `sₜ = α xₜ + (1 - α) sₜ₋₁` with `α = 2 / (span + 1)`,
seeded with the first value. `EMA(:x; halflife)` is the time-aware form for
irregular series, `α = 1 - exp(-ln 2 · Δt / halflife)` with `Δt` the time since
the previous row (read from `row.time`); for `DateTime` the difference is a
`Millisecond` and the half-life is converted to one, for numeric time types it
is plain division. Exactly one of `span` and `halflife` is given, and each form
is its own state type, so neither pays for the other's branch. A `missing` value
leaves the state unchanged and emits the current average. The output is
`x_ema_{span}`, or `x_ema_hl_{halflife}` (`x_ema_hl_5minute` for `Minute(5)`),
or `name`; its element type is `Union{Missing, Float64}`, `missing` until the
first value. `ema(:x; …)` is the `addsummarycolumns` wrapper.

`EMA` is a plain `Summarizer`: it is neither combinable nor invertible, and
rolling windows are not how it is used.

#### MACD: `macd`

`macd(:x; fast = 12, slow = 26, signal = 9, name = :macd, key)` appends
`macd`, `macd_signal` and `macd_hist`:

```julia
addsummarycolumns([EMA(:x; span = fast), EMA(:x; span = slow)]; key) |>
    addcolumns(r -> (; macd = r.x_ema_fast - r.x_ema_slow)) |>
    addsummarycolumns(EMA(:macd; span = signal); key) |>
    addcolumns(r -> (; macd_hist = r.macd - r.macd_signal)) |>
    dropcolumns(intermediates)
```

It exports as `macd(...)`, not as the expansion.

#### Autoregression by least squares

An AR(p) fit is CausalFrames' own `LinearRegression` over row lags —
`lags(:x, p)`, `filterrows` to drop the rows with an incomplete history (a
`missing` predictor would poison the fit rather than be skipped), and then
`summarize(LinearRegression([:x_lag_1, …, :x_lag_p], :x; name = :ar))` for one
fit, or `addrollingcolumns` for rolling coefficients that are causal row by row.
The composite `ar(:x, p; key, name = :ar)` is the node kind for this; it shares
accumulators with any `Variance` or `Correlation` over the same columns, as
`LinearRegression` always does.

#### ARMA, ARIMA and SARIMA: `FitARMA`, `ARMAFilter`

Estimation is **StateSpaceModels.jl**'s `SARIMA`.

`FitARMA(:x; order = (p, d, q), seasonal_order = (0, 0, 0, 0), include_mean = false, name = :model)`
is a plain summarizer, the same shape as CausalFrames' `FitModel`. Its state
buffers `:x` in a `Vector{Float64}` (`missing` stored as `NaN`), `fresh!` empties
the buffer keeping its capacity, and `value` builds
`SARIMA(y; order, seasonal_order, include_mean)`, calls `fit!`, and emits a
`FittedARMA`: the fitted model, its hyperparameters by name (`get_names`), the
information criteria, the number of observations, a status, and — computed once
per fit — the state-space system the filter steps (`Z`, `T`, `RQR`, `c`, `d`,
`H`) with its initial state (`a1`, `P1`). The system is read from the fitted
`SARIMA`'s `system` field, an exported `LinearUnivariateTimeInvariant`, and the
criteria from its `results`. The initial covariance is StateSpaceModels' own
SARIMA initialization: diffuse (`1e6·I`) differencing states, and the ARMA
block's stationary covariance `Q · lyapd(T, R R')` from MatrixEquations.
StateSpaceModels skips a `NaN` observation in the likelihood, which is what the
buffer's `missing`-as-`NaN` relies on. A fit whose likelihood is not finite is
`:failed` too, and so is a series with no observations at all, which
StateSpaceModels would otherwise "fit". A fit that
throws — too few observations, a failed optimization — emits a `FittedARMA`
with `status = :failed` and the message rather than raising: under a rolling
refit one bad window must not end the run, which is `LinearRegression`'s `NaN`
rule for a model. An empty window emits `missing`.

The column type is `Union{Missing, FittedARMA}`, concrete. `FittedARMA` is an
ordinary Julia struct, so a model table survives `writejls`/`readjls` with no
custom serializer.

`ARMAFilter(:x; model = :model, horizon = 0, name = :x)` applies a fitted model
to a stream. It is a summarizer reading two columns — the value and the model —
whose state is one step of the model's Kalman filter. On each row it predicts
`xₜ` from the state, emits the prediction error, and updates. Its value is:

| Column | Meaning |
|---|---|
| `x_fitted` | `E[xₜ ∣ x₁…xₜ₋₁]`, the one-step prediction made before seeing `xₜ` |
| `x_residual` | `xₜ - x_fitted`, the innovation |
| `x_stdresidual` | the innovation over the square root of its variance |
| `x_forecast_1 … x_forecast_h` | `E[xₜ₊ₕ ∣ x₁…xₜ]` for `h ≤ horizon` |

All of it is known at time `t`, so the filter is causal. When the `model`
column changes identity, the state is re-initialized from the new model, as a
fresh filter would be; a `missing` or failed model emits `missing` and keeps no
state. A `NaN` observation is skipped by the filter (prediction without update)
and emits `missing` residuals.

Re-running `kalman_filter` over a copy of the model for each row would be
quadratic in the window. The per-row step is one allocation-free Joseph-form
update over the fitted system — O(state³) per row, the recursions
StateSpaceModels uses — and it is **exact**. StateSpaceModels' filter stops
updating the covariance once it looks steady, which is cheaper but leaves the
innovation variance stale after a gap (it keeps the post-gap variance until the
tolerance trips again), so `ARMAFilter` takes no such shortcut. Its correctness
is pinned by a differential test against StateSpaceModels' own `kalman_filter`,
`get_innovations` and `get_innovations_variance`, run with the fitted
hyperparameters and the steady-state tolerance disabled. `fix_hyperparameters!`
is not the route to that model: one with every hyperparameter fixed cannot be
`fit!`, and `kalman_filter` refuses an unfitted one, so the test copies the
fitted hyperparameters instead, as StateSpaceModels' `forecast` does.

The operators built from the two:

- `fitarma(:x; order, …, key)` is `summarize(FitARMA(...); key)` — one model per
  key at the window's `stop`.
- `applyarma(models, :x; column = :model, key, tolerance, strict = false, horizon = 0, name = :x)`
  — the series is positional because the filter carries it as a type
  parameter — is
  `asofjoin` of the models pipeline (narrowed to its model and key columns)
  followed by `addsummarycolumns(ARMAFilter(...); key)` and the model column
  dropped — `applymodels`' composition, with the as-of store supplying the
  model and the summarizer supplying the filter state.
- `arma(clock, lookback, :x; order, …, key)` refits on
  `summarizewindows(clock, lookback, FitARMA(...); key)` and applies the stream
  to itself with `applyarma`. The windows are half-open, so every row is
  filtered by a model fit only on rows before it — `addpredictions`' argument,
  unchanged.

#### Fitting over another context: `fitonce`

`fitonce(p, trainctx, s; key)` is the CausalFrames "fit once, apply later"
recipe as an operator. Its `run(ctx)` loads `p |> summarize(s; key)` over
`trainctx` and serves the model table through
`readtable(frame; checkcontext = false)`, so whatever context it is run over it
yields the model rows that fall inside it — timed at `trainctx.stop`.

That timing is what makes it causal, and it makes a leakage warning unnecessary.
A row before the training window's `stop` cannot see the model; applied over an
analysis window that overlaps the training window, the early rows get `missing`
rather than a model that was fit on their own future. To reach a model from
a later window, `applyarma`'s `tolerance` widens the models' context backward,
exactly as in the recipe. The only way to apply a model to its own training
rows is to say so — `insample`, below.

## In-sample fits

The exploratory loop for a time-series model is Box–Jenkins identification:
transform until the series looks stationary, read candidate orders from the ACF
and PACF, fit, and then look at the residuals **over the rows the model was fit
on** — their ACF, a Ljung–Box test, their distribution — to see whether what is
left is white noise. If it is not, change the orders and go round again.

Residuals over the fit window are acausal by definition: row `t`'s residual uses
a model that saw rows after `t`. That is not a flaw to be engineered around;
it is the question being asked. So in-sample residuals are a first-class
operator, living in `Loki.Acausal`, rather than a side path hidden inside the
diagnostics.

### `insample`

`Loki.Acausal.insample(s; fitcontext = nothing, key)` (and the uncurried
`insample(p, s; …)`) takes a fitting summarizer and appends that model's fitted
values and residuals to the stream. Its `run(ctx)`:

1. loads `fitinput(s, p) |> summarize(s; key)` over the fit context — `fitcontext` if given,
   otherwise `ctx` itself — giving one model row per key at that context's
   `stop`;
2. lifts the model table back in with `readtable(models; time = _ -> ctx.start)`,
   placing each whole-window model at the *start* of the window — the single
   acausal step, taken once per run;
3. applies it with the summarizer's causal apply operator, so every row is
   filtered by the final model.

The fit is materialized once, in step 1. Retiming the lazy stream with
`CausalFrames.Acausal.settime` instead would re-fold the fit every time the
pipeline runs — and a pipeline feeding two consumers runs twice.

Which apply operator is used is a method of `Loki.applyfit(s, p, models; key)`:

| Fitting summarizer | Apply | Columns appended |
|---|---|---|
| `FitARMA` | `applyarma` | `x_fitted`, `x_residual`, `x_stdresidual` |
| `LinearRegression` | `asofjoin` of the coefficient columns, then `addcolumns` of `β·x` | `y_fitted`, `y_residual` |
| `FitModel` (MLJ) | `applymodels` | `y_fitted`, `y_residual` |

A new fitting summarizer supports `insample` by adding an `applyfit` method,
and — when some rows must not reach the fit — a `Loki.fitinput(s, p)` method,
which defaults to `p`. `LinearRegression` and `FitModel` drop the rows with a
`missing` predictor or response, which would otherwise poison the fit, so a
regression over row lags (an AR fit) fits on the rows with a complete history;
`FitARMA` keeps them as gaps in the series. The coefficients `LinearRegression`'s
apply joins arrive under a private prefix and are dropped after use, and the
`FitModel` residual subtracts the prediction, so it needs a deterministic
regressor.

When `fitcontext` is narrower than the run's context — fit on `train`, evaluate
over `analysis` — the rows inside `train` carry in-sample residuals and the rows
after it carry the same model applied out of sample. The residual panel splits
the two at `train.stop` (see "Diagnostics").

### The fit node

In the graph, a model fit is one node with two output ports:

- `model` — the causal model table: `summarize(s; key)` over the run's context,
  or `fitonce(p, fitcontext, s; key)` when a fit context is named. Feeds
  `applyarma`/`applymodels` for honest out-of-sample use.
- `insample` — the input stream plus fitted values and residuals, acausal. The
  residual diagnostics attach here.

The node's parameters are the model family (ARMA, AR by least squares, MLJ
model), its options, the fit context, and the key. Exporting it emits one
binding per connected port.

Concretely, `family` is `arma` (with `order`, `seasonal_order`,
`include_mean`), `ar` (with `p`) or `mlj` (with `model` as source text and
`predictors`); `column` is the series, or the response for `mlj`. The `model`
port is `fitinput(s, p) |> summarize(s; key)`, or `fitonce` of it over the named
`fitcontext`; the `insample` port is `p |> insample(s; fitcontext, key)`. An `ar`
fit is `LinearRegression` (named `ar`) over `lags(:x, p)`, with the lag columns
dropped from the in-sample stream.

### Why a pipeline, not a diagnostic

Residuals are rarely the end of the analysis. They get differenced again, fit
with a second model, joined against an exogenous series, or written out; a
residual series that existed only inside a plot could do none of that and could
not be exported. As a pipeline it is an ordinary input to anything downstream.

### Taint

The engine computes, for each output port, whether it or any ancestor is
acausal (an acausal kind, or an `insample` port) — `taint(graph)`; a node is
tainted when any of its outputs is. Tainted nodes are shaded in the canvas, reported
as `acausal = true` by the MCP `get_graph` tool, and in the exported script
the import of `Loki.Acausal` or `CausalFrames.Acausal` makes the dependence
visible at the top. Taint is information, not a restriction: nothing refuses to
run.

## Engine

### Compiling

Compiling a node builds its output pipelines from its inputs' pipelines,
recursively, once per run and memoized within it. Building is cheap — pipelines
are lazy values, and source-text parameters are cached by the user-code module —
and is where eager parameter errors surface. It happens under the session lock
as a run starts, so the worker then streams pipeline values that no later edit
can change. A node feeding several consumers hands each the same
pipeline value; CausalFrames pipelines can be re-run, so this is correct, but
an uncached shared ancestor is then *evaluated* once per consumer (the
self-join precedent). The cache is the answer when that matters.

### Running

A run evaluates a set of **watched** nodes — the ones with a diagnostic panel
or table preview open, or requested by MCP — over the analysis context. It
executes on a worker task as

```julia
for frame in stream(ctx, p)
    cancelled[] && break
    push!(chunks, frame); progress(nrow(frame))
end
```

so a run reports progress per chunk and can be cancelled between chunks. A new
run request cancels the one in flight. Concretely, `run!(session, targets;
context, progress)` compiles every target, records build errors, and spawns the
worker. The worker drains each target's chunks from its pipeline's `run`
directly, rather than through `stream`, whose per-chunk frames the cache would
have to copy back out, and assembles them with the public `CausalFrame`
constructor. A cancelled run caches nothing and leaves its targets `:idle`. One CausalFrames caveat applies:
abandoning a stream leaves a sink upstream of the cancellation point
unfinalized. Loki therefore evaluates write nodes (`writecsv`, `writeparquet`,
`writejls`) only on an explicit "write" command, with `scan`, and never as a
side effect of watching a downstream node: under a run, a write node compiles as
a pass-through of its input.

**Errors are attributed.** A run-time failure is raised deep inside a lazy
iterator, far from the node that caused it. Every node's pipelines are wrapped
in `tagged(p, id)`, a `CausalPipeline` whose iterator catches an exception from
`iterate`, wraps it as `NodeError(id, exception)` unless it already is one, and
rethrows. The innermost tag wins, so the error lands on the node that actually
failed; that node turns red in the canvas and downstream nodes show "blocked".
A build error — a bad parameter, an unconnected input — is a `NodeError` on its
node in the same way.

### Caching

Loaded frames are cached by (node, output port, upstream hash, context), where
the upstream hash covers the kinds, parameters and user code of the node and all
its ancestors, and the identity of the tables and the values of the contexts
their parameters name. Any edit therefore invalidates exactly the node and its
descendants.

When a node is compiled with a cached ancestor, the ancestor's pipeline is
replaced by `cachedsource(frame, fallback)`: a `CausalPipeline` whose `run(ctx)`
is `readtable(frame)`'s when `ctx == context(frame)`, and `fallback`'s — the
uncached pipeline — otherwise. `readtable` shares the frame's chunks without
copying, and its `closed = nothing` default keeps the rows a summarizing
operator emitted at `stop`, so the substituted pipeline reproduces the cached
result exactly.

The test is **equality**, not `readtable`'s own "within the frame's context"
rule, and both directions matter:

- operators downstream may request a *wider* context — `lag`, `asofjoin` with
  `tolerance`, `addrollingcolumns` and `summarizewindows` widen backward by
  their look-back — which `readtable` would refuse;
- a *narrower* context `readtable` would accept, but serving it would be wrong
  whenever the cached subgraph is stateful: `summarize`, `head`, `lastrow` and
  every rolling operator give different results over a sub-context, which is
  precisely the chunk-concatenation property they lack.

Frames stay in memory under a byte budget, evicting the least recently used
first; a frame is sized with `Base.summarysize` when it is stored. Frozen outputs (see "In-memory tables") are not cache entries and are
never evicted.

### Schemas

CausalFrames schemas are data-driven: the columns a node produces are known
only once it has produced a chunk. Column pickers in the inspector are populated
from the last evaluated `Tables.schema` of the input. A session may define a
short `preview` context; adding or editing a node then loads it over `preview`
first, which gives the picker something to show in a fraction of the time. A
node never evaluated has free-text column fields.

## Diagnostics

Diagnostics are computed on a node's **loaded frame**, outside the pipeline.
They are whole-window analyses — an ACF over the window uses every row in it —
and are acausal in exactly the sense a plot is. Nothing a diagnostic computes
flows back into the graph; a statistic that should (a rolling correlation, a
rolling standard deviation) is a node, and each causal diagnostic offers
**promote to node**, which adds the corresponding `addrollingcolumns` node.

Each diagnostic is a Julia function over a `CausalFrame` returning a
`DiagnosticResult`: plot-ready data for the web app and a compact numeric
summary for MCP. `acf`, `pacf`, `ljungbox`, `adftest`, `fitreport` and
`forecastfan` are exported, so a script can call them; `seriesplot`, `preview`,
`histogram`, `qqplot` and `residuals` are `Loki.`-qualified, because those names
belong to everyone (`residuals` is StatsAPI's, `histogram` every plotting
package's). `Loki.diagnostic(frame, kind; params)` runs any of them by name from
string-valued parameters, so the HTTP routes and the MCP tool share one argument
list rather than two that drift.

Every float a diagnostic reports is sanitized to `null` where it is built:
`JSON3.write` refuses `NaN` and `Inf`, and a constant series, an all-`missing`
column or a failed fit produce them routinely. And nothing that would raise on a
short window does: StatsBase's `pacf` needs `2·lags < n`, `LjungBoxTest` needs
`dof < lags`, and a singular window has no correlogram at all — each clamps or
drops with a warning the panel shows, because a short window is exactly what a
user points at first.

| Diagnostic | Function | Notes |
|---|---|---|
| Series and table preview | `seriesplot`, `preview` | long series are downsampled server-side (LTTB) before plotting |
| Whole-frame summary | `resultsummary(frame; head, tail)` | schema, row count, a statistic per column, and the first and last rows — what an agent reads instead of the rows |
| ACF / PACF | `acf(frame, col; lags)`, `pacf(frame, col; lags)` | StatsBase `autocor`/`pacf`, with ±1.96/√n bands; the summary lists the significant lags |
| Distribution | `histogram`, `qqplot` | against a fitted normal |
| Stationarity | `adftest(frame, col)` | HypothesisTests `ADFTest` |
| Ljung–Box | `ljungbox(frame, col; lags, dof)` | HypothesisTests `LjungBoxTest`; `dof` defaults to `p + q + P + Q` on a residual column |
| Fit report | `fitreport(frame; column = :model)` | a `FittedARMA`'s hyperparameters, information criteria and status, or `modelreports` for MLJ |
| Residual panel | `residuals(frame, col)` | see below |
| Forecast fan | `forecastfan(frame, col; h, models)` | StateSpaceModels `forecast` from the fitted model, with intervals |

Two of these need something the frame alone does not carry, because `applyarma`
drops the model column: an in-sample residual stream has no `FittedARMA` in it.
The Ljung–Box degrees of freedom come from the keyword, else from a model column
if there is one, else from the fit node's own `order` and `seasonal_order` —
which only the server's route knows, since it has both the frame and the node.
The same route hands `forecastfan` the `model` port's frame as `models`.

**The residual panel** opens on any `insample` port and gathers what the
identification loop needs in one view: residuals over time, fitted values over
the actual series, residual ACF and PACF, Ljung–Box at a few lag counts with the
degrees of freedom adjusted, and a residual histogram and QQ plot. When the fit
context is narrower than the analysis context, in-sample and out-of-sample
residuals are drawn in two colors and their statistics reported separately.

**Quick fit** closes the loop from the other side: on any series port, it
proposes AR and MA orders from the PACF and ACF cut-offs, and one click adds a
fit node wired to that port with its residual panel open.

Diagnostics that assume regular spacing — ACF, PACF, Ljung–Box — check the
spacing of `:time` first and warn when it is not constant, suggesting the
resample `intervalize(clock(Δ), Last(:x))` as a node. Keyed frames get a key
selector; the diagnostic runs on one key's rows. `missing` values are dropped,
and the count dropped is part of the summary.

## User code

Row functions and other expression parameters are stored as Julia source
text. Each session owns an anonymous module, created with
`using CausalFrames, Loki, Dates, Statistics`, where that text is parsed with
`Meta.parse` and evaluated; a session may also hold a **prelude**, a block of
helper definitions evaluated into the module first and emitted at the top of an
exported script. Source text is exported verbatim, so the script says exactly
what the user typed.

The module binds `CausalFrames`, `Loki`, `Dates` and `Statistics` directly and
`using`s them relatively, so it does not depend on which environment is active.
The module is created on first use, so a session that evaluates no source text
never makes one. Changing the prelude builds a fresh module, so a removed
definition is really gone; a prelude that fails to evaluate leaves the previous one in place.
Evaluated values are cached by source text until the prelude changes, so
rebuilding a node with unchanged parameters gets the same function back. A
parse error is an `ArgumentError` naming the parameter. Functions defined this
way are newer than the engine's code, so the engine compiles and runs a graph
under `invokelatest`, once per run — never per row.

This is arbitrary code execution, and the design does not pretend otherwise.
The containment is the server's:

- **It binds to `127.0.0.1`, in every mode.** Loki never listens on a LAN
  interface, and doing so is a non-goal. Remote access — the iPhone case — goes
  only through `tailscale serve`, which terminates TLS on the machine's tailnet
  name and proxies to the local port (see "Server"). The phone reaches Tailscale;
  only Tailscale reaches Loki.
- **It requires a per-session random token**, behind Tailscale too. The tailnet
  limits who can *connect*; the token limits who can *use this session*, and
  with code execution on the table both are wanted.
- **It checks the `Origin` and the `Host`** of requests and WebSocket upgrades,
  accepting `http://127.0.0.1:<port>`, `http://localhost:<port>`, and the
  configured `public_url` — nothing else. `Origin` alone does not close DNS
  rebinding: an attacker's name resolving to 127.0.0.1 yields
  `Host: evil.example:8712` on a same-origin GET that carries no `Origin` at
  all.

An MCP client can submit code through the same parameters, and connecting one
to Loki grants it the same power the user has at the REPL.

## Web app

A single-page app written in TypeScript with Vite and React:

- **Palette** — node kinds by category (sources, rows, columns, summarizing,
  joins, time series, models, acausal).
- **Canvas** — React Flow. Nodes show their kind, status (idle, running, ok,
  error, blocked), row count, and acausal badge or shading.
- **Inspector** — a form generated from the node kind's `paramschema`, a
  CodeMirror 6 editor for expression parameters, context pickers, and column pickers fed by
  the input schema.
- **Diagnostics** — tabs per watched port, rendered with Plotly.js from the
  server's plot-ready data.
- **Table** — a paged preview of a node's output.
- **Session bar** — named contexts, tables, prelude, run and cancel, export,
  open and save, the file the session is looking at, and the origin of the most
  recent change (you or the agent). The file's name is itself the button that
  saves somewhere else, and `Save` overwrites the file the session knows.
- **File picker** — a path on the machine Loki is running on, over
  `/api/files`. A band hanging off the session bar rather than a floating
  dialog, with the path as its subject: one line that is at once the
  breadcrumb, the file name field and the string that will be written. Files it
  cannot use are dimmed rather than filtered away, because a folder filtered
  down to nothing cannot say whether it is the right folder. It takes suffixes,
  a folder and a name and returns a path, so a `readcsv` node's path parameter
  can use the same component.

The bundle is built into `assets/web`, which is **not** in version control:
`web/` holds the sources, and `cd web && npm ci && npm run build` produces it. A
server without one serves a page saying so rather than refusing to start, so a
fresh clone is a working API and a REPL session immediately, and a browser once
the bundle is built. (Shipping it to users who have no Node — a committed
bundle, or an `Artifacts.toml` — is a packaging decision for a release, not a
design one.) One plotting library was chosen over two:
Plotly covers every chart above, and server-side downsampling handles the long
series that would otherwise argue for uPlot.

### Responsive layout

The primary client is a laptop or desktop browser, and the five-region layout
above is the design target. The app must also be **usable on an iPhone** —
checking a run, reading a residual panel, adjusting a parameter away from the
desk — and it gets there as **one responsive UI**, not a separate phone app or
a reduced feature set. Below a width breakpoint the same components reflow: the
canvas takes the screen, the palette, inspector, diagnostics and table become
tabbed bottom sheets over it, and the session bar collapses into a menu.
Nothing is removed at narrow widths.

One UI works on both only if no interaction depends on a mouse, so these are
rules for every component:

- **Every action has a tap path.** No hover-only affordances, no right-click-only
  menus, no drag-only actions: a node is added by drag from the palette *or* by
  tapping a kind and then the canvas; an edge is connected by dragging between
  handles *or* by tapping one handle and then the other (React Flow handles
  touch); context menus are also reachable from a node's toolbar. Tooltips open
  on tap.
- **Hit targets are at least 44 pt**, including port handles, which are drawn
  small and hit-tested large.
- **Viewport.** `viewport-fit=cover` with safe-area insets, and `dvh` rather than
  `vh` heights so iOS Safari's collapsing toolbar never hides a sheet's controls.
  Form inputs use a font size of at least 16px, below which Safari zooms the page
  on focus. The table preview scrolls horizontally inside its own panel, never
  the page.

Two component choices follow from iOS rather than taste. The code editor is
**CodeMirror 6**, which works with touch selection and the on-screen keyboard;
Monaco, the obvious desktop choice, does not support mobile browsers. Plotly is
configured for touch — pan and pinch-zoom gestures, readouts that do not depend
on hover. The server-side downsampling above also keeps plot payloads small
enough for a phone on a cellular connection.

## Server

`Loki.serve(; port, public_url = get(ENV, "LOKI_PUBLIC_URL", nothing), tables, token, open_browser = true)`
starts an HTTP.jl server (`HTTP.serve!`, non-blocking) on `127.0.0.1` for the
static bundle, a REST API and one WebSocket, and returns the session;
`Loki.stop!(session)` ends it. `port = 0` takes a free one, which `Loki.port`
then reports — how the tests get one — and `token` is given only to make a run
reproducible, since it defaults to a fresh random one.

HTTP.jl is pinned to 1.x deliberately. HTTP 2's WebSocket server is a separate
websocket-only listener that cannot share a port with the REST API, which would
mean two ports, two origins, and two things for `tailscale serve` to proxy;
HTTP 1's `stream = true` handler serves both on one socket. Oxygen.jl was
evaluated and declined: it brings JSON.jl alongside JSON3 — two serializers with
different `NaN` behaviour, in a process where sanitizing `NaN` is already the
likeliest failure — plus eight more dependencies and a module-global router, for
routing sugar over fourteen routes.

**When the bundle has not been built**, `serve` does not refuse to start: every
non-`/api` GET returns a page saying how to build it, and the API, the socket
and MCP stay up. That is also how the tests run without Node. `index.html` is
served `no-store` rather than `no-cache` — with no validator to revalidate
against a browser reuses it anyway, and a stale index against a fresh server
means a stale app.

**Access from an iPhone** is through `tailscale serve`, and only through it.
`public_url` is the HTTPS address it exposes on the tailnet; Loki uses it for
the `Origin` check (see "User code") and to print links, and nothing else —
the listening socket does not change:

```sh
tailscale serve --bg 8712
```

```julia
Loki.serve(; port = 8712, public_url = "https://workstation.example-tailnet.ts.net")
```

The startup message, and the MCP `get_web_url` tool, give the local URL and,
when `public_url` is set, the public one, both carrying the token.

When `tailscale serve` listens on a port other than 443
(`tailscale serve --bg --https=8443 8712`), the port is part of `public_url`
(`"https://workstation.example-tailnet.ts.net:8443"`), since it is part of
every `Host` and `Origin` that arrives through it. The scheme's default port is
accepted with or without it.

**The token survives iOS.** It arrives in the URL *fragment*, which browsers
never send to a server or put in a `Referer`. On first load the app exchanges it
once for a session cookie — `HttpOnly`, `SameSite=Strict`, and `Secure` when
served over HTTPS — and replaces the address with a token-free one. A Safari tab
that iOS evicted and reloads, or a home-screen bookmark opened a day later,
still authenticates, and the token does not linger in history. Because the
fragment is not sent with the page request, the static bundle itself is served
without authentication; every `/api` route and the WebSocket require the token
or the cookie.

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/auth` | exchange the fragment token for the session cookie |
| `GET` | `/api/nodekinds` | kinds with ports, param schemas and their order |
| `GET` | `/api/graph` | the whole graph, with status and taint |
| `POST` / `PATCH` / `DELETE` | `/api/nodes[/:id]` | add, edit, remove a node; `PATCH` merges `params` (a `null` removes one) and moves a node by `position`, which invalidates nothing |
| `POST` / `DELETE` | `/api/edges[/:id]` | connect, disconnect |
| `GET` / `PUT` / `DELETE` | `/api/contexts[/:name]` | named contexts; `analysis` can be changed but not removed |
| `GET` / `POST` | `/api/tables[/:name]` | list, upload |
| `POST` | `/api/run`, `/api/cancel`, `/api/write/:id` | evaluation |
| `GET` | `/api/results/:id/:port` | schema, row count, paged rows |
| `GET` | `/api/diagnostics/:id/:port/:kind` | a `DiagnosticResult` |
| `POST` | `/api/nodes/:id/freeze` | freeze output as a table |
| `GET` | `/api/export` | the Julia script |
| `GET` | `/api/files` | one directory on the server, for the file picker |
| `GET` / `PUT` / `POST` | `/api/session` | the current file, save, open |

`/api/files` lists one directory — its subdirectories and files, with each
file's modified time — so the browser can pick a path to save to or open, and
later a path for `readcsv`. It is deliberately **not rooted**: an analysis reads
its data from one directory and saves beside it in another, and a session that
evaluates source text can already reach the whole filesystem (see "User code"),
so a root would be a configuration burden rather than a boundary. The token,
cookie, `Origin` and `Host` checks in front of it are the same ones in front of
everything else under `/api`. A listing is capped and says when it was cut
short, because a home directory full of downloads is otherwise a megabyte of
JSON on a phone's connection.

Every mutating endpoint calls the command layer, which takes the session lock,
applies the change, invalidates what it affects, and broadcasts an event on
`/ws`: `graph_changed`, `node_status`, `run_progress`, `result_ready` and
`log`. Each event carries its `origin` — `ui`, `mcp`, or `repl` for everyone
else — so the browser can show what an agent just did, and the agent can be told
what the user changed. The origin travels as a scoped value
(`Loki.withorigin`), set once by each transport rather than threaded through ten
mutators, and `run!` captures it onto the `Run`, since the worker outlives the
request that started it.

An edit invalidates the node and everything downstream, and says which on the
`graph_changed` event rather than emitting a status event each — that would be
dozens of messages per keystroke. Chunk progress is throttled to ten events a
second per target, with the last one always sent.

Each socket is two tasks, a reader and a writer, because `receive` blocks and
Julia has no `select`; only the writer ever sends, so the 30-second heartbeat
and the reply to a client's ping are offered into the subscriber's own queue
rather than written from a second task. That queue is bounded and never blocked
on — broadcasting happens under the session lock, so a `put!` that waited for
the slowest reader would hold the lock for everyone — and a subscriber at
capacity drops events and counts them. Every event carries a monotonic `seq`,
and a drop is followed by an explicit `desync` carrying the count.

The socket is expected to drop. `tailscale serve` proxies the upgrade, but iOS
suspends background tabs and closes their sockets, and a phone changes networks.
The client reconnects with backoff and refetches `/api/graph` — on reconnect, on
a `desync`, and on a gap in `seq` — rather than trusting that it missed no
events. Events are a live-update convenience; the REST state is the truth.

## MCP mode

`Loki.serve_mcp(; port, public_url, tables)` does everything `serve` does and also runs an
MCP server over **stdio** in the same process, against the same session. The
agent's edits appear live in the browser and the user's edits are visible to
the agent: there is one graph, one cache and one lock. Stdout belongs to the
JSON-RPC stream, so all logging goes to stderr, and the startup message there
(and the `get_web_url` tool) gives the browser URLs — local, and tailnet when
`public_url` is set — with the token.

A Claude Code configuration is one line:

```json
{ "mcpServers": { "loki": { "command": "julia", "args": ["-e", "using Loki; Loki.serve_mcp()"] } } }
```

The server is built with **ModelContextProtocol.jl**: `mcp_server(name = "loki", tools, resources)`
with its default stdio transport, and `start!(server)` on its own task, after the
web server is up. Tool handlers run on that task and reach the session only
through the command layer, whose lock serializes them against browser requests,
under `withorigin(:mcp)` — the counterpart of the `withorigin(:ui)` the HTTP
handler sets, and what lets the browser show what the agent just did.

`start!` **blocks** in its read loop until stdin closes, which is why
`serve_mcp` blocks too: the configuration above is a process whose job is to be
that server, and a `serve_mcp` that returned would end it. `wait = false` leaves
the loop on its own task, for the REPL and for the tests, and `transport` takes
a `StdioTransport` over any pair of streams, which is how the tests drive it
over a pipe without a second Julia. `start!` also installs its own global
logger, so that `@info` reaches the client as `notifications/message`, and never
takes it back; `stop!` returns the one it displaced, so a session served and
stopped inside a larger process leaves logging as it found it. Ending the loop
means closing the transport's input: `close` on the transport only flips a flag,
and the loop is blocked in `readline`.

| Tool | Purpose |
|---|---|
| `list_node_kinds` | the catalog — names, categories, ports — and, for one `kind` or one `category`, each kind's `paramschema` |
| `get_graph` | nodes, edges, params, status, taint |
| `add_node`, `update_node`, `remove_node` | edit nodes; `params` is an open object, because one tool cannot carry forty-nine schemas — the kind's `paramschema` comes from `list_node_kinds`, so the user and an agent still edit one vocabulary. `update_node` merges, and a `null` removes, exactly as `PATCH` does |
| `connect`, `disconnect` | edit edges |
| `set_context`, `remove_context`, `load_table` | session state; `load_table` reads a CSV or parquet path through the same DuckDB reader an upload goes through |
| `run` | evaluate nodes and wait for them, with progress through `send_progress` fed by the engine's stream loop, throttled to the interval the event stream uses. Reports every node that errored, not only the targets: a target downstream of a failure is `blocked` and the error is upstream |
| `get_result_summary` | `resultsummary`: schema, row count, per-column summary statistics, head and tail |
| `get_diagnostic` | a diagnostic's numeric summary: ACF/PACF values and significant lags, test statistics and p-values. The plot-ready `data` is dropped unless `include_data` asks for it — the correlograms and the tests already carry their numbers in the summary, and the fan is the one that does not |
| `fit_insample` | add a fit node on a port and return its residual summary — Ljung–Box p-values, significant residual ACF lags, information criteria. A fit that cannot be wired is taken back out; one that runs and fails stays, because it is the proposal being judged |
| `export_julia` | the script |
| `save`, `open` | persistence; `open` is `opensession!`, so the session the browser is watching is the one that changes |
| `get_web_url` | the local URL and, when `public_url` is set, the tailnet URL for a phone, to hand to the user |

Resources expose the same state for clients that prefer reading to calling:
`loki://graph` as an `MCPResource`, and `loki://node/{id}/result` as a
`ResourceTemplate`. Every result an agent receives is a summary sized for a
context window, never a data dump; the rows themselves are in the browser.

ModelContextProtocol.jl also offers an HTTP transport. Serving MCP on the web
server's port is a natural later step, and nothing in the command layer depends
on the transport.

## Export

`exportjulia(session; tables = :argument)` returns the graph as a script that
runs without Loki's server, and `exportjulia(path, session; tables = :snapshot)`
writes it to `path`:

1. `using CausalFrames, Loki, Dates, Statistics` — the user module's own
   imports, so source-text parameters mean in the script what they meant in the
   session, and anything else they need (MLJ and a model's package among them)
   is already in the prelude, which is the only reason the session could
   evaluate them. `using DuckDB, Parquet2` when a parquet node is present, and
   `using Loki.Acausal: insample` or `using CausalFrames.Acausal: lead,
   futurejoin` for the acausal names the script actually calls, so the
   dependence on looking ahead is visible at the top;
   `CausalFrames.Acausal.settime` is written in full, being deliberately
   unexported;
2. the prelude, verbatim;
3. the named contexts as `const` bindings;
4. one binding per node output in topological order, `p_<id> = p_<in> |> op(args...)`
   (`p_<id>_<port>` for a node with several outputs), from each kind's `emit` — a
   fan-out reuses a binding, a multi-input node takes bindings as arguments, and a
   Loki composite (`macd`, `arma`, `insample`) exports as its own call rather
   than its expansion. A write node keeps its binding, but its consumers read its
   *input* — the pass-through a run compiles — and no target loads it, so
   including a script never writes a file; the commented `scan` line at the foot
   is how to run one;

   The script holds what the targets need, as a run compiles them — their
   ancestors, plus the write nodes hanging off that much of the graph — and not
   the rest: a node the targets do not reach is left out, and a half-wired one
   can no more fail an export than it fails a run. Exporting every sink, the
   default with no run, does reach such a node and reports it. The session
   *file* is not narrowed: it holds the whole graph, half-wired nodes included,
   because it is the analysis and not a rendering of it;
5. `load` of the watched nodes — the last run's targets, or every output nothing
   reads — as `frame_<id>[_<port>] = load(analysis, p_…)`.

Table sources have no file behind them, so a `table` node exports as
`readtable(tables.<name>; …)`, exactly what it builds, and `tables` is either
snapshotted or supplied:

- `tables = :snapshot` writes each table beside the script and defines `tables`
  to read it back. A plain table becomes a parquet file (`Parquet2.writefile`,
  read back as `DataFrame(Parquet2.Dataset(path))`), which needs no `:time`
  column, so a `lookupjoin`'s table snapshots too. A frozen `CausalFrame` goes
  through the pipeline it came from — `readtable(frame) |> writeparquet` when its
  columns allow, `writejls` when they hold what parquet cannot, a `FittedARMA`
  say — and is read back with `load(ctx, readparquet(path; closed = true))` over
  its own context, so it returns as the frame it was and keeps `readtable`'s
  frame semantics. A plain table parquet cannot hold is an error naming the
  column: freeze the node that produced it, or pass `tables = :argument`.
- `tables = :argument` expects the caller to supply a `NamedTuple` with a field
  per table the script reads. A table only a left-out node names is neither
  declared nor snapshotted.

Script text is printed by Loki's own emitter rather than `string(::Expr)`, so
the output is stable enough to be golden-tested and diffed in version control;
source text is passed through exactly as it was typed, and a keyword already at
its operator's default is left out. The export is correct when **including the
script reproduces the session**: the frames it loads equal the session's cached
frames for the same nodes. That is a test, not a hope.

## Persistence

`savesession(path, session)` writes a `.loki.json` file, and
`opensession(path)` reads one back:

```json
{
  "format": "loki", "version": 1,
  "contexts": { "analysis": { "timetype": "DateTime", "start": "2015-01-01T00:00:00", "stop": "2026-01-01T00:00:00" } },
  "prelude": "",
  "nextid": 7,
  "nodes": [ { "id": "n3", "kind": "difference", "params": { "column": "close_log", "order": 1, "lag": 1 }, "position": [420, 180] } ],
  "edges": [ { "id": "e4", "from": ["n2", "out"], "to": ["n3", "in"] } ],
  "tables": [ { "name": "prices", "path": "analysis.tables/prices.parquet", "format": "parquet", "frame": false } ]
}
```

The header is the JLS file's precedent: a foreign or future file is reported as
such, not as a parse failure, and so is a file that carries the header but not
the contexts, nodes and edges it must have. No data is stored in the session file; tables are
referenced by path, and saving a session writes each one into a `<stem>.tables/`
directory beside it, as an exported script's snapshots are written beside the
script (see "Export") — a frozen frame carries the context it is read back over.
That directory is Loki's, so saving again sweeps the snapshots nothing references
any more (a table dropped or renamed, or a frame that now needs JLS where it
needed parquet), leaving anything else in it alone; a script's directory is the
caller's and is never swept.
A session remembers the file it was last saved to or opened from, as
`Session.file`, so a second save overwrites it without being told where again
and a browser can show what it is looking at; `reset!` forgets it.
Parameters hold source text, never evaluated values, so a session file is as
portable as the exported script. The graph's next id is saved with it, so an id
freed before saving is not handed out again after opening; opening adds every
node and edge through the session's own commands, so a file with a parameter the
kind does not accept fails on that node rather than silently.

## Module layout

| File | Content |
|---|---|
| `src/Loki.jl` | module, includes, exports |
| `src/graph.jl` | `Graph`, `Node`, edges, cycle check, topological order, taint |
| `src/registry.jl` | `NodeKind` interface and `register_nodekind!` |
| `src/nodes/causalframes.jl` | the node kinds wrapping CausalFrames operators |
| `src/nodes/timeseries.jl` | the node kinds for Loki's operators, including the two-port fit node |
| `src/timeseries/summarizers.jl` | `Lags`, `EMA`, `FitARMA`, `FittedARMA`, `ARMAFilter` |
| `src/timeseries/operators.jl` | `lags`, `difference`, `logtransform`, `boxcox`, `ema`, `macd`, `ar`, `fitarma`, `applyarma`, `arma`, `fitonce`, `applyfit` |
| `src/acausal.jl` | the `Loki.Acausal` submodule: `insample` |
| `src/compile.jl` | node compilation, `tagged`, `NodeError` |
| `src/engine.jl` | runs, cancellation, the cache and `cachedsource` |
| `src/diagnostics.jl` | the diagnostic functions and `DiagnosticResult` |
| `src/usercode.jl` | session modules, prelude, parsing expression parameters |
| `src/export.jl` | `exportjulia` and the script emitter |
| `src/tables.jl` | table snapshots: `savetable`, `loadtable` and what a script reads them back with |
| `src/persist.jl` | `.loki.json` save and open |
| `src/events.jl` | events, subscribers, and the origin of a change |
| `src/session.jl` | `Session`, named contexts, tables, the command layer and events |
| `src/server.jl` | HTTP routes, WebSocket, static bundle, `serve` |
| `src/mcp.jl` | tools, resources, `serve_mcp` |
| `src/precompile.jl` | PrecompileTools workload |
| `web/` | web app sources |
| `assets/web/` | the built bundle |

Exports: `Lags`, `EMA`, `FitARMA`, `FittedARMA`, `ARMAFilter`, `lags`,
`difference`, `logtransform`, `boxcox`, `ema`, `macd`, `ar`, `fitarma`,
`applyarma`, `arma`, `fitonce`, `acf`, `pacf`, `ljungbox`, `adftest`,
`fitreport`, `forecastfan`, `serve`, `serve_mcp`, `exportjulia`.
`Loki.Acausal` and its `insample` are not in this list, for CausalFrames'
reason: acausality is an explicit opt-in.

Dependencies: CausalFrames, **with all of its optional dependencies taken as
hard dependencies** — DuckDB, Parquet2 and MLJModelInterface — so loading Loki
loads CausalFrames' three extensions and every operator in the catalog is
available without the user knowing which package enables it. Also
StateSpaceModels (with MatrixEquations, already its dependency, for the filter's
initial covariance), ModelContextProtocol, HTTP, JSON3, DataFrames, Tables,
StatsBase, HypothesisTests, StatsFuns, PrecompileTools, and the `Dates`,
`LinearAlgebra` and `Random` stdlibs. StatsBase and HypothesisTests are imported
as modules, never `using`'d: `StatsBase.pacf` would clash with Loki's own
exported `pacf`, and extending it on a `CausalFrame` would be piracy. Table snapshots go through CausalFrames' own file
operators, so Loki never reaches for `Serialization` itself. StateSpaceModels is imported as a module alias
(`SSM`), never `using`'d: its `LinearRegression` clashes with CausalFrames'.

The consequences are deliberate. Load time is higher than CausalFrames' own,
which is the price of an application rather than a library. The precompile
workload can cover the parquet paths, which CausalFrames' cannot, since there
they are weak dependencies. MLJ **models** are still the user's to load:
MLJModelInterface runs in its light mode without MLJBase, so an MLJ node needs
`using MLJ` and the model's package in the session, and the node kind says so
when they are absent.

CausalFrames is not registered. Until it is, `Project.toml` names it in
`[sources]` by URL, which every supported Julia reads. The Manifest stays out of
version control.

Package infrastructure follows CausalFrames, with **Julia 1.12 as the minimum**.
Loki is an application, not a library other packages depend on, so it has no
reason to carry the accommodations an older floor costs: `[sources]` is read
without a workaround, `mul!` is statically dispatched in the ARMA filter's inner
loop, and `Base.ScopedValues` carries a command's origin into the run worker.
The rest follows CausalFrames: `test/` with Aqua and targeted JET checks, a
Documenter site, JuliaFormatter, and this file as the source of truth for the
design.

## Testing

- **Operators.** Each Loki operator has unit tests and the streaming property:
  concatenating `stream(ctx, p)` equals `load(ctx, p)` across chunk sizes.
  `Lags` and `difference` against direct indexing; `EMA` and `macd` against
  reference values; `ar` against a direct least-squares fit.
- **ARMA.** `FitARMA` against `SARIMA` + `fit!` called directly. `ARMAFilter`
  differentially against `kalman_filter`, `get_innovations` and
  `get_innovations_variance` with the fitted hyperparameters and the
  steady-state shortcut disabled, including `NaN` observations and a model
  change mid-stream; forecasts against `forecast`. `insample` residuals against the
  same reference.
- **Engine.** Cached and uncached evaluation give equal frames for every
  operator family, including the widening and stateful ones; error tags land on
  the failing node; cancellation leaves no running task.
- **Graph.** Cycle rejection, topological order, taint propagation.
- **Export.** For a corpus of graphs, including the script reproduces the
  session's frames; the emitted text is golden-tested.
- **Server and MCP.** HTTP and WebSocket tests against a running server; MCP
  tests drive `serve_mcp` over a pipe and check that an MCP edit produces a
  WebSocket event.
- **Web app.** A Playwright smoke test in two projects: desktop Chromium, and
  WebKit with Playwright's iPhone device profile (touch, narrow viewport). Both
  build a graph, run it, open a diagnostic and export; the iPhone project does it
  by tap only, and also drops and restores the WebSocket to check that the client
  resyncs.
- **Access control.** Requests with a foreign `Origin`, or without a valid
  token or session cookie, are rejected; the configured `public_url` origin is
  accepted; one printed URL authenticates both a desktop and a phone (the token
  is per session, not single-use).

## Milestones

0. Package scaffolding: dependencies, the module skeleton, the Aqua and JET
   test harness, formatting, the Documenter site, and CI. *Done.*
1. Loki's time-series operators, `insample`, the fit node's two ports, the
   graph, and the engine — usable headless from the REPL. *Done:* every
   operator in the catalog above, the node registry and graph, the session's
   user code, and the engine and cache behind a headless `Session`.
2. Export and persistence. *Done:* `emit` on every node kind and Loki's own
   script printer, `exportjulia` with table snapshots, and
   `savesession`/`opensession` for `.loki.json`. Including an exported script
   reproduces the session's frames, and the emitted text is golden-tested.
3. The server and web app, with diagnostics and the residual panel. *Done:*
   every diagnostic in the table above behind `Loki.diagnostic`, session events
   with their origin, the HTTP server with its token, cookie, `Origin` and
   `Host` checks, the WebSocket, and the web app — canvas, palette, inspector,
   diagnostics and table, on a laptop and on a phone. The Julia suite covers the
   access-control list bullet by bullet; two Playwright projects, desktop and an
   iPhone profile that may only tap, drive the app against a live server.
4. MCP mode. *Done:* `serve_mcp`, the seventeen tools and the two resources
   above over ModelContextProtocol.jl's stdio transport against the same
   session the browser has, `Loki.resultsummary` behind `get_result_summary`,
   and tests that drive the server over a pipe in-process — including the one
   that matters: an agent's edit arrives on the browser's WebSocket carrying
   `origin = "mcp"`.
5. Breadth: seasonal models in the UI, more diagnostics, undo and redo.

## Open questions

- **Upstreaming.** Whether `Lags`, `EMA`, `difference` and a `CausalPipeline`
  run accessor belong in CausalFrames.
- **Undo and redo** across two clients: a single linear history, or one per
  origin.
- **Shipping the bundle to users without Node.** `assets/web` is built, not
  committed, which is right for the repository; a released package still needs a
  committed bundle or an `Artifacts.toml`.
- **Tailscale identity.** `tailscale serve` adds identity headers
  (`Tailscale-User-Login`) to proxied requests. Checking them against an allowed
  login would add a second factor for phone access; whether that is worth
  the configuration over the token alone is open.
