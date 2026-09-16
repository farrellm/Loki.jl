# Diagnostics: whole-window analyses of a node's loaded frame, computed outside
# the pipeline. Each is a plain function over a `CausalFrame` returning a
# `DiagnosticResult` — plot-ready arrays for the web app, and a compact numeric
# summary small enough for an agent's context window.
#
# Nothing here reads `frame.chunks`, which CausalFrames documents as private.
# The public route is `Tables.schema` (which never scans rows), `nrow`, and
# `Tables.partitions`, which walks the backing chunks one copy at a time.

"""
    Loki.DiagnosticResult

One diagnostic's output: its `kind`, `data` (plot-ready arrays), a compact
numeric `summary`, any `warnings`, and — for the residual panel — the `panels`
it is composed of. Every value is JSON-safe: a non-finite float is `nothing`,
which is JSON's `null`, because `JSON3.write` refuses `NaN` and `Inf`.
"""
struct DiagnosticResult
    kind::Symbol
    data::Dict{String,Any}
    summary::Dict{String,Any}
    warnings::Vector{String}
    panels::Dict{String,DiagnosticResult}
end

DiagnosticResult(kind::Symbol; data = Dict{String,Any}(), summary = Dict{String,Any}(),
    warnings = String[], panels = Dict{String,DiagnosticResult}()) =
    DiagnosticResult(Symbol(kind), Dict{String,Any}(data), Dict{String,Any}(summary),
        collect(String, warnings), Dict{String,DiagnosticResult}(panels))

JSON3.StructTypes.StructType(::Type{DiagnosticResult}) = JSON3.StructTypes.Struct()

function Base.show(io::IO, ::MIME"text/plain", r::DiagnosticResult)
    print(io, "DiagnosticResult(:", r.kind, ")")
    for k in sort!(collect(keys(r.summary)))
        v = r.summary[k]
        v isa Union{Real,AbstractString,Nothing,Bool} || continue
        print(io, "\n  ", k, " = ", v === nothing ? "nothing" : v)
    end
    for w in r.warnings
        print(io, "\n  ! ", w)
    end
    isempty(r.panels) ||
        print(io, "\n  panels: ", join(sort!(collect(keys(r.panels))), ", "))
    return nothing
end

# --- JSON safety ---------------------------------------------------------------
#
# `JSON3.write` refuses NaN and Inf, and a diagnostic produces both routinely:
# the ACF of a constant series, a failed fit's information criteria, a statistic
# over an empty window. They are turned into `nothing` here, at construction,
# rather than at write time, so a `DiagnosticResult` is always serializable.

jsonnumber(::Missing) = nothing
jsonnumber(::Nothing) = nothing
jsonnumber(x::Bool) = x
jsonnumber(x::Real) = isfinite(x) ? Float64(x) : nothing
jsonnumbers(xs) = Any[jsonnumber(x) for x in xs]

# An integer time stays an integer: a row's timestamp is an identity in the
# table preview, not a measurement, and 1.0 reads wrong where 1 was meant.
jsontime(t::Integer) = t
jsontime(t::Real) = jsonnumber(t)
jsontime(t::Union{Dates.Date,Dates.DateTime,Dates.Time}) = string(t)
jsontime(t) = string(t)
jsontimes(ts) = Any[jsontime(t) for t in ts]

# A table cell for the preview: numbers as numbers, times and everything else —
# a fitted model among them — as the text `show` gives it.
jsoncell(::Missing) = nothing
jsoncell(::Nothing) = nothing
jsoncell(x::Bool) = x
jsoncell(x::Integer) = x
jsoncell(x::Real) = jsonnumber(x)
jsoncell(x::AbstractString) = String(x)
jsoncell(x::Symbol) = String(x)
jsoncell(x::Union{Dates.Date,Dates.DateTime,Dates.Time}) = string(x)
jsoncell(x) = sprint(show, x; context = :compact => true)

# Time as a number, for arithmetic the time type does not support directly.
timenumber(t::Real) = Float64(t)
timenumber(t::Union{Dates.Date,Dates.DateTime,Dates.Time}) = Float64(Dates.value(t))

# --- extraction ----------------------------------------------------------------

function schemaindex(sch::Tables.Schema, name::Symbol)
    i = findfirst(==(name), sch.names)
    i === nothing && throw(ArgumentError("the frame has no column \
        $(repr(String(name))); it has $(join(repr.(String.(sch.names)), ", "))"))
    return i
end

columntype(sch::Tables.Schema, name::Symbol) = sch.types[schemaindex(sch, name)]

# A key selector: `nothing`, one `:col => value`, or several of them.
keypairs(::Nothing) = Pair{Symbol,Any}[]
keypairs(p::Pair) = Pair{Symbol,Any}[Symbol(first(p))=>last(p)]
keypairs(ps) = Pair{Symbol,Any}[Symbol(first(p))=>last(p) for p in ps]

# Values arriving from a query string are strings whatever the column holds, so
# a textual match on the shown value is accepted alongside the real one.
keymatches(cell, value) = isequal(cell, value) || string(cell) == string(value)

function keymask(part, ks::Vector{Pair{Symbol,Any}})
    isempty(ks) && return nothing
    mask = trues(nrow(part))
    for (col, value) in ks
        c = Tables.getcolumn(part, col)
        @inbounds for i in eachindex(mask)
            mask[i] &= keymatches(c[i], value)
        end
    end
    return mask
end

"""
    Loki.columnvectors(frame::CausalFrame, names::Symbol...; key = nothing)
        -> NamedTuple

The named columns of `frame` as vectors, typed from its `Tables.schema` and
restricted to the rows matching `key` (`nothing`, `:sym => "AAPL"`, or several
such pairs). The frame is walked one backing chunk at a time through
`Tables.partitions`, so peak memory is a chunk rather than the whole frame.
"""
function columnvectors(frame::CausalFrame, names::Symbol...; key = nothing)
    sch = Tables.schema(frame)
    ks = keypairs(key)
    for (col, _) in ks
        schemaindex(sch, col)
    end
    # A NamedTuple is keyed by name, so asking for one twice — `seriesplot` over
    # `:time` and `:x`, where `:x` is `:time` — is one column, not a duplicate field.
    wanted = Tuple(unique(names))
    out = Any[Vector{columntype(sch, n)}() for n in wanted]
    rows = nrow(frame)
    for v in out
        sizehint!(v, rows)
    end
    for part in Tables.partitions(frame)
        nrow(part) == 0 && continue
        mask = keymask(part, ks)
        for (j, name) in enumerate(wanted)
            col = Tables.getcolumn(part, name)
            mask === nothing ? append!(out[j], col) : append!(out[j], view(col, mask))
        end
    end
    return NamedTuple{wanted}(Tuple(out))
end

# A numeric column and its times, with the `missing` and non-finite rows dropped
# and counted. A column that is not numeric at all is an error naming it, rather
# than a silent empty result.
function numericvalues(frame::CausalFrame, column::Symbol; key = nothing)
    T = columntype(Tables.schema(frame), column)
    Base.nonmissingtype(T) <: Real || throw(ArgumentError("column \
        $(repr(String(column))) holds $T, which is not numeric"))
    cols = columnvectors(frame, :time, column; key)
    raw = getproperty(cols, column)
    times = cols.time
    values = Vector{Float64}()
    kept = similar(times, 0)
    sizehint!(values, length(raw))
    dropped = 0
    @inbounds for i in eachindex(raw)
        v = raw[i]
        if v === missing || !isfinite(v)
            dropped += 1
        else
            push!(values, Float64(v))
            push!(kept, times[i])
        end
    end
    return (; values, times = kept, dropped)
end

"""
    Loki.keyvalues(frame::CausalFrame, columns; limit = 1000) -> Vector{NamedTuple}

The distinct values of the key `columns` in `frame`, in first-seen order — what
a diagnostic's key selector offers. Stops at `limit` distinct values.
"""
function keyvalues(frame::CausalFrame, columns; limit::Integer = 1000)
    cols = Symbol[Symbol(c) for c in (columns isa Union{Symbol,AbstractString} ?
                                      (columns,) : columns)]
    isempty(cols) && return NamedTuple[]
    vectors = columnvectors(frame, cols...)
    seen = Set{Any}()
    out = NamedTuple[]
    for i in 1:length(getproperty(vectors, first(cols)))
        row = NamedTuple{Tuple(cols)}(Tuple(getproperty(vectors, c)[i] for c in cols))
        row in seen && continue
        push!(seen, row)
        push!(out, row)
        length(out) >= limit && break
    end
    return out
end

# --- spacing -------------------------------------------------------------------

function modalstep(steps)
    counts = Dict{Any,Int}()
    for s in steps
        counts[s] = get(counts, s, 0) + 1
    end
    best, bestcount = first(steps), 0
    for (s, c) in counts
        c > bestcount && ((best, bestcount) = (s, c))
    end
    return best
end

stepequal(a::Real, b::Real) = isapprox(a, b; rtol = 1e-9)
stepequal(a, b) = a == b

# Whether `:time` is evenly spaced, and by how much. ACF, PACF and Ljung-Box all
# assume it is, and say so when it is not.
function spacing(times::AbstractVector)
    length(times) < 3 && return (; regular = true, delta = nothing)
    steps = diff(times)
    modal = modalstep(steps)
    return (; regular = all(s -> stepequal(s, modal), steps), delta = modal)
end

spelldelta(::Nothing) = "Δ"
spelldelta(d::Real) = string(d)
function spelldelta(d::Dates.Period)
    periods = Dates.canonicalize(Dates.CompoundPeriod(d)).periods
    length(periods) == 1 || return string(d)
    return string(nameof(typeof(only(periods))), "(", only(periods).value, ")")
end

# The warning the diagnostics that assume regular spacing carry, with the resample
# that would fix it spelled in the frame's own time units.
function spacingwarnings!(warnings::Vector{String}, summary::Dict{String,Any},
    times::AbstractVector, column::Symbol)
    s = spacing(times)
    s.regular && return warnings
    fix = "intervalize(clock($(spelldelta(s.delta))), Last($(repr(column))))"
    push!(warnings, "time is not evenly spaced, and this diagnostic assumes it is; \
        resample first with $fix")
    summary["suggestion"] = fix
    return warnings
end

# --- downsampling --------------------------------------------------------------

"""
    Loki.lttb(x, y, threshold) -> Vector{Int}

The indices Largest-Triangle-Three-Buckets keeps when downsampling the series
`(x, y)` to about `threshold` points — indices rather than values, so the caller
keeps its own exact times. The first and last points are always kept, and a
series already at or under `threshold` is returned whole.
"""
function lttb(x::AbstractVector{<:Real}, y::AbstractVector{<:Real}, threshold::Integer)
    n = length(y)
    length(x) == n || throw(ArgumentError("lttb needs x and y of equal length"))
    (threshold >= n || threshold < 3) && return collect(1:n)
    out = Vector{Int}(undef, threshold)
    out[1] = 1
    every = (n - 2) / (threshold - 2)
    a = 1
    for i in 0:(threshold-3)
        avgstart = floor(Int, (i + 1) * every) + 2
        avgstop = min(floor(Int, (i + 2) * every) + 1, n)
        avgx, avgy = if avgstop < avgstart
            (Float64(x[n]), Float64(y[n]))
        else
            sx = sy = 0.0
            @inbounds for j in avgstart:avgstop
                sx += x[j]
                sy += y[j]
            end
            m = avgstop - avgstart + 1
            (sx / m, sy / m)
        end
        rangestart = floor(Int, i * every) + 2
        rangestop = min(floor(Int, (i + 1) * every) + 1, n)
        pax, pay = Float64(x[a]), Float64(y[a])
        best, bestarea = rangestart, -1.0
        @inbounds for j in rangestart:rangestop
            area = abs((pax - avgx) * (y[j] - pay) - (pax - x[j]) * (avgy - pay))
            area > bestarea && ((bestarea, best) = (area, j))
        end
        out[i+2] = best
        a = best
    end
    out[threshold] = n
    return out
end

# --- summary statistics --------------------------------------------------------

function moments(v::AbstractVector{Float64})
    n = length(v)
    n == 0 && return (; n = 0, mean = NaN, std = NaN, min = NaN, max = NaN)
    m = sum(v) / n
    s = n < 2 ? NaN : sqrt(sum(x -> abs2(x - m), v) / (n - 1))
    return (; n, mean = m, std = s, min = minimum(v), max = maximum(v))
end

function seriessummary(values::AbstractVector{Float64}, dropped::Integer)
    m = moments(values)
    return Dict{String,Any}("n" => m.n, "missing" => Int(dropped),
        "mean" => jsonnumber(m.mean), "std" => jsonnumber(m.std),
        "min" => jsonnumber(m.min), "max" => jsonnumber(m.max),
        "first" => isempty(values) ? nothing : jsonnumber(first(values)),
        "last" => isempty(values) ? nothing : jsonnumber(last(values)))
end

# What every diagnostic reports about where it was computed.
function basesummary(frame::CausalFrame, column, key)
    ctx = context(frame)
    return Dict{String,Any}("column" => column === nothing ? nothing : String(column),
        "rows" => nrow(frame),
        "key" => isempty(keypairs(key)) ? nothing :
                 Dict(String(k) => jsoncell(v) for (k, v) in keypairs(key)),
        "context" => Any[jsontime(ctx.start), jsontime(ctx.stop)])
end

# --- the series diagnostics ----------------------------------------------------

"""
    Loki.seriesplot(frame::CausalFrame, columns...; key = nothing, maxpoints = 2000)
        -> Loki.DiagnosticResult

One trace per column over `:time`. A series of at most `maxpoints` rows is sent
whole, with `missing` as `null` so the plot breaks where the data does; a longer
one is downsampled with [`Loki.lttb`](@ref) over its finite points, which keeps
the shape of a million-row series in a payload a phone can fetch.
"""
function seriesplot(frame::CausalFrame, columns::Union{Symbol,AbstractString}...;
    key = nothing, maxpoints::Integer = 2000)
    cols = Symbol[Symbol(c) for c in columns]
    isempty(cols) && throw(ArgumentError("seriesplot needs at least one column"))
    series = Any[]
    persummary = Dict{String,Any}()
    for column in cols
        trace, s = onetrace(frame, column; key, maxpoints)
        push!(series, trace)
        persummary[String(column)] = s
    end
    return DiagnosticResult(:seriesplot;
        data = Dict{String,Any}("series" => series, "rows" => nrow(frame),
            "maxpoints" => Int(maxpoints)),
        summary = merge(basesummary(frame, length(cols) == 1 ? only(cols) : nothing, key),
            Dict{String,Any}("series" => persummary)))
end

function onetrace(frame::CausalFrame, column::Symbol; key, maxpoints::Integer)
    T = columntype(Tables.schema(frame), column)
    if !(Base.nonmissingtype(T) <: Real)
        # A non-numeric column has no line to draw; say so rather than raise, so
        # one bad column does not lose the panel.
        return (Dict{String,Any}("name" => String(column), "time" => Any[],
                "values" => Any[], "downsampled" => false,
                "note" => "column holds $T, which is not numeric"),
            Dict{String,Any}("n" => 0, "missing" => nrow(frame)))
    end
    cols = columnvectors(frame, :time, column; key)
    raw = getproperty(cols, column)
    times = cols.time
    if length(raw) <= maxpoints
        finite = Float64[Float64(v) for v in raw if !(v === missing) && isfinite(v)]
        return (Dict{String,Any}("name" => String(column), "time" => jsontimes(times),
                "values" => jsonnumbers(raw), "downsampled" => false),
            seriessummary(finite, length(raw) - length(finite)))
    end
    v = numericvalues(frame, column; key)
    idx = lttb(map(timenumber, v.times), v.values, maxpoints)
    return (Dict{String,Any}("name" => String(column),
            "time" => jsontimes(view(v.times, idx)),
            "values" => jsonnumbers(view(v.values, idx)), "downsampled" => true),
        seriessummary(v.values, v.dropped))
end

"""
    Loki.preview(frame::CausalFrame; offset = 0, limit = 100, columns = nothing,
                 key = nothing) -> Loki.DiagnosticResult

A page of the frame's rows, with its column names and element types — what the
table panel shows and what `GET /api/results/:id/:port` returns. Cells that are
not numbers or times arrive as the text `show` gives them, so a column of fitted
models previews as readably as a column of floats.
"""
function preview(frame::CausalFrame; offset::Integer = 0, limit::Integer = 100,
    columns = nothing, key = nothing)
    offset >= 0 || throw(ArgumentError("preview offset must not be negative"))
    limit >= 0 || throw(ArgumentError("preview limit must not be negative"))
    sch = Tables.schema(frame)
    wanted = columns === nothing ? collect(Symbol, sch.names) :
             Symbol[Symbol(c) for c in
                    (columns isa Union{Symbol,AbstractString} ? (columns,) : columns)]
    for c in wanted
        schemaindex(sch, c)
    end
    ks = keypairs(key)
    rows = Vector{Any}[]
    total = 0
    for part in Tables.partitions(frame)
        nrow(part) == 0 && continue
        mask = keymask(part, ks)
        indices = mask === nothing ? (1:nrow(part)) : findall(mask)
        for i in indices
            total += 1
            (total <= offset || length(rows) >= limit) && continue
            push!(rows,
                Any[jsoncell(Tables.getcolumn(part, c)[i]) for c in wanted])
        end
    end
    return DiagnosticResult(:preview;
        data = Dict{String,Any}("columns" => String.(wanted),
            "types" => [string(columntype(sch, c)) for c in wanted],
            "rows" => rows, "offset" => Int(offset), "limit" => Int(limit),
            "total" => total),
        summary = merge(basesummary(frame, nothing, key),
            Dict{String,Any}("matched" => total, "returned" => length(rows))))
end
