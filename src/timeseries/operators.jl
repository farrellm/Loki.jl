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
