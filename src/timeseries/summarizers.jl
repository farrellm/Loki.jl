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
