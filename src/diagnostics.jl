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

# A warning written across several source lines carries the indentation with it —
# Julia's line continuation drops the newline and keeps the spaces — and these
# are shown in a panel, so the runs are collapsed on the way in.
pushwarning!(warnings::Vector{String}, message::AbstractString) =
    push!(warnings, replace(strip(message), r"\s+" => " "))

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
    cols = Symbol[
        Symbol(c) for c in (columns isa Union{Symbol,AbstractString} ?
              (columns,) : columns)
    ]
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
    pushwarning!(
        warnings,
        "time is not evenly spaced, and this diagnostic assumes it is; \
        resample first with $fix",
    )
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
        "key" =>
            isempty(keypairs(key)) ? nothing :
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
        return (
            Dict{String,Any}("name" => String(column), "time" => Any[],
                "values" => Any[], "downsampled" => false,
                "note" => "column holds $T, which is not numeric"),
            Dict{String,Any}("n" => 0, "missing" => nrow(frame)))
    end
    cols = columnvectors(frame, :time, column; key)
    raw = getproperty(cols, column)
    times = cols.time
    if length(raw) <= maxpoints
        finite = Float64[Float64(v) for v in raw if !(v === missing) && isfinite(v)]
        return (
            Dict{String,Any}("name" => String(column), "time" => jsontimes(times),
                "values" => jsonnumbers(raw), "downsampled" => false),
            seriessummary(finite, length(raw) - length(finite)))
    end
    v = numericvalues(frame, column; key)
    idx = lttb(map(timenumber, v.times), v.values, maxpoints)
    return (
        Dict{String,Any}("name" => String(column),
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
    wanted =
        columns === nothing ? collect(Symbol, sch.names) :
        Symbol[
            Symbol(c) for c in
            (columns isa Union{Symbol,AbstractString} ? (columns,) : columns)
        ]
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

# --- correlation ---------------------------------------------------------------
#
# ACF, PACF and Ljung-Box all assume evenly spaced observations, so each carries
# the spacing warning. They also each have a length past which StatsBase or
# HypothesisTests raises rather than returns; Loki clamps to that length and says
# so, because a short window is exactly what a user pokes at first and a panel
# that 500s is worse than one that says "40 lags asked, 12 available".

# `z` for a two-sided interval at `level`: 1.96 at the conventional 0.95.
function zscore(level::Real)
    0 < level < 1 ||
        throw(ArgumentError("level must be between 0 and 1, got $level"))
    return StatsFuns.norminvcdf((1 + level) / 2)
end

# StatsBase's `autocor` needs `maxlag < n`; its `pacf` needs `2 * maxlag < n`.
maxacflag(n::Integer) = max(n - 1, 0)
maxpacflag(n::Integer) = max((n - 1) ÷ 2, 0)

function chooselags(requested, available::Integer, warnings::Vector{String}, what::String)
    wanted = requested === nothing ? 40 : Int(requested)
    wanted >= 1 || throw(ArgumentError("$what needs at least one lag, got $wanted"))
    wanted <= available && return wanted, false
    pushwarning!(
        warnings,
        "$what was asked for $wanted lags but this window supports \
        $available; showing $available",
    )
    return available, true
end

function correlogram(kind::Symbol, frame::CausalFrame, column::Symbol, lags, key,
    level::Real, compute)
    col = Symbol(column)
    warnings = String[]
    summary = basesummary(frame, col, key)
    v = numericvalues(frame, col; key)
    summary["n"] = length(v.values)
    summary["missing"] = v.dropped
    spacingwarnings!(warnings, summary, v.times, col)
    n = length(v.values)
    available = kind === :acf ? maxacflag(n) : maxpacflag(n)
    if available < 1
        pushwarning!(warnings, "too few rows for $(kind): $n")
        return DiagnosticResult(kind;
            data = Dict{String,Any}("lags" => Int[], "values" => Any[],
                "band" => nothing, "level" => Float64(level)),
            summary, warnings)
    end
    k, clamped = chooselags(lags, available, warnings, String(kind))
    values = try
        compute(v.values, k)
    catch err
        err isa InterruptException && rethrow()
        # A singular window — a constant series, a perfectly periodic one — is a
        # property of the data, not a bug. Report it where the user can see it.
        pushwarning!(
            warnings,
            "$(kind) could not be computed for this window: \
            $(sprint(showerror, err))",
        )
        fill(NaN, kind === :acf ? k + 1 : k)
    end
    lagindex = kind === :acf ? collect(0:k) : collect(1:k)
    band = zscore(level) / sqrt(n)
    significant = [
        lagindex[i] for i in eachindex(values)
        if lagindex[i] != 0 && isfinite(values[i]) && abs(values[i]) > band
    ]
    summary["lags"] = k
    summary["clamped"] = clamped
    summary["band"] = jsonnumber(band)
    summary["values"] = jsonnumbers(values)
    summary["significant"] = significant
    return DiagnosticResult(kind;
        data = Dict{String,Any}("lags" => lagindex, "values" => jsonnumbers(values),
            "band" => jsonnumber(band), "level" => Float64(level)),
        summary, warnings)
end

"""
    acf(frame::CausalFrame, column; lags = 40, key = nothing, demean = true,
        level = 0.95) -> Loki.DiagnosticResult

The autocorrelation function of a column over the whole window, with the
±z/√n significance band at `level`. `missing` rows are dropped and counted, and
the summary lists the lags outside the band — the ones a Box–Jenkins reading
starts from.

More lags than the window supports are clamped with a warning rather than
raised, and so is a window whose autocorrelation is not computable at all.
"""
acf(frame::CausalFrame, column::Union{Symbol,AbstractString}; lags = nothing,
    key = nothing, demean::Bool = true, level::Real = 0.95) =
    correlogram(:acf, frame, Symbol(column), lags, key, level,
        (v, k) -> StatsBase.autocor(v, 0:k; demean))

"""
    pacf(frame::CausalFrame, column; lags = 40, key = nothing,
         method = :regression, level = 0.95) -> Loki.DiagnosticResult

The partial autocorrelation function, as [`acf`](@ref) but from lag 1 and
through StatsBase's `pacf`. The window supports half as many lags as `acf`
does — `2 · lags < n` — and asking for more clamps with a warning.
"""
pacf(frame::CausalFrame, column::Union{Symbol,AbstractString}; lags = nothing,
    key = nothing, method::Symbol = :regression, level::Real = 0.95) =
    correlogram(:pacf, frame, Symbol(column), lags, key, level,
        (v, k) -> StatsBase.pacf(v, 1:k; method))

# --- the degrees of freedom a residual test needs ------------------------------

"""
    Loki.armadof(frame::CausalFrame; column = nothing) -> Union{Nothing,Int}

The degrees of freedom a Ljung–Box test on this frame's residuals should give
up — `p + q + P + Q` — read from a [`FittedARMA`](@ref) column, or `nothing`
when the frame has none.

A frame usually has none: [`applyarma`](@ref) drops the model column, so an
in-sample residual stream carries no model. The fit node's own parameters are
the other route, and the server's diagnostics endpoint takes it.
"""
function armadof(frame::CausalFrame; column = nothing)
    sch = Tables.schema(frame)
    name = if column === nothing
        i = findfirst(T -> Base.nonmissingtype(T) <: FittedARMA, collect(sch.types))
        i === nothing && return nothing
        sch.names[i]
    else
        Symbol(column)
    end
    Base.nonmissingtype(columntype(sch, name)) <: FittedARMA || return nothing
    models = getproperty(columnvectors(frame, name), name)
    i = findlast(m -> m isa FittedARMA, models)
    i === nothing && return nothing
    fm = models[i]
    p, _, q = fm.order
    P, _, Q, _ = fm.seasonal_order
    return p + q + P + Q
end

"""
    ljungbox(frame::CausalFrame, column; lags = [10, 20, 40], dof = nothing,
             key = nothing, modelcolumn = nothing) -> Loki.DiagnosticResult

The Ljung–Box test for autocorrelation, at one lag count or several. On a
residual column the model's own parameters must be given up as degrees of
freedom: `dof` if given, else `p + q + P + Q` from a [`FittedARMA`](@ref) column
in the frame (see [`Loki.armadof`](@ref)), else `0` with a warning — the summary
says which, as `dofsource`.

A lag count the window cannot support, or one not above `dof`, is dropped with a
warning rather than raised.
"""
function ljungbox(frame::CausalFrame, column::Union{Symbol,AbstractString};
    lags = nothing, dof = nothing, key = nothing, modelcolumn = nothing)
    col = Symbol(column)
    warnings = String[]
    summary = basesummary(frame, col, key)
    v = numericvalues(frame, col; key)
    n = length(v.values)
    summary["n"] = n
    summary["missing"] = v.dropped
    spacingwarnings!(warnings, summary, v.times, col)

    d, source = if dof !== nothing
        Int(dof), "given"
    else
        found = armadof(frame; column = modelcolumn)
        found === nothing ? (0, "none") : (found, "model")
    end
    source == "none" && pushwarning!(
        warnings,
        "no model column in this frame, so the test \
        gives up no degrees of freedom; pass dof if these are residuals",
    )
    summary["dof"] = d
    summary["dofsource"] = source

    wanted =
        lags === nothing ? [10, 20, 40] :
        lags isa Integer ? [Int(lags)] : Int[Int(l) for l in lags]
    tests = Any[]
    pvalues = Dict{String,Any}()
    for k in wanted
        if k <= d
            pushwarning!(
                warnings,
                "skipping $k lags: the test needs more lags than the $d \
                degrees of freedom it gives up",
            )
            continue
        elseif k >= n
            pushwarning!(warnings, "skipping $k lags: the window has $n rows")
            continue
        end
        t = try
            HT.LjungBoxTest(v.values, k, d)
        catch err
            err isa InterruptException && rethrow()
            pushwarning!(warnings, "skipping $k lags: $(sprint(showerror, err))")
            continue
        end
        p = HT.pvalue(t)
        push!(tests,
            Dict{String,Any}("lags" => k, "dof" => d, "statistic" => jsonnumber(t.Q),
                "pvalue" => jsonnumber(p)))
        pvalues[string(k)] = jsonnumber(p)
    end
    summary["pvalues"] = pvalues
    # White noise until some lag count says otherwise; no test at all is no verdict.
    summary["whitenoise"] =
        isempty(tests) ? nothing : all(t -> something(t["pvalue"], 1.0) > 0.05, tests)
    return DiagnosticResult(:ljungbox;
        data = Dict{String,Any}("tests" => tests), summary, warnings)
end

"""
    adftest(frame::CausalFrame, column; key = nothing, deterministic = :constant,
            lag = nothing) -> Loki.DiagnosticResult

The augmented Dickey–Fuller test for a unit root: a small p-value is evidence
*against* one, so `stationary` in the summary is `pvalue < 0.05`. `lag` defaults
to Schwert's rule, `⌊12 (n/100)^¼⌋`, clamped to what the window supports.
"""
function adftest(frame::CausalFrame, column::Union{Symbol,AbstractString};
    key = nothing, deterministic::Symbol = :constant, lag = nothing)
    col = Symbol(column)
    warnings = String[]
    summary = basesummary(frame, col, key)
    v = numericvalues(frame, col; key)
    n = length(v.values)
    summary["n"] = n
    summary["missing"] = v.dropped
    summary["deterministic"] = String(deterministic)
    schwert = floor(Int, 12 * (n / 100)^0.25)
    k = lag === nothing ? schwert : Int(lag)
    k = clamp(k, 0, max((n - 4) ÷ 3, 0))
    result =
        n < 8 ? nothing :
        try
            HT.ADFTest(v.values, deterministic, k)
        catch err
            err isa InterruptException && rethrow()
            pushwarning!(
                warnings,
                "the ADF test could not be computed: $(sprint(showerror, err))",
            )
            nothing
        end
    n < 8 && pushwarning!(warnings, "too few rows for an ADF test: $n")
    if result === nothing
        summary["lag"] = k
        summary["statistic"] = nothing
        summary["pvalue"] = nothing
        summary["stationary"] = nothing
        return DiagnosticResult(:adftest; data = copy(summary), summary, warnings)
    end
    p = HT.pvalue(result)
    summary["lag"] = result.lag
    summary["statistic"] = jsonnumber(result.stat)
    summary["pvalue"] = jsonnumber(p)
    summary["stationary"] = isfinite(p) ? p < 0.05 : nothing
    summary["criticalvalues"] =
        Dict{String,Any}(zip(("1%", "5%", "10%"), jsonnumbers(result.cv)))
    return DiagnosticResult(:adftest; data = copy(summary), summary, warnings)
end

# --- distribution --------------------------------------------------------------

# Freedman–Diaconis: bin width 2·IQR·n^(-1/3), which is robust to the outliers a
# residual distribution has. A zero IQR (a near-constant series) falls back to
# Sturges' rule, which depends only on the count.
function fdbins(v::AbstractVector{Float64})
    n = length(v)
    n < 2 && return 1
    lo, hi = extrema(v)
    hi > lo || return 1
    iqr = Statistics.quantile(v, 0.75) - Statistics.quantile(v, 0.25)
    width = 2 * iqr * n^(-1 / 3)
    width > 0 || return max(ceil(Int, log2(n)) + 1, 1)
    return clamp(ceil(Int, (hi - lo) / width), 1, 200)
end

"""
    Loki.histogram(frame::CausalFrame, column; key = nothing, bins = nothing)
        -> Loki.DiagnosticResult

The distribution of a column, against the normal fitted to it. `bins` defaults
to the Freedman–Diaconis rule. The summary carries the first four moments, which
is what a residual panel reports beside the plot.
"""
function histogram(frame::CausalFrame, column::Union{Symbol,AbstractString};
    key = nothing, bins = nothing)
    col = Symbol(column)
    warnings = String[]
    summary = basesummary(frame, col, key)
    v = numericvalues(frame, col; key)
    values = v.values
    n = length(values)
    merge!(summary, seriessummary(values, v.dropped))
    summary["skewness"] = n > 2 ? jsonnumber(StatsBase.skewness(values)) : nothing
    summary["kurtosis"] = n > 3 ? jsonnumber(StatsBase.kurtosis(values)) : nothing
    summary["median"] = n > 0 ? jsonnumber(Statistics.median(values)) : nothing
    if n == 0
        pushwarning!(
            warnings,
            "nothing to plot: every row of $(repr(String(col))) is missing",
        )
        return DiagnosticResult(:histogram;
            data = Dict{String,Any}("edges" => Any[], "counts" => Int[],
                "density" => Any[], "normal" => nothing), summary, warnings)
    end
    lo, hi = extrema(values)
    hi > lo || (hi = lo + 1.0)
    k = bins === nothing ? fdbins(values) : max(Int(bins), 1)
    width = (hi - lo) / k
    edges = [lo + i * width for i in 0:k]
    counts = zeros(Int, k)
    for x in values
        counts[clamp(floor(Int, (x - lo) / width) + 1, 1, k)] += 1
    end
    m = moments(values)
    sd = isfinite(m.std) && m.std > 0 ? m.std : nothing
    normal = if sd === nothing
        nothing
    else
        xs = [lo + (hi - lo) * i / 100 for i in 0:100]
        Dict{String,Any}("mean" => jsonnumber(m.mean), "std" => jsonnumber(sd),
            "x" => jsonnumbers(xs),
            "pdf" => jsonnumbers(StatsFuns.normpdf.(m.mean, sd, xs)))
    end
    return DiagnosticResult(:histogram;
        data = Dict{String,Any}("edges" => jsonnumbers(edges), "counts" => counts,
            "density" => jsonnumbers(counts ./ (n * width)), "normal" => normal),
        summary, warnings)
end

"""
    Loki.qqplot(frame::CausalFrame, column; key = nothing, maxpoints = 2000)
        -> Loki.DiagnosticResult

A normal quantile–quantile plot: the sorted values against `Φ⁻¹((i - ½)/n)`, with
the line through the fitted normal. `correlation` in the summary is how straight
the plot is — near 1 is normal — and a long series is thinned to `maxpoints`
evenly spaced quantiles.
"""
function qqplot(frame::CausalFrame, column::Union{Symbol,AbstractString};
    key = nothing, maxpoints::Integer = 2000)
    col = Symbol(column)
    warnings = String[]
    summary = basesummary(frame, col, key)
    v = numericvalues(frame, col; key)
    sample = sort(v.values)
    n = length(sample)
    m = moments(sample)
    summary["n"] = n
    summary["missing"] = v.dropped
    summary["mean"] = jsonnumber(m.mean)
    summary["std"] = jsonnumber(m.std)
    if n < 2
        pushwarning!(warnings, "too few rows for a QQ plot: $n")
        summary["correlation"] = nothing
        return DiagnosticResult(:qqplot;
            data = Dict{String,Any}("theoretical" => Any[], "sample" => Any[],
                "line" => nothing), summary, warnings)
    end
    theoretical = [StatsFuns.norminvcdf((i - 0.5) / n) for i in 1:n]
    idx = n <= maxpoints ? (1:n) :
          unique(round.(Int, range(1, n; length = maxpoints)))
    summary["correlation"] = jsonnumber(Statistics.cor(theoretical, sample))
    sd = isfinite(m.std) && m.std > 0 ? m.std : 1.0
    return DiagnosticResult(:qqplot;
        data = Dict{String,Any}("theoretical" => jsonnumbers(view(theoretical, idx)),
            "sample" => jsonnumbers(view(sample, idx)),
            "line" => Dict{String,Any}("intercept" => jsonnumber(m.mean),
                "slope" => jsonnumber(sd))), summary, warnings)
end

# --- fitted models -------------------------------------------------------------

"""
    fitreport(frame::CausalFrame; column = :model, key = nothing)
        -> Loki.DiagnosticResult

What a fit came out as: a [`FittedARMA`](@ref)'s specification, fitted
hyperparameters by name, information criteria, observation count and status —
and, for a failed fit, the message rather than an exception.

A model column holding something else (an MLJ model, whose report is the
`modelreports` operator's job) is reported as the text it shows as, with a
warning.
"""
function fitreport(frame::CausalFrame; column = :model, key = nothing)
    col = Symbol(column)
    warnings = String[]
    summary = basesummary(frame, col, key)
    fitted = if col in Tables.schema(frame).names
        [m for m in getproperty(columnvectors(frame, col; key), col) if m !== missing]
    else
        pushwarning!(
            warnings,
            "this frame has no column $(repr(String(col))); a fit node's             model port is where the models are",
        )
        Any[]
    end
    summary["models"] = length(fitted)
    if isempty(fitted)
        isempty(warnings) &&
            pushwarning!(warnings, "no model in column $(repr(String(col)))")
        return DiagnosticResult(:fitreport; data = copy(summary), summary, warnings)
    end
    fm = last(fitted)
    if !(fm isa FittedARMA)
        pushwarning!(
            warnings,
            "column $(repr(String(col))) holds a $(typeof(fm)), not a \
            FittedARMA; an MLJ model's report comes from the modelreports operator",
        )
        summary["status"] = "unknown"
        summary["model"] = jsoncell(fm)
        return DiagnosticResult(:fitreport; data = copy(summary), summary, warnings)
    end
    fm.status === :ok ||
        pushwarning!(warnings, "the fit failed: $(fm.message)")
    summary["status"] = String(fm.status)
    summary["message"] = fm.message
    summary["order"] = collect(fm.order)
    summary["seasonal_order"] = collect(fm.seasonal_order)
    summary["include_mean"] = fm.include_mean
    summary["coefficients"] =
        Dict{String,Any}(zip(fm.names, jsonnumbers(fm.coefs)))
    summary["loglik"] = jsonnumber(fm.loglik)
    summary["aic"] = jsonnumber(fm.aic)
    summary["aicc"] = jsonnumber(fm.aicc)
    summary["bic"] = jsonnumber(fm.bic)
    summary["nobs"] = fm.nobs
    return DiagnosticResult(:fitreport; data = copy(summary), summary, warnings)
end

# The fitted models in a column, or none when the frame has no such column —
# which is the usual case on an in-sample stream, since `applyarma` drops it.
function fittedmodels(frame::CausalFrame, column::Symbol, key)
    column in Tables.schema(frame).names || return FittedARMA[]
    return FittedARMA[
        m for m in getproperty(columnvectors(frame, column; key), column)
        if m isa FittedARMA
    ]
end

# A `SARIMA` over `ys` carrying `fm`'s fitted hyperparameters. StateSpaceModels
# refuses to filter an unfitted model and cannot fit one with every
# hyperparameter fixed, so the fitted values are copied across — which is what
# its own `forecast` does.
function refitted(fm::FittedARMA, ys::Vector{Float64})
    m = SSM.SARIMA(copy(ys); order = fm.order, seasonal_order = fm.seasonal_order,
        include_mean = fm.include_mean)
    m.hyperparameters = deepcopy(fm.model.hyperparameters)
    return m
end

# The steady-state shortcut freezes the covariance once it looks settled, which
# leaves the innovation variance stale after a gap. `ARMAFilter` takes no such
# shortcut, so neither does the forecast that has to agree with it.
nonsteady(fm::FittedARMA) =
    SSM.UnivariateKalmanFilter(copy(fm.a1), copy(fm.P1), 0, -1.0)

# The `h` times after the last one, spaced as the series is.
function futuretimes(times::AbstractVector, h::Integer)
    (isempty(times) || h < 1) && return similar(times, 0)
    step = spacing(times).delta
    step === nothing && return similar(times, 0)
    last_ = last(times)
    return typeof(last_)[last_+i*step for i in 1:h]
end

"""
    forecastfan(frame::CausalFrame, column; h = 12, models = nothing,
                model = :model, key = nothing, levels = (0.8, 0.95),
                history = 200) -> Loki.DiagnosticResult

`h` steps ahead from the end of the series, with prediction intervals at each of
`levels` — the fan chart. The last `history` observed rows come back with it, so
the plot has something to fan out from.

The model comes from `models` — the frame a fit node's `model` port loaded — or
from a [`FittedARMA`](@ref) column in `frame` itself. It usually has to be
`models`: [`applyarma`](@ref) drops the model column, so an in-sample stream
carries no model to forecast with.
"""
function forecastfan(frame::CausalFrame, column::Union{Symbol,AbstractString};
    h::Integer = 12, models = nothing, model = :model, key = nothing,
    levels = (0.8, 0.95), history::Integer = 200)
    col = Symbol(column)
    warnings = String[]
    summary = basesummary(frame, col, key)
    ls = Float64[Float64(l) for l in (levels isa Real ? (levels,) : levels)]
    summary["h"] = Int(h)
    summary["levels"] = ls
    v = numericvalues(frame, col; key)
    summary["n"] = length(v.values)
    summary["missing"] = v.dropped

    source = models === nothing ? frame : models
    fitted = fittedmodels(source, Symbol(model), key)
    empty = Dict{String,Any}("history" => Dict{String,Any}("time" => Any[],
        "values" => Any[]), "time" => Any[], "mean" => Any[],
        "intervals" => Any[])
    if isempty(fitted)
        pushwarning!(
            warnings,
            "no fitted model to forecast with: pass the fit node's \
            model port as `models`, since applyarma drops the model column",
        )
        return DiagnosticResult(:forecastfan; data = empty, summary, warnings)
    end
    fm = last(fitted)
    summary["model"] = fitreport(source; column = Symbol(model), key).summary
    if fm.status !== :ok || fm.model === nothing
        pushwarning!(
            warnings,
            "the model failed to fit, so there is nothing to \
            forecast: $(fm.message)",
        )
        return DiagnosticResult(:forecastfan; data = empty, summary, warnings)
    end
    (h >= 1 && !isempty(v.values)) || return DiagnosticResult(:forecastfan;
        data = empty, summary,
        warnings = pushwarning!(warnings, "nothing to forecast from"))

    fc = try
        SSM.forecast(refitted(fm, v.values), Int(h); filter = nonsteady(fm))
    catch err
        err isa InterruptException && rethrow()
        pushwarning!(
            warnings,
            "the forecast could not be computed: $(sprint(showerror, err))",
        )
        return DiagnosticResult(:forecastfan; data = empty, summary, warnings)
    end
    means = Float64[only(e) for e in fc.expected_value]
    sds = Float64[sqrt(max(only(c), 0.0)) for c in fc.covariance]
    times = futuretimes(v.times, h)
    isempty(times) && pushwarning!(
        warnings,
        "the series is too short or too irregular to \
        place the forecast in time",
    )
    keep = max(length(v.values)-history+1, 1):length(v.values)
    intervals = Any[
        Dict{String,Any}("level" => l,
            "lower" => jsonnumbers(means .- zscore(l) .* sds),
            "upper" => jsonnumbers(means .+ zscore(l) .* sds)) for l in ls
    ]
    summary["mean"] = jsonnumbers(means)
    summary["sd"] = jsonnumbers(sds)
    return DiagnosticResult(:forecastfan;
        data = Dict{String,Any}(
            "history" => Dict{String,Any}("time" => jsontimes(view(v.times, keep)),
                "values" => jsonnumbers(view(v.values, keep))),
            "time" => jsontimes(times), "mean" => jsonnumbers(means),
            "intervals" => intervals), summary, warnings)
end

# --- the residual panel --------------------------------------------------------

# The columns an apply operator appends, from either the residual column itself
# or the series it came from.
function residualcolumns(frame::CausalFrame, column::Symbol)
    names = Set(Tables.schema(frame).names)
    base =
        endswith(String(column), "_residual") ?
        Symbol(chop(String(column); tail = length("_residual"))) : column
    residual = Symbol(base, :_residual)
    residual in names || throw(ArgumentError("no residual column for \
        $(repr(String(column))): expected $(repr(String(residual))). The frame has \
        $(join(repr.([String(n) for n in names if endswith(String(n), "_residual")]),
            ", "))"))
    pick(name) = name in names ? name : nothing
    return (; base, residual, stdresidual = pick(Symbol(base, :_stdresidual)),
        fitted = pick(Symbol(base, :_fitted)), actual = pick(base))
end

# The rows a whole-window fit was fitted on, and the rows after it. `fitstop` is
# a time or a `Context` whose `stop` splits them; without one, every row is in
# sample, which is what a fit over the run's own context means.
# A `fitstop` that arrived as a query string is text whatever the frame's time
# type is, and comparing text to a `DateTime` is a `MethodError` rather than an
# answer. It is parsed into the time type here, so a bad one names itself.
fitstoptime(::Type, stop) = stop
function fitstoptime(::Type{T}, stop::AbstractString) where {T}
    T <: AbstractString && return stop
    try
        return parse(T, stop)
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("fitstop $(repr(stop)) is not a $T"))
    end
end

function splitatfit(frame::CausalFrame, fitstop)
    stop = fitstop isa Context ? fitstop.stop : fitstop
    ctx = context(frame)
    stop === nothing && return (frame, nothing)
    stop = fitstoptime(
        Base.nonmissingtype(columntype(Tables.schema(frame), :time)), stop)
    df = DataFrame(frame)
    inside = df.time .< stop
    all(inside) && return (frame, nothing)
    any(inside) || return (nothing, frame)
    return (CausalFrame(ctx, df[inside, :]), CausalFrame(ctx, df[.!inside, :]))
end

function halfsummary(frame::Union{Nothing,CausalFrame}, residual::Symbol, key)
    frame === nothing && return nothing
    v = numericvalues(frame, residual; key)
    return seriessummary(v.values, v.dropped)
end

"""
    Loki.residuals(frame::CausalFrame, column; key = nothing, lags = 40,
                   dof = nothing, fitstop = nothing, level = 0.95,
                   maxpoints = 2000) -> Loki.DiagnosticResult

The residual panel: everything the Box–Jenkins identification loop asks of a
fit, in one result. `column` is the residual column or the series it came from.
Its `panels` are

| Panel | What it shows |
|---|---|
| `series` | the residuals over time |
| `fitted` | the fitted values over the actual series |
| `acf`, `pacf` | the residual correlogram, over the fitted rows |
| `ljungbox` | the test at 10, 20 and 40 lags, with `dof` given up |
| `histogram`, `qqplot` | the residual distribution against a normal |

`dof` is the model's parameters, which the test must give up: see
[`ljungbox`](@ref). `fitstop` is the fit context's `stop` when the fit was
narrower than the window — rows before it carry in-sample residuals, rows after
it the same model applied out of sample, and the summary reports the two
separately.
"""
function residuals(frame::CausalFrame, column::Union{Symbol,AbstractString};
    key = nothing, lags = nothing, dof = nothing, fitstop = nothing,
    level::Real = 0.95, maxpoints::Integer = 2000)
    cols = residualcolumns(frame, Symbol(column))
    warnings = String[]
    summary = basesummary(frame, cols.residual, key)
    d = dof === nothing ? something(armadof(frame), 0) : Int(dof)

    inside, outside = splitatfit(frame, fitstop)
    fitted = inside === nothing ? frame : inside
    inside === nothing && pushwarning!(
        warnings,
        "no row falls inside the fit window, so \
        every residual here is out of sample",
    )
    shape = cols.stdresidual === nothing ? cols.residual : cols.stdresidual

    panels = Dict{String,DiagnosticResult}(
        "series" => seriesplot(frame, cols.residual; key, maxpoints),
        "acf" => acf(fitted, cols.residual; lags, key, level),
        "pacf" => pacf(fitted, cols.residual; lags, key, level),
        "ljungbox" =>
            ljungbox(fitted, cols.residual; lags = [10, 20, 40], dof = d, key),
        "histogram" => histogram(fitted, shape; key),
        "qqplot" => qqplot(fitted, shape; key))
    if cols.fitted !== nothing && cols.actual !== nothing
        panels["fitted"] = seriesplot(frame, cols.actual, cols.fitted; key, maxpoints)
    else
        pushwarning!(
            warnings,
            "no fitted-value column beside $(repr(String(cols.residual)))",
        )
    end

    lb = panels["ljungbox"]
    summary["residual"] = String(cols.residual)
    summary["dof"] = d
    summary["dofsource"] = lb.summary["dofsource"]
    summary["fitstop"] =
        fitstop === nothing ? nothing :
        jsontime(fitstop isa Context ? fitstop.stop : fitstop)
    summary["insample"] = halfsummary(inside, cols.residual, key)
    summary["outofsample"] = halfsummary(outside, cols.residual, key)
    summary["ljungbox"] = lb.summary["pvalues"]
    summary["acf_significant"] = panels["acf"].summary["significant"]
    summary["whitenoise"] = lb.summary["whitenoise"]
    for panel in values(panels)
        append!(warnings, panel.warnings)
    end
    return DiagnosticResult(:residuals;
        data = Dict{String,Any}("residual" => String(cols.residual),
            "fitstop" => summary["fitstop"], "dof" => d),
        summary, warnings = unique!(warnings), panels)
end

# --- the dispatcher ------------------------------------------------------------
#
# One name to one diagnostic, with the coercion a query string needs. The server
# and the MCP `get_diagnostic` tool both come through here, so neither has to
# know the argument list of eleven functions.

querymissing(params::AbstractDict, name::AbstractString) =
    !haskey(params, name) || params[name] === nothing ||
    (params[name] isa AbstractString && isempty(params[name]))

function queryvalue(params::AbstractDict, name::AbstractString, parse, default)
    querymissing(params, name) && return default
    v = params[name]
    try
        return parse(v)
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("$name is not $(lowercase(string(parse))): $(repr(v))"))
    end
end

queryint(params, name, default = nothing) =
    queryvalue(params, name, v -> v isa Integer ? Int(v) : parse(Int, String(v)), default)
queryfloat(params, name, default = nothing) =
    queryvalue(params, name,
        v -> v isa Real ? Float64(v) : parse(Float64, String(v)), default)
querybool(params, name, default = nothing) =
    queryvalue(params, name,
        v -> v isa Bool ? v : parse(Bool, lowercase(String(v))), default)
querysymbol(params, name, default = nothing) =
    querymissing(params, name) ? default : Symbol(params[name])
querystring(params, name, default = nothing) =
    querymissing(params, name) ? default : String(params[name])

# One lag count, or several: `lags=20` and `lags=10,20,40` both read.
function querylags(params, name = "lags", default = nothing)
    querymissing(params, name) && return default
    v = params[name]
    v isa Integer && return Int(v)
    v isa AbstractVector && return Int[Int(x) for x in v]
    parts = split(String(v), ','; keepempty = false)
    length(parts) == 1 && return parse(Int, strip(only(parts)))
    return Int[parse(Int, strip(p)) for p in parts]
end

function querylevels(params, name = "levels", default = (0.8, 0.95))
    querymissing(params, name) && return default
    v = params[name]
    v isa Real && return (Float64(v),)
    v isa AbstractVector && return Tuple(Float64(x) for x in v)
    return Tuple(parse(Float64, strip(p))
                 for p in split(String(v), ','; keepempty = false))
end

function querycolumns(params, name = "columns", default = nothing)
    querymissing(params, name) && return default
    v = params[name]
    v isa AbstractVector && return Symbol[Symbol(c) for c in v]
    return Symbol[Symbol(strip(c)) for c in split(String(v), ','; keepempty = false)]
end

# A key selector as a query string: `key=sym=AAPL,venue=XNAS`. The values stay
# strings, which `keymatches` compares against the shown cell.
function querykey(params, name = "key")
    querymissing(params, name) && return nothing
    v = params[name]
    v isa AbstractDict && return keypairs(collect(pairs(v)))
    v isa Union{Pair,AbstractVector} && return keypairs(v)
    out = Pair{Symbol,Any}[]
    for part in split(String(v), ','; keepempty = false)
        eq = findfirst('=', part)
        eq === nothing &&
            throw(ArgumentError("a key selector is column=value, got $(repr(part))"))
        push!(out, Symbol(strip(part[1:(eq-1)])) => String(strip(part[(eq+1):end])))
    end
    return out
end

# The column a diagnostic is about; the ones that need one say so by name.
function querycolumn(params)
    querymissing(params, "column") &&
        throw(ArgumentError("this diagnostic needs a column"))
    return Symbol(params["column"])
end

# `series` takes either one `column` or a list of them, and `columns` wins. This
# is a function rather than `something(...)` at the call site, which would
# evaluate — and so raise from — the branch it is not taking.
function seriescolumns(params::AbstractDict)
    cols = querycolumns(params)
    cols === nothing && return Symbol[querycolumn(params)]
    return cols
end

const DIAGNOSTICKINDS = Dict{String,Any}(
    "series" =>
        (frame, p) -> seriesplot(frame, seriescolumns(p)...;
            key = querykey(p), maxpoints = queryint(p, "maxpoints", 2000)),
    "preview" =>
        (frame, p) -> preview(frame; offset = queryint(p, "offset", 0),
            limit = queryint(p, "limit", 100), columns = querycolumns(p),
            key = querykey(p)),
    "acf" =>
        (frame, p) -> acf(frame, querycolumn(p); lags = queryint(p, "lags"),
            key = querykey(p), level = queryfloat(p, "level", 0.95)),
    "pacf" =>
        (frame, p) -> pacf(frame, querycolumn(p); lags = queryint(p, "lags"),
            key = querykey(p), level = queryfloat(p, "level", 0.95)),
    "histogram" =>
        (frame, p) -> histogram(frame, querycolumn(p); key = querykey(p),
            bins = queryint(p, "bins")),
    "qqplot" =>
        (frame, p) -> qqplot(frame, querycolumn(p); key = querykey(p),
            maxpoints = queryint(p, "maxpoints", 2000)),
    "adf" =>
        (frame, p) -> adftest(frame, querycolumn(p); key = querykey(p),
            deterministic = querysymbol(p, "deterministic", :constant),
            lag = queryint(p, "lag")),
    "ljungbox" =>
        (frame, p) -> ljungbox(frame, querycolumn(p); lags = querylags(p),
            dof = queryint(p, "dof"), key = querykey(p),
            modelcolumn = querysymbol(p, "modelcolumn")),
    "fit" =>
        (frame, p) -> fitreport(frame; column = querysymbol(p, "column", :model),
            key = querykey(p)),
    "forecast" =>
        (frame, p) -> forecastfan(frame, querycolumn(p);
            h = queryint(p, "h", 12), models = get(p, "models", nothing),
            model = querysymbol(p, "model", :model), key = querykey(p),
            levels = querylevels(p), history = queryint(p, "history", 200)),
    "residuals" =>
        (frame, p) -> residuals(frame, querycolumn(p); key = querykey(p),
            lags = queryint(p, "lags"), dof = queryint(p, "dof"),
            fitstop = get(p, "fitstop", nothing),
            level = queryfloat(p, "level", 0.95),
            maxpoints = queryint(p, "maxpoints", 2000)))

"""
    Loki.diagnostics() -> Vector{String}

The names [`Loki.diagnostic`](@ref) accepts, sorted.
"""
diagnostics() = sort!(collect(keys(DIAGNOSTICKINDS)))

"""
    Loki.diagnostic(frame::CausalFrame, kind; params = Dict()) -> Loki.DiagnosticResult

Run the diagnostic named `kind` over `frame`, taking its arguments from `params`
— a dictionary of JSON-like or string values, as a query string or an MCP tool
call supplies them. `"column"`, `"lags"`, `"key"` and the rest are coerced to
what the diagnostic wants, so the HTTP layer and the MCP layer share one
argument list instead of writing two.

`Loki.diagnostics()` lists the names.
"""
function diagnostic(frame::CausalFrame, kind::AbstractString;
    params::AbstractDict = Dict{String,Any}())
    f = get(DIAGNOSTICKINDS, String(kind), nothing)
    f === nothing && throw(ArgumentError("unknown diagnostic $(repr(String(kind))); \
        there is $(join(diagnostics(), ", "))"))
    return f(frame, Dict{String,Any}(String(k) => v for (k, v) in pairs(params)))
end
