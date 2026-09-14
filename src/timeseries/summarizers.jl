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
