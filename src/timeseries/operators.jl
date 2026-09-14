# Loki's time-series operators: CausalFrames sources and curried transforms built
# from its exported operators and Loki's summarizers. Each transform `op(args...)`
# returns `CausalPipeline -> CausalPipeline`; `op(p, args...)` applies it. Row
# functions are callable structs carrying their column names as type
# parameters, so `addcolumns`' per-chunk barrier specializes on them and the
# row access compiles to field loads.

# --- lags --------------------------------------------------------------------

"""
    lags(column::Symbol, p::Integer; key = nothing, name = Symbol(column, :_lag))
        -> (CausalPipeline -> CausalPipeline)
    lags(pipeline::CausalPipeline, column::Symbol, p::Integer; ...) -> CausalPipeline

A transform appending the previous `p` values of `column` as `x_lag_1, …,
x_lag_p` (`missing` where there is not enough history): `addsummarycolumns` of
[`Lags`](@ref). With `key`, the history is kept per key.
"""
lags(column::Symbol, p::Integer; key = nothing, name::Symbol = Symbol(column, :_lag)) =
    addsummarycolumns(Lags(column, p; name); key)
lags(pipeline::CausalPipeline, column::Symbol, p::Integer; kwargs...) =
    lags(column, p; kwargs...)(pipeline)

# --- difference ----------------------------------------------------------------

"""
    difference(column::Symbol; order = 1, lag = 1, key = nothing, name = nothing)
        -> (CausalPipeline -> CausalPipeline)
    difference(pipeline::CausalPipeline, column::Symbol; ...) -> CausalPipeline

A transform appending the `order`-th difference of `column` at row lag `lag`,
`Δₛᵈ xₜ = Σₖ (-1)ᵏ C(d, k) xₜ₋ₖₛ` for `d = order` and `s = lag`. The output column is
`x_diff` for the first difference and `x_diff_{order}_{lag}` otherwise, or
`name`. It is `missing` for the first `order * lag` rows (of each key, with
`key`).
"""
function difference(column::Symbol; order::Integer = 1, lag::Integer = 1,
    key = nothing, name::Union{Nothing,Symbol} = nothing)
    order >= 1 || throw(ArgumentError("difference needs order >= 1, got $order"))
    lag >= 1 || throw(ArgumentError("difference needs lag >= 1, got $lag"))
    out = something(name,
        order == 1 && lag == 1 ? Symbol(column, :_diff) :
        Symbol(column, :_diff_, order, :_, lag))
    # A private prefix, so a lag column the caller already has cannot collide.
    prefix = Symbol("#", column, :_difflag)
    lagcols = lagnames(prefix, order * lag)
    used = ntuple(k -> lagcols[k*lag], order)
    weights = ntuple(k -> (-1)^k * binomial(Int(order), k), order)
    f = DiffRow{column,used,out,typeof(weights)}(weights)
    return function (p::CausalPipeline)
        return p |> lags(column, order * lag; key, name = prefix) |> addcolumns(f) |>
               dropcolumns(lagcols...)
    end
end
difference(pipeline::CausalPipeline, column::Symbol; kwargs...) =
    difference(column; kwargs...)(pipeline)

struct DiffRow{C,L,O,W<:Tuple}
    weights::W
end

@inline function (f::DiffRow{C,L,O})(row) where {C,L,O}
    x = getproperty(row, C)
    lagged = map(n -> getproperty(row, n), L)
    return NamedTuple{(O,)}((x + sum(map(*, f.weights, lagged)),))
end

# --- transforms ----------------------------------------------------------------

"""
    logtransform(column::Symbol; name = Symbol(column, :_log))
        -> (CausalPipeline -> CausalPipeline)
    logtransform(pipeline::CausalPipeline, column::Symbol; ...) -> CausalPipeline

A row-wise transform appending the natural logarithm of `column` as `x_log`, or
`name`. `missing` stays `missing`.
"""
logtransform(column::Symbol; name::Symbol = Symbol(column, :_log)) =
    addcolumns(LogRow{column,name}())
logtransform(pipeline::CausalPipeline, column::Symbol; kwargs...) =
    logtransform(column; kwargs...)(pipeline)

struct LogRow{C,O} end
@inline (::LogRow{C,O})(row) where {C,O} = NamedTuple{(O,)}((log(getproperty(row, C)),))

"""
    boxcox(column::Symbol; lambda::Real, name = Symbol(column, :_boxcox))
        -> (CausalPipeline -> CausalPipeline)
    boxcox(pipeline::CausalPipeline, column::Symbol; ...) -> CausalPipeline

A row-wise transform appending the Box–Cox transform of `column` with a fixed
`lambda`, `(x^λ - 1) / λ` (`log(x)` when `λ = 0`), as `x_boxcox`, or `name`.
`missing` stays `missing`.

`λ` is a parameter, not an estimate: estimating it looks at the whole window,
which no causal operator may do.
"""
function boxcox(column::Symbol; lambda::Real, name::Symbol = Symbol(column, :_boxcox))
    isfinite(lambda) || throw(ArgumentError("boxcox lambda must be finite, got $lambda"))
    return addcolumns(BoxCoxRow{column,name}(Float64(lambda)))
end
boxcox(pipeline::CausalPipeline, column::Symbol; kwargs...) =
    boxcox(column; kwargs...)(pipeline)

struct BoxCoxRow{C,O}
    lambda::Float64
end
@inline (f::BoxCoxRow{C,O})(row) where {C,O} =
    NamedTuple{(O,)}((boxcoxvalue(getproperty(row, C), f.lambda),))

boxcoxvalue(::Missing, ::Float64) = missing
boxcoxvalue(x::Real, lambda::Float64) =
    iszero(lambda) ? log(float(x)) : (float(x)^lambda - 1) / lambda

# --- moving averages -------------------------------------------------------------

"""
    ema(column::Symbol; span = nothing, halflife = nothing, name = nothing,
        key = nothing) -> (CausalPipeline -> CausalPipeline)
    ema(pipeline::CausalPipeline, column::Symbol; ...) -> CausalPipeline

A transform appending the exponential moving average of `column`:
`addsummarycolumns` of [`EMA`](@ref), whose keywords it takes. With `key`, each
key has its own average.
"""
ema(column::Symbol; key = nothing, kwargs...) =
    addsummarycolumns(EMA(column; kwargs...); key)
ema(pipeline::CausalPipeline, column::Symbol; kwargs...) = ema(column; kwargs...)(pipeline)

"""
    macd(column::Symbol; fast = 12, slow = 26, signal = 9, name = :macd,
         key = nothing) -> (CausalPipeline -> CausalPipeline)
    macd(pipeline::CausalPipeline, column::Symbol; ...) -> CausalPipeline

A transform appending the moving average convergence/divergence of `column`:
`macd`, the `fast`-span minus the `slow`-span [`EMA`](@ref); `macd_signal`, the
`signal`-span EMA of `macd`; and `macd_hist`, their difference. `name` replaces
the `macd` prefix. With `key`, every average is kept per key.
"""
function macd(column::Symbol; fast::Integer = 12, slow::Integer = 26,
    signal::Integer = 9, name::Symbol = :macd, key = nothing)
    1 <= fast < slow || throw(
        ArgumentError("macd needs 1 <= fast < slow, got fast = $fast, slow = $slow"))
    signal >= 1 || throw(ArgumentError("macd needs signal >= 1, got $signal"))
    fastname = Symbol("#", name, :_fast)
    slowname = Symbol("#", name, :_slow)
    signalname = Symbol(name, :_signal)
    return function (p::CausalPipeline)
        return p |>
               addsummarycolumns(
                   [EMA(column; span = fast, name = fastname),
                       EMA(column; span = slow, name = slowname)]; key) |>
               addcolumns(ColumnDiff{fastname,slowname,name}()) |>
               addsummarycolumns(EMA(name; span = signal, name = signalname); key) |>
               addcolumns(ColumnDiff{name,signalname,Symbol(name, :_hist)}()) |>
               dropcolumns(fastname, slowname)
    end
end
macd(pipeline::CausalPipeline, column::Symbol; kwargs...) =
    macd(column; kwargs...)(pipeline)

struct ColumnDiff{A,B,O} end
@inline (::ColumnDiff{A,B,O})(row) where {A,B,O} =
    NamedTuple{(O,)}((getproperty(row, A) - getproperty(row, B),))

# --- autoregression ----------------------------------------------------------------

"""
    ar(column::Symbol, p::Integer; key = nothing, name = :ar)
        -> (CausalPipeline -> CausalPipeline)
    ar(pipeline::CausalPipeline, column::Symbol, p::Integer; ...) -> CausalPipeline

A transform fitting an AR(`p`) model of `column` by least squares over the
whole window: [`lags`](@ref), dropping the rows without a complete history,
then `summarize` of CausalFrames' `LinearRegression` of `column` on
`x_lag_1, …, x_lag_p`, with an intercept. One row per key is emitted at the
window's `stop`; its columns are the regression's, prefixed by `name`
(`ar_intercept_beta`, `ar_x_lag_1_beta`, …, `ar_r2`, `ar_n`).

Because it is a `LinearRegression`, it shares accumulators with a `Variance` or
`Correlation` over the same columns in the same `summarize`.
"""
function ar(column::Symbol, p::Integer; key = nothing, name::Symbol = :ar)
    p >= 1 || throw(ArgumentError("ar needs p >= 1, got $p"))
    lagcols = lagnames(Symbol(column, :_lag), p)
    fit = LinearRegression(collect(lagcols), column; name)
    return function (pipeline::CausalPipeline)
        return pipeline |> lags(column, p; key) |>
               filterrows(CompleteRows{(column, lagcols...)}()) |> summarize(fit; key)
    end
end
ar(pipeline::CausalPipeline, column::Symbol, p::Integer; kwargs...) =
    ar(column, p; kwargs...)(pipeline)

# A row predicate: no `missing` in any of the columns `Cols`.
struct CompleteRows{Cols} end
@inline (::CompleteRows{Cols})(row) where {Cols} =
    !any(ismissing, map(c -> getproperty(row, c), Cols))

# --- ARMA ------------------------------------------------------------------------

"""
    fitarma(column::Symbol; order, seasonal_order = (0, 0, 0, 0),
            include_mean = false, name = :model, key = nothing)
        -> (CausalPipeline -> CausalPipeline)
    fitarma(pipeline::CausalPipeline, column::Symbol; ...) -> CausalPipeline

A transform fitting one seasonal ARIMA model of `column` per key over the whole
window: `summarize` of [`FitARMA`](@ref), whose keywords it takes, emitting a
[`FittedARMA`](@ref) in the column `name` at the window's `stop`.
"""
fitarma(column::Symbol; key = nothing, kwargs...) =
    summarize(FitARMA(column; kwargs...); key)
fitarma(pipeline::CausalPipeline, column::Symbol; kwargs...) =
    fitarma(column; kwargs...)(pipeline)

"""
    applyarma(models::CausalPipeline, x::Symbol; column = :model, key = nothing,
              tolerance = nothing, strict = false, horizon = 0, name = x)
        -> (CausalPipeline -> CausalPipeline)
    applyarma(pipeline::CausalPipeline, models::CausalPipeline, x::Symbol; ...)
        -> CausalPipeline

A transform filtering the series `x` with fitted ARIMA models. `models` is a
pipeline whose `column` holds [`FittedARMA`](@ref)s — the output of
[`FitARMA`](@ref) under any summarizing transform, of [`fitonce`](@ref), or a
file of them. Each row is matched to the most recent model row not after it
(`strict = true`: strictly before) by `asofjoin`, with its `key` and `tolerance`,
and filtered by [`ARMAFilter`](@ref), appending `x_fitted`, `x_residual`,
`x_stdresidual` and `horizon` forecasts (named from `name`). The model column
is dropped. Rows with no model get `missing`.

This is `applymodels`' composition: the as-of store supplies the model and the
summarizer carries the filter state, restarting whenever the model changes.
"""
function applyarma(models::CausalPipeline, x::Symbol; column::Symbol = :model,
    key = nothing, tolerance = nothing, strict::Bool = false, horizon::Integer = 0,
    name::Symbol = x)
    filter = ARMAFilter(x; model = column, horizon, name)
    keycols = tokeys(key)
    column in keycols &&
        throw(ArgumentError("applyarma model column $column may not be a key column"))
    # Predicates, unlike names, do not fail on an absent column: a models stream
    # with no rows reaches the filter without one, which then emits `missing`.
    right = models |> selectcolumns(n -> Symbol(n) === column || Symbol(n) in keycols)
    return function (p::CausalPipeline)
        return p |> asofjoin(right; key, tolerance, strict) |>
               addsummarycolumns(filter; key) |> dropcolumns(n -> Symbol(n) === column)
    end
end
applyarma(pipeline::CausalPipeline, models::CausalPipeline, x::Symbol; kwargs...) =
    applyarma(models, x; kwargs...)(pipeline)

tokeys(::Nothing) = Symbol[]
tokeys(k::Union{Symbol,AbstractString}) = Symbol[Symbol(k)]
tokeys(ks) = Symbol[Symbol(k) for k in ks]

"""
    arma(clock::CausalPipeline, lookback, x::Symbol; order,
         seasonal_order = (0, 0, 0, 0), include_mean = false, key = nothing,
         horizon = 0, name = x) -> (CausalPipeline -> CausalPipeline)
    arma(pipeline::CausalPipeline, clock::CausalPipeline, lookback, x::Symbol; ...)
        -> CausalPipeline

A transform filtering `x` with a seasonal ARIMA model refit on a rolling window.
At every tick `τ` of `clock` a model is fit over the rows in `[τ - lookback, τ)`
(`summarizewindows` of [`FitARMA`](@ref)), and each row from `τ` until the next
tick is filtered by it ([`applyarma`](@ref)), appending the same columns. The
windows are half-open, so every row is filtered by a model fit only on rows
before it. Rows before the first fitted tick, and a key with no rows in the
latest window, get `missing`. The pipeline runs twice, once to fit and once to
filter, as a self-join does.
"""
function arma(clk::CausalPipeline, lookback, x::Symbol; order,
    seasonal_order = (0, 0, 0, 0), include_mean::Bool = false, key = nothing,
    horizon::Integer = 0, name::Symbol = x)
    modelcol = Symbol("#", x, :_armamodel)
    fits = summarizewindows(clk, lookback,
        FitARMA(x; order, seasonal_order, include_mean, name = modelcol); key)
    return function (p::CausalPipeline)
        return p |> applyarma(p |> fits, x; column = modelcol, key, horizon, name)
    end
end
arma(pipeline::CausalPipeline, clk::CausalPipeline, lookback, x::Symbol; kwargs...) =
    arma(clk, lookback, x; kwargs...)(pipeline)

# --- fitting over another context --------------------------------------------------

"""
    fitonce(trainctx::Context, s::Summarizer; key = nothing)
        -> (CausalPipeline -> CausalPipeline)
    fitonce(pipeline::CausalPipeline, trainctx::Context, s::Summarizer; ...)
        -> CausalPipeline

A transform fitting once over a fixed training window. Whatever context it runs
over, it loads `pipeline |> summarize(s; key)` over `trainctx` and yields the
model rows — timed at `trainctx.stop` — that fall inside the run's context.

That timing is what makes it causal: applied over a window overlapping
`trainctx`, the rows before `trainctx.stop` get no model rather than one fit on
their own future. To apply the model to a later window, `applyarma`'s (or
`applymodels`') `tolerance` widens the models' context back to it. The fit is
loaded on every run.
"""
function fitonce(trainctx::Context, s::Summarizer; key = nothing)
    return function (p::CausalPipeline)
        fit = p |> summarize(s; key)
        return CausalPipeline() do ctx::Context
            frame = load(trainctx, fit)
            # One of Loki's recorded reads of a pipeline's `run` field: the
            # fitted frame is served as this pipeline's source.
            return readtable(frame; checkcontext = false).run(ctx)
        end
    end
end
fitonce(pipeline::CausalPipeline, trainctx::Context, s::Summarizer; kwargs...) =
    fitonce(trainctx, s; kwargs...)(pipeline)

# --- applying fits -------------------------------------------------------------------

"""
    Loki.applyfit(s::Summarizer, p::CausalPipeline, models::CausalPipeline;
                  key = nothing) -> CausalPipeline

Apply the model rows produced by the fitting summarizer `s` — a pipeline of
`summarize(s; key)`'s output — to the stream `p`, appending the model's fitted
values and residuals. Each row uses the latest model row not after it (per key).
This is the causal half of [`Loki.Acausal.insample`](@ref); a new fitting
summarizer supports `insample` by adding a method.

| `s` | Apply | Columns appended |
|---|---|---|
| [`FitARMA`](@ref) | [`applyarma`](@ref) | `x_fitted`, `x_residual`, `x_stdresidual` |
| CausalFrames' `LinearRegression` | `asofjoin` of the coefficients, then `β·x` | `y_fitted`, `y_residual` |
| CausalFrames' `FitModel` (MLJ) | `applymodels` | `y_fitted`, `y_residual` |

The `FitModel` residual subtracts the prediction, so it needs a deterministic
regressor.
"""
function applyfit end

applyfit(::FitARMA{C,N}, p::CausalPipeline, models::CausalPipeline;
    key = nothing) where {C,N} = p |> applyarma(models, C; column = N, key)

# Reads LinearRegression's type parameters and its `intercept` and `name` fields
# (recorded in DESIGN.md): which columns it regresses on, and the names it gave
# its coefficients.
function applyfit(s::LinearRegression{P,Y}, p::CausalPipeline, models::CausalPipeline;
    key = nothing) where {P,Y}
    prefixed(base) = s.name === nothing ? base : Symbol(s.name, :_, base)
    betas = (s.intercept ? (prefixed(:intercept_beta),) : ())
    betas = (betas..., map(q -> prefixed(Symbol(q, :_beta)), P)...)
    keycols = tokeys(key)
    right = models |> selectcolumns(n -> Symbol(n) in betas || Symbol(n) in keycols)
    # The coefficients arrive under a private prefix, so they cannot collide with
    # the stream's own columns.
    joined = map(b -> Symbol("#fit_", b), betas)
    f = LinearFitRow{P,Y,joined,s.intercept,Symbol(Y, :_fitted),Symbol(Y, :_residual)}()
    return p |> asofjoin(right; key, rightprefix = "#fit") |> addcolumns(f) |>
           dropcolumns(joined...)
end

applyfit(::FitModel{N,P,Y}, p::CausalPipeline, models::CausalPipeline;
    key = nothing) where {N,P,Y} =
    p |> applymodels(models; column = N, key, name = Symbol(Y, :_fitted)) |>
    addcolumns(ColumnDiff{Y,Symbol(Y, :_fitted),Symbol(Y, :_residual)}())

# `β₀ + Σ βₚ xₚ` (without β₀ when `I` is false) and the residual, from the
# joined coefficient columns `B` and the predictor columns `P`.
struct LinearFitRow{P,Y,B,I,F,R} end
@inline function (::LinearFitRow{P,Y,B,I,F,R})(row) where {P,Y,B,I,F,R}
    betas = map(b -> getproperty(row, b), B)
    xs = map(q -> getproperty(row, q), P)
    fitted = linearfit(Val(I), betas, xs)
    return NamedTuple{(F, R)}((fitted, getproperty(row, Y) - fitted))
end
@inline linearfit(::Val{true}, betas, xs) = first(betas) + sum(map(*, Base.tail(betas), xs))
@inline linearfit(::Val{false}, betas, xs) = sum(map(*, betas, xs))

"""
    Loki.fitinput(s::Summarizer, p::CausalPipeline) -> CausalPipeline

The stream the fitting summarizer `s` is fit on under
[`Loki.Acausal.insample`](@ref): `p` itself by default. `LinearRegression` and
`FitModel` drop the rows with a `missing` predictor or response, which would
otherwise poison the fit, so a regression over row lags fits on the rows with a
complete history. [`FitARMA`](@ref) keeps them, as gaps in the series.
"""
fitinput(::Summarizer, p::CausalPipeline) = p
fitinput(::LinearRegression{P,Y}, p::CausalPipeline) where {P,Y} =
    p |> filterrows(CompleteRows{(P..., Y)}())
fitinput(::FitModel{N,P,Y}, p::CausalPipeline) where {N,P,Y} =
    p |> filterrows(CompleteRows{(P..., Y)}())
