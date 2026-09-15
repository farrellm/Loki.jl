# Table snapshots: a session's in-memory tables written beside an exported script
# or a saved session, and read back.
#
# The files are CausalFrames' and Parquet2's own, never a Loki format. A plain
# table is a parquet file. A frozen frame is written through the pipeline it came
# from — parquet when its columns allow, CausalFrames' JLS when they hold
# something parquet cannot spell, such as a fitted model — and read back over its
# own context, so it returns as the frame it was.

"""
    Loki.TableFile

Where a session table was snapshotted: its `path`, its `format` (`:parquet` or
`:jls`), whether it holds a `frame` — a frozen `CausalFrame`, read back over the
`context` it was loaded over, so it keeps `readtable`'s frame semantics — and
that context (`nothing` for a plain table).
"""
struct TableFile
    path::String
    format::Symbol
    frame::Bool
    context::Union{Nothing,Context}
end

"""
    Loki.savetable(dir, name, table) -> Loki.TableFile

Write a session table into `dir` as `name.parquet`, or `name.jls` for a frozen
`CausalFrame` whose columns parquet cannot hold, and return where it went.

A frame goes through `readtable(frame) |> writeparquet` (or `writejls`) over its
own context; any other Tables.jl table is written by `Parquet2.writefile`, which
needs no `:time` column, so a `lookupjoin`'s timeless table snapshots too. A
plain table holding what parquet cannot store is an `ArgumentError` naming the
column — freeze the node that produced it, or export with `tables = :argument`.
"""
function savetable(dir::AbstractString, name::AbstractString, table)
    bad = unstorablecolumn(table)
    if table isa CausalFrame
        ctx = context(table)
        if bad === nothing
            path = joinpath(dir, "$name.parquet")
            scan(ctx, readtable(table) |> writeparquet(path; backend = :parquet2))
            return TableFile(path, :parquet, true, ctx)
        end
        path = joinpath(dir, "$name.jls")
        scan(ctx, readtable(table) |> writejls(path))
        return TableFile(path, :jls, true, ctx)
    end
    bad === nothing || throw(ArgumentError("table $(repr(name)) cannot be \
        snapshotted: its column $(bad[1]) holds $(bad[2]), which parquet cannot \
        store. Freeze the node that produced it, or export with tables = :argument."))
    path = joinpath(dir, "$name.parquet")
    Parquet2.writefile(path, table)
    return TableFile(path, :parquet, false, nothing)
end

"""
    Loki.loadtable(file::Loki.TableFile)

Read back what [`Loki.savetable`](@ref) wrote: a `DataFrame` for a plain table,
and for a frame the `CausalFrame` it was, loaded over its own context.
"""
function loadtable(file::TableFile)
    file.frame || return DataFrame(Parquet2.Dataset(file.path); copycols = false)
    return load(file.context, framesource(file))
end

# `closed = true` keeps the rows at `stop`, which is what `readtable(frame)` does
# over the frame's own context, so what comes back holds the rows that went in.
framesource(file::TableFile) =
    file.format === :parquet ?
    readparquet(file.path; closed = true, backend = :parquet2) :
    readjls(file.path; closed = true)

# The expression an exported script reads the snapshot back with, beside itself.
function tableexpr(file::TableFile)
    path = Expr(:call, :joinpath, :SCRIPTDIR, basename(file.path))
    file.frame || return opcall(:DataFrame,
        Expr(:call, qualified(:Parquet2, :Dataset), path); copycols = false)
    source =
        file.format === :parquet ?
        opcall(:readparquet, path; closed = true, backend = QuoteNode(:parquet2)) :
        opcall(:readjls, path; closed = true)
    return Expr(:call, :load, contextexpr(file.context), source)
end

# The first column parquet cannot store, as (name, type), or `nothing`.
function unstorablecolumn(table)
    schema = Tables.schema(table)
    (schema === nothing || schema.types === nothing) &&
        return (:unknown, "columns of unknown type")
    for (name, T) in zip(schema.names, schema.types)
        parquetstorable(T) || return (name, T)
    end
    return nothing
end

function parquetstorable(T)
    S = nonmissingtype(T)
    S === Bool && return true
    S <: AbstractString && return true
    S <: Union{Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32,UInt64,Float32,Float64} &&
        return true
    return S <: Dates.Date || S <: Dates.DateTime
end
