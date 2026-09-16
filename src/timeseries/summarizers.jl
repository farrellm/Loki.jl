# Loki's summarizers, written against CausalFrames' summarizer interface: an
# immutable configuration carrying its column and output names as type
# parameters, and a mutable state typed from the input schema. The interface
# functions are unexported in CausalFrames and extended qualified. Per-row work
# (`update!`, `value`) takes concretely typed states, so the folding kernels
# specialize on them; each has a `JET.@test_opt` check in test/jet.jl.

# --- Lags --------------------------------------------------------------------

"""
    Lags(column::Symbol, p::Integer; name = Symbol(column, :_lag))

A summarizer whose value is the previous `p` values of `column` —
`x_lag_1, …, x_lag_p`, each of element type `Union{Missing, T}` for an input
column of element type `T`, and `missing` where the history is too short. `name`
replaces the `x_lag` prefix of the output columns.

Under `addsummarycolumns` the summary is emitted *after* the current row is
folded, so `x_lag_1` is the value one row back: these are **row** lags, not time
lags (CausalFrames' `lag` shifts by a time offset). Use [`lags`](@ref) for the
transform.
"""
struct Lags{C,P,N} <: Summarizer end

function Lags(column::Symbol, p::Integer; name::Symbol = Symbol(column, :_lag))
    p >= 1 || throw(ArgumentError("Lags needs p >= 1, got $p"))
    return Lags{column,Int(p),lagnames(name, p)}()
end

lagnames(prefix::Symbol, p::Integer) = ntuple(i -> Symbol(prefix, :_, i), p)

# A ring buffer of the last P + 1 values, the newest (the row just folded) at
# `pos`. Slots are written before they are read — `count` says how many hold a
# value — so a non-isbits T never exposes an undefined reference.
mutable struct LagsState{C,P,N,T} <: SummarizerState
    const buf::Vector{T}
    pos::Int
    count::Int
end

LagsState{C,P,N,T}() where {C,P,N,T} = LagsState{C,P,N,T}(Vector{T}(undef, P + 1), 0, 0)

CausalFrames.emptyvalue(::Lags{C,P,N}) where {C,P,N} =
    NamedTuple{N}(ntuple(_ -> missing, Val(P)))
CausalFrames.fresh(::Lags{C,P,N}, intypes::NamedTuple) where {C,P,N} =
    LagsState{C,P,N,intypes[C]}()
CausalFrames.fresh(::LagsState{C,P,N,T}) where {C,P,N,T} = LagsState{C,P,N,T}()
@inline function CausalFrames.fresh!(st::LagsState)
    st.pos = 0
    st.count = 0
    return st
end

@inline function CausalFrames.update!(st::LagsState{C,P}, row) where {C,P}
    pos = st.pos == P + 1 ? 1 : st.pos + 1
    @inbounds st.buf[pos] = getproperty(row, C)
    st.pos = pos
    st.count = min(st.count + 1, P + 1)
    return nothing
end

@inline function CausalFrames.value(st::LagsState{C,P,N,T}) where {C,P,N,T}
    vals = ntuple(Val(P)) do i
        i < st.count ? lagat(st, i) : missing
    end
    return NamedTuple{N,NTuple{P,Union{Missing,T}}}(vals)
end

# The value `i` rows behind the newest; the caller checks `i < count`.
@inline lagat(st::LagsState{C,P}, i::Int) where {C,P} =
    @inbounds st.buf[mod1(st.pos - i, P + 1)]

function CausalFrames.widenstate(st::LagsState{C,P,N,T},
    intypes::NamedTuple) where {C,P,N,T}
    W = intypes[C]
    W === T && return st
    widened = LagsState{C,P,N,W}()
    # Copied oldest first, so the rebuilt buffer's positions are 1:count.
    for i in (st.count-1):-1:0
        widened.buf[st.count-i] = lagat(st, i)
    end
    widened.pos = st.count
    widened.count = st.count
    return widened
end

# --- EMA ---------------------------------------------------------------------

"""
    EMA(column::Symbol; span = nothing, halflife = nothing, name = nothing)

A summarizer holding the exponential moving average of `column`, given exactly
one of:

- `span`: `sₜ = α xₜ + (1 - α) sₜ₋₁` with `α = 2 / (span + 1)`, `span ≥ 1`;
  the output column is `x_ema_{span}`.
- `halflife`: the time-aware form for irregular series,
  `α = 1 - exp(-ln 2 · Δt / halflife)` with `Δt` the time since the previous
  folded value (read from the `time` column). A `Dates` fixed period (such as
  `Minute(5)`) for a `Dates` time type, a positive number for a numeric one;
  the output column is `x_ema_hl_{halflife}`, e.g. `x_ema_hl_5minute`.

The average is seeded with the first value. A `missing` value leaves it
unchanged and emits the current average. The output column, or `name`, has
element type `Union{Missing, Float64}` and is `missing` until the first
non-missing value. Use [`ema`](@ref) for the transform.
"""
struct EMA{C,N,K} <: Summarizer
    alpha::Float64     # K === :span
    halflife::Float64  # K === :period (in milliseconds) or :numeric
end

function EMA(column::Symbol; span::Union{Nothing,Real} = nothing, halflife = nothing,
    name::Union{Nothing,Symbol} = nothing)
    (span === nothing) == (halflife === nothing) &&
        throw(ArgumentError("EMA needs exactly one of span and halflife"))
    if span !== nothing
        span >= 1 || throw(ArgumentError("EMA span must be >= 1, got $span"))
        out = something(name, Symbol(column, :_ema_, span))
        return EMA{column,out,:span}(2 / (span + 1), NaN)
    elseif halflife isa Dates.FixedPeriod
        ms = Float64(Dates.toms(halflife))
        ms > 0 || throw(ArgumentError("EMA halflife must be positive, got $halflife"))
        unit = lowercase(string(nameof(typeof(halflife))))
        out = something(name, Symbol(column, :_ema_hl_, Dates.value(halflife), unit))
        return EMA{column,out,:period}(NaN, ms)
    elseif halflife isa Real && isfinite(halflife) && halflife > 0
        out = something(name, Symbol(column, :_ema_hl_, halflife))
        return EMA{column,out,:numeric}(NaN, Float64(halflife))
    end
    throw(ArgumentError("EMA halflife must be a positive number or a fixed \
        Dates period, got $(repr(halflife))"))
end

mutable struct SpanEMAState{C,N} <: SummarizerState
    const alpha::Float64
    s::Float64
    seen::Bool
end

# `last` is written by the first folded value and read only once `seen`.
mutable struct HalflifeEMAState{C,N,K,T} <: SummarizerState
    const halflife::Float64
    s::Float64
    seen::Bool
    last::T
    HalflifeEMAState{C,N,K,T}(halflife::Float64) where {C,N,K,T} =
        new{C,N,K,T}(halflife, 0.0, false)
end

CausalFrames.emptyvalue(::EMA{C,N}) where {C,N} = NamedTuple{(N,)}((missing,))
CausalFrames.fresh(e::EMA{C,N,:span}, ::NamedTuple) where {C,N} =
    SpanEMAState{C,N}(e.alpha, 0.0, false)
function CausalFrames.fresh(e::EMA{C,N,K}, intypes::NamedTuple) where {C,N,K}
    T = intypes.time
    ok = K === :period ? T <: Dates.TimeType : T <: Real
    ok || throw(ArgumentError("EMA $N: a $(K === :period ? "Dates period" : "numeric") \
        halflife does not fit time type $T"))
    return HalflifeEMAState{C,N,K,T}(e.halflife)
end
CausalFrames.fresh(st::SpanEMAState{C,N}) where {C,N} =
    SpanEMAState{C,N}(st.alpha, 0.0, false)
CausalFrames.fresh(st::HalflifeEMAState{C,N,K,T}) where {C,N,K,T} =
    HalflifeEMAState{C,N,K,T}(st.halflife)
@inline function CausalFrames.fresh!(st::Union{SpanEMAState,HalflifeEMAState})
    st.seen = false
    return st
end

@inline function CausalFrames.update!(st::SpanEMAState{C}, row) where {C}
    v = getproperty(row, C)
    ismissing(v) && return nothing
    st.s = st.seen ? st.alpha * v + (1 - st.alpha) * st.s : Float64(v)
    st.seen = true
    return nothing
end

@inline function CausalFrames.update!(st::HalflifeEMAState{C}, row) where {C}
    v = getproperty(row, C)
    ismissing(v) && return nothing
    t = row.time
    if st.seen
        a = 1 - exp(-log(2.0) * elapsed(t - st.last) / st.halflife)
        st.s = a * v + (1 - a) * st.s
    else
        st.s = Float64(v)
    end
    st.last = t
    st.seen = true
    return nothing
end

# Time differences in the halflife's unit: milliseconds for a Dates period.
elapsed(d::Dates.Period) = Float64(Dates.toms(d))
elapsed(d::Real) = Float64(d)

@inline CausalFrames.value(st::Union{SpanEMAState{C,N},HalflifeEMAState{C,N}}) where {C,N} =
    NamedTuple{(N,),Tuple{Union{Missing,Float64}}}((st.seen ? st.s : missing,))

# --- ARMA ----------------------------------------------------------------------

"""
    FittedARMA

A (seasonal) ARIMA model fitted by [`FitARMA`](@ref), as one cell of a model
column. Its fields:

- `model`: the fitted StateSpaceModels `SARIMA` (`nothing` for a failed fit);
- `order`, `seasonal_order`, `include_mean`: the specification;
- `names`, `coefs`: the hyperparameters by name (`ar_L1`, `ma_L1`, `mean`,
  `sigma2_η`, …) and their fitted values;
- `loglik`, `aic`, `aicc`, `bic`: the information criteria;
- `nobs`: the number of non-missing observations the fit saw;
- `status` (`:ok` or `:failed`) and `message`, the error of a failed fit;
- `Z`, `T`, `RQR`, `c`, `d`, `H`, `a1`, `P1`: the fitted state-space system and
  the filter's initial state, which [`ARMAFilter`](@ref) steps.

It is an ordinary struct, so a model table survives `writejls`/`readjls`.
"""
struct FittedARMA
    model::Union{Nothing,SSM.SARIMA}
    order::NTuple{3,Int}
    seasonal_order::NTuple{4,Int}
    include_mean::Bool
    names::Vector{String}
    coefs::Vector{Float64}
    loglik::Float64
    aic::Float64
    aicc::Float64
    bic::Float64
    nobs::Int
    status::Symbol
    message::String
    Z::Vector{Float64}
    T::Matrix{Float64}
    RQR::Matrix{Float64}
    c::Vector{Float64}
    d::Float64
    H::Float64
    a1::Vector{Float64}
    P1::Matrix{Float64}
end

function Base.show(io::IO, fm::FittedARMA)
    p, d, q = fm.order
    P, D, Q, s = fm.seasonal_order
    spec = iszero(s) ? "ARIMA($p, $d, $q)" : "SARIMA($p, $d, $q)x($P, $D, $Q, $s)"
    fm.status === :ok ||
        return print(io, "FittedARMA(", spec, ", failed: ", fm.message, ")")
    return print(io, "FittedARMA(", spec, ", aic = ", round(fm.aic; sigdigits = 6),
        ", n = ", fm.nobs, ")")
end

"""
    FitARMA(column::Symbol; order, seasonal_order = (0, 0, 0, 0),
            include_mean = false, name = :model)

A summarizer fitting a seasonal ARIMA model `(p, d, q) × (P, D, Q, s)` to
`column` by maximum likelihood (StateSpaceModels' `SARIMA` and `fit!`), emitting
a [`FittedARMA`](@ref) in the column `name`. `missing` values are kept in the
series as gaps, which the likelihood skips.

A fit that throws or does not reach a finite likelihood emits a `FittedARMA`
with `status = :failed` and the error message rather than raising, so under a
rolling refit one bad window does not end the run. The column's element type is
`Union{Missing, FittedARMA}`; an empty window emits `missing`.

`FitARMA` folds by buffering the series and fits when its value is taken, so it
is a plain `Summarizer`: re-folded under rolling windows.
"""
struct FitARMA{C,N} <: Summarizer
    order::NTuple{3,Int}
    seasonal_order::NTuple{4,Int}
    include_mean::Bool
end

function FitARMA(column::Symbol; order, seasonal_order = (0, 0, 0, 0),
    include_mean::Bool = false, name::Symbol = :model)
    (length(order) == 3 && all(>=(0), order)) || throw(
        ArgumentError("FitARMA order must be three non-negative integers (p, d, q), \
            got $(repr(order))"))
    (length(seasonal_order) == 4 && all(>=(0), seasonal_order)) || throw(
        ArgumentError("FitARMA seasonal_order must be four non-negative integers \
            (P, D, Q, s), got $(repr(seasonal_order))"))
    P, D, Q, s = seasonal_order
    P + D + Q > 0 && s < 2 &&
        throw(
            ArgumentError("FitARMA seasonal_order needs a period s >= 2 when P, D or Q \
            is nonzero, got $(repr(seasonal_order))"))
    name === column && throw(ArgumentError("FitARMA name may not be the fitted column"))
    return FitARMA{column,name}(NTuple{3,Int}(order), NTuple{4,Int}(seasonal_order),
        include_mean)
end

mutable struct FitARMAState{C,N} <: SummarizerState
    const spec::FitARMA{C,N}
    const y::Vector{Float64}
end

CausalFrames.emptyvalue(::FitARMA{C,N}) where {C,N} = NamedTuple{(N,)}((missing,))
function CausalFrames.fresh(s::FitARMA{C,N}, intypes::NamedTuple) where {C,N}
    T = nonmissingtype(intypes[C])
    T <: Real || throw(ArgumentError("FitARMA needs a numeric column; $C holds $T"))
    return FitARMAState{C,N}(s, Float64[])
end
CausalFrames.fresh(st::FitARMAState{C,N}) where {C,N} =
    FitARMAState{C,N}(st.spec, Float64[])
@inline function CausalFrames.fresh!(st::FitARMAState)
    empty!(st.y)
    return st
end

@inline function CausalFrames.update!(st::FitARMAState{C}, row) where {C}
    v = getproperty(row, C)
    push!(st.y, ismissing(v) ? NaN : Float64(v))
    return nothing
end

function CausalFrames.value(st::FitARMAState{C,N}) where {C,N}
    return NamedTuple{(N,),Tuple{Union{Missing,FittedARMA}}}((fitsarima(st.spec, st.y),))
end

# The fit behind a barrier returning a concrete FittedARMA whatever happens.
function fitsarima(s::FitARMA, y::Vector{Float64})
    nobs = count(!isnan, y)
    # StateSpaceModels "fits" a series with no observations to a finite likelihood.
    nobs == 0 && return failedarma(s, nobs, "the series has no non-missing observations")
    try
        model = SSM.SARIMA(copy(y); order = s.order, seasonal_order = s.seasonal_order,
            include_mean = s.include_mean)
        SSM.fit!(model; save_hyperparameter_distribution = false)
        isfinite(model.results.llk) ||
            return failedarma(s, nobs, "the likelihood did not converge to a finite value")
        return fittedarma(s, model, nobs)
    catch err
        err isa InterruptException && rethrow()
        return failedarma(s, nobs, sprint(showerror, err))
    end
end

# The number of ARMA states in StateSpaceModels' SARIMA representation, which
# follow the d + D·s differencing states.
armastates((p, _, q), (P, _, Q, s)) = max(p + s * P, q + s * Q + 1)

function fittedarma(s::FitARMA, model::SSM.SARIMA, nobs::Int)
    sys = model.system
    names = SSM.get_names(model)
    coefs = Float64[SSM.get_constrained_value(model, n) for n in names]
    res = model.results
    m = length(sys.Z)
    # StateSpaceModels' SARIMA initialization: diffuse differencing states, and
    # the stationary covariance of the ARMA block from the Lyapunov equation.
    P1 = Matrix{Float64}(1e6 * I, m, m)
    lo = m - armastates(s.order, s.seasonal_order) + 1
    Ra = sys.R[lo:m, 1]
    P1[lo:m, lo:m] .= sys.Q[1] .* lyapd(sys.T[lo:m, lo:m], Ra * Ra')
    return FittedARMA(model, s.order, s.seasonal_order, s.include_mean, names, coefs,
        res.llk, res.aic, res.aicc, res.bic, nobs, :ok, "", copy(sys.Z), copy(sys.T),
        sys.R * sys.Q * sys.R', copy(sys.c), sys.d, sys.H, zeros(m), P1)
end

failedarma(s::FitARMA, nobs::Int, message::String) =
    FittedARMA(nothing, s.order, s.seasonal_order, s.include_mean, String[], Float64[],
        NaN, NaN, NaN, NaN, nobs, :failed, message, Float64[], zeros(0, 0), zeros(0, 0),
        Float64[], NaN, NaN, Float64[], zeros(0, 0))

"""
    ARMAFilter(column::Symbol; model = :model, horizon = 0, name = column)

A summarizer applying the [`FittedARMA`](@ref)s in the `model` column to the
series `column`, one Kalman filter step per row. Its value, for `x = name`:

| Column | Meaning |
|---|---|
| `x_fitted` | `E[xₜ ∣ x₁…xₜ₋₁]`, the one-step prediction made before seeing `xₜ` |
| `x_residual` | `xₜ - x_fitted`, the innovation |
| `x_stdresidual` | the innovation over the square root of its variance |
| `x_forecast_1 … x_forecast_h` | `E[xₜ₊ₕ ∣ x₁…xₜ]` for `h ≤ horizon` |

all of element type `Union{Missing, Float64}` and all known at time `t`. When the
model cell changes identity the filter restarts from the new model's initial
state, as a fresh filter would; a `missing` or failed model emits `missing` and
keeps no state. A `missing` or `NaN` observation is predicted over without an
update and emits `missing` residuals. Use [`applyarma`](@ref) for the transform.

The filter is exact: unlike StateSpaceModels' own filter it takes no
steady-state shortcut, whose frozen covariance goes stale after a gap.
"""
struct ARMAFilter{C,M,N,H} <: Summarizer end

function ARMAFilter(column::Symbol; model::Symbol = :model, horizon::Integer = 0,
    name::Symbol = column)
    horizon >= 0 || throw(ArgumentError("ARMAFilter horizon must be >= 0, got $horizon"))
    model === column &&
        throw(ArgumentError("ARMAFilter model column may not be the filtered column"))
    names = (Symbol(name, :_fitted), Symbol(name, :_residual), Symbol(name, :_stdresidual),
        ntuple(h -> Symbol(name, :_forecast_, h), horizon)...)
    return ARMAFilter{column,model,names,Int(horizon)}()
end

CausalFrames.emptyvalue(::ARMAFilter{C,M,N,H}) where {C,M,N,H} =
    NamedTuple{N}(ntuple(_ -> missing, Val(H + 3)))

# The filter's state and its preallocated workspace, sized for the current
# model's state dimension and resized only when a model of another size arrives.
mutable struct ARMAFilterState{C,M,N,H} <: SummarizerState
    model::Union{Nothing,FittedARMA}
    a::Vector{Float64}       # predicted state for the next row
    P::Matrix{Float64}       # and its covariance
    att::Vector{Float64}     # filtered state
    Ptt::Matrix{Float64}
    PZ::Vector{Float64}
    K::Vector{Float64}       # Kalman gain
    IKZ::Matrix{Float64}     # I - K Z'
    scratch::Matrix{Float64}
    fa::Vector{Float64}      # forecast recursion
    fb::Vector{Float64}
    forecasts::Vector{Float64}
    fitted::Float64
    residual::Float64
    stdresidual::Float64
    observed::Bool
end

ARMAFilterState{C,M,N,H}() where {C,M,N,H} =
    ARMAFilterState{C,M,N,H}(nothing, Float64[], zeros(0, 0), Float64[], zeros(0, 0),
        Float64[], Float64[], zeros(0, 0), zeros(0, 0), Float64[], Float64[],
        zeros(H), NaN, NaN, NaN, false)

# The state when the input has no model column at all — an as-of join against a
# models stream with no rows passes the left chunks through without one.
struct NoModelState{N,H} <: SummarizerState end

function CausalFrames.fresh(::ARMAFilter{C,M,N,H}, intypes::NamedTuple) where {C,M,N,H}
    haskey(intypes, C) || throw(ArgumentError("ARMAFilter: no column $C in the input"))
    haskey(intypes, M) || return NoModelState{N,H}()
    return ARMAFilterState{C,M,N,H}()
end
CausalFrames.fresh(::ARMAFilterState{C,M,N,H}) where {C,M,N,H} = ARMAFilterState{C,M,N,H}()
CausalFrames.fresh(st::NoModelState) = st
@inline function CausalFrames.fresh!(st::ARMAFilterState)
    st.model = nothing
    return st
end

@inline CausalFrames.update!(::NoModelState, row) = nothing
@inline CausalFrames.value(::NoModelState{N,H}) where {N,H} =
    NamedTuple{N,NTuple{H + 3,Union{Missing,Float64}}}(ntuple(_ -> missing, Val(H + 3)))

@inline function CausalFrames.update!(st::ARMAFilterState{C,M}, row) where {C,M}
    armastep!(st, getproperty(row, M), getproperty(row, C))
    return nothing
end

function armastep!(st::ARMAFilterState, model, y)
    if !(model isa FittedARMA)
        ismissing(model) || throw(
            ArgumentError(
                "ARMAFilter: the model column holds a $(typeof(model)), not a FittedARMA",
            ),
        )
        st.model = nothing
        return nothing
    end
    if model.status !== :ok
        st.model = nothing
        return nothing
    end
    st.model === model || resetfilter!(st, model)
    kalmanstep!(st, model, y)
    return nothing
end

function resetfilter!(st::ARMAFilterState{C,M,N,H}, fm::FittedARMA) where {C,M,N,H}
    m = length(fm.Z)
    if length(st.a) != m
        st.a = Vector{Float64}(undef, m)
        st.att = Vector{Float64}(undef, m)
        st.PZ = Vector{Float64}(undef, m)
        st.K = Vector{Float64}(undef, m)
        st.fa = Vector{Float64}(undef, m)
        st.fb = Vector{Float64}(undef, m)
        st.P = Matrix{Float64}(undef, m, m)
        st.Ptt = Matrix{Float64}(undef, m, m)
        st.IKZ = Matrix{Float64}(undef, m, m)
        st.scratch = Matrix{Float64}(undef, m, m)
    end
    copyto!(st.a, fm.a1)
    copyto!(st.P, fm.P1)
    st.model = fm
    return st
end

# One step of the univariate Kalman filter over the fitted system, in the
# recursions StateSpaceModels uses (Joseph-form covariance update, symmetrized
# prediction), without allocating.
function kalmanstep!(st::ARMAFilterState, fm::FittedARMA, y)
    Z, T = fm.Z, fm.T
    a, P, att, Ptt, PZ, K = st.a, st.P, st.att, st.Ptt, st.PZ, st.K
    m = length(a)
    mul!(PZ, P, Z)
    F = dot(Z, PZ) + fm.H
    fitted = dot(Z, a) + fm.d
    st.fitted = fitted
    if ismissing(y) || isnan(y)
        copyto!(att, a)
        copyto!(Ptt, P)
        st.observed = false
    else
        v = Float64(y) - fitted
        @inbounds for i in 1:m
            K[i] = PZ[i] / F
            att[i] = a[i] + K[i] * v
        end
        IKZ = st.IKZ
        @inbounds for j in 1:m, i in 1:m
            IKZ[i, j] = (i == j) - K[i] * Z[j]
        end
        mul!(st.scratch, IKZ, P)
        mul!(Ptt, st.scratch, IKZ')
        H = fm.H
        if !iszero(H)
            @inbounds for j in 1:m, i in 1:m
                Ptt[i, j] += H * K[i] * K[j]
            end
        end
        st.residual = v
        st.stdresidual = v / sqrt(F)
        st.observed = true
    end
    mul!(a, T, att)
    a .+= fm.c
    mul!(st.scratch, T, Ptt)
    mul!(P, st.scratch, T')
    P .+= fm.RQR
    @inbounds for j in 1:m, i in (j+1):m
        s = (P[i, j] + P[j, i]) / 2
        P[i, j] = s
        P[j, i] = s
    end
    forecast!(st, fm)
    return nothing
end

# E[xₜ₊ₕ ∣ x₁…xₜ] = Z'·T^(h-1)·aₜ₊₁ + d, iterating the state prediction.
function forecast!(st::ARMAFilterState{C,M,N,H}, fm::FittedARMA) where {C,M,N,H}
    H == 0 && return nothing
    fa, fb = st.fa, st.fb
    copyto!(fa, st.a)
    for h in 1:H
        if h > 1
            mul!(fb, fm.T, fa)
            fb .+= fm.c
            fa, fb = fb, fa
        end
        @inbounds st.forecasts[h] = dot(fm.Z, fa) + fm.d
    end
    return nothing
end

@inline function CausalFrames.value(st::ARMAFilterState{C,M,N,H}) where {C,M,N,H}
    R = NamedTuple{N,NTuple{H + 3,Union{Missing,Float64}}}
    st.model === nothing && return R(ntuple(_ -> missing, Val(H + 3)))
    observed = st.observed
    return R((st.fitted, observed ? st.residual : missing,
        observed ? st.stdresidual : missing,
        ntuple(h -> @inbounds(st.forecasts[h]), Val(H))...))
end
