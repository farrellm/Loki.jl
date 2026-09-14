# A session: one live analysis — the graph, the named contexts and tables, the
# user code, the result cache, node status, and the current run — driven headless
# from the REPL. Every mutation takes the session lock.

"""
    Loki.Session(; tables = (;), contexts = (;), prelude = "", cachebytes = 2^30)

One live analysis: a [`Loki.Graph`](@ref), named contexts (runs are over
`"analysis"` unless told otherwise), in-memory tables for `table` nodes, the
[`Loki.UserCode`](@ref) module, a result cache of `cachebytes`, each node's
status, and the current [`Loki.Run`](@ref).

```julia
s = Loki.Session(; tables = (prices = df,), contexts = (analysis = Context(0, 1000),))
src = Loki.addnode!(s, "table", Dict("table" => "prices"))
fit = Loki.addnode!(s, "fit", Dict("family" => "arma", "column" => "close", "order" => [1, 0, 1]))
Loki.connect!(s, (src, :out), (fit, :in))
wait(Loki.run!(s, [(fit, :insample)]))
Loki.result(s, fit; port = :insample)
```
"""
mutable struct Session
    const graph::Graph
    const contexts::Dict{String,Context}
    const tables::Dict{String,Any}
    const usercode::UserCode
    const cache::ResultCache
    const status::Dict{String,Symbol}
    const errors::Dict{String,Exception}
    run::Union{Nothing,Run}
    const lock::ReentrantLock
end

function Session(; tables = (;), contexts = (;), prelude::AbstractString = "",
    cachebytes::Integer = 2^30)
    return Session(Graph(),
        Dict{String,Context}(String(k) => v for (k, v) in pairs(contexts)),
        Dict{String,Any}(String(k) => v for (k, v) in pairs(tables)),
        UserCode(; prelude), ResultCache(cachebytes), Dict{String,Symbol}(),
        Dict{String,Exception}(), nothing, ReentrantLock())
end

buildenv(s::Session) = BuildEnv(s.usercode, s.contexts, s.tables)

# --- session state -------------------------------------------------------------------

"""
    Loki.setcontext!(s::Session, name, ctx::Context) -> Session

Define or replace the named context `name`.
"""
function setcontext!(s::Session, name::AbstractString, ctx::Context)
    lock(s.lock) do
        s.contexts[String(name)] = ctx
    end
    return s
end

"""
    Loki.addtable!(s::Session, name, table) -> Session

Hold `table` — any Tables.jl table, or a loaded `CausalFrame` — under `name`, for
`table` nodes to read. Replacing a table invalidates the results that read it.
"""
function addtable!(s::Session, name::AbstractString, table)
    lock(s.lock) do
        s.tables[String(name)] = table
    end
    return s
end

"""
    Loki.setprelude!(s::Session, prelude::AbstractString) -> Session

Replace the session's prelude of helper definitions; see
[`Loki.setprelude!`](@ref)`(::UserCode, …)`.
"""
function setprelude!(s::Session, prelude::AbstractString)
    lock(s.lock) do
        setprelude!(s.usercode, prelude)
    end
    return s
end

# --- graph edits ---------------------------------------------------------------------

"""
    Loki.addnode!(s::Session, kind, params = Dict(); id = nothing, position = (0, 0)) -> String
    Loki.updatenode!(s::Session, id, params) -> Session
    Loki.removenode!(s::Session, id) -> Session
    Loki.connect!(s::Session, from, to; id = nothing) -> String
    Loki.disconnect!(s::Session, id) -> Session

Edit the session's graph as the [`Loki.Graph`](@ref) functions do, under the session
lock. An edit invalidates the node it touches and everything downstream: their
cached results are dropped and their status returns to `:idle`.
"""
function addnode!(s::Session, kind::AbstractString,
    params::AbstractDict = Dict{String,Any}();
    kwargs...)
    return lock(s.lock) do
        addnode!(s.graph, kind, params; kwargs...)
    end
end

function updatenode!(s::Session, id::AbstractString, params::AbstractDict)
    lock(s.lock) do
        setparams!(s.graph, id, params)
        invalidate!(s, String(id))
    end
    return s
end

function removenode!(s::Session, id::AbstractString)
    lock(s.lock) do
        getnode(s.graph, id)
        invalidate!(s, String(id))
        removenode!(s.graph, id)
        delete!(s.status, id)
        delete!(s.errors, id)
    end
    return s
end

function connect!(s::Session, from, to; kwargs...)
    return lock(s.lock) do
        eid = connect!(s.graph, from, to; kwargs...)
        invalidate!(s, String(to[1]))
        eid
    end
end

function disconnect!(s::Session, id::AbstractString)
    lock(s.lock) do
        i = findfirst(e -> e.id == id, s.graph.edges)
        i === nothing || invalidate!(s, s.graph.edges[i].to[1])
        disconnect!(s.graph, id)
    end
    return s
end

function invalidate!(s::Session, id::String)
    affected = push!(descendants(s.graph, id), id)
    cachedrop!(s.cache, k -> k[1] in affected)
    for a in affected
        s.status[a] = :idle
        delete!(s.errors, a)
    end
    return s
end

# --- status and results ----------------------------------------------------------------

"""
    Loki.status(s::Session, id) -> Symbol

A node's status: `:idle`, `:running`, `:ok`, `:error` (see
[`Loki.nodeerror`](@ref)) or `:blocked` by an error upstream.
"""
status(s::Session, id::AbstractString) =
    lock(() -> get(s.status, String(id), :idle), s.lock)

"""
    Loki.nodeerror(s::Session, id) -> Union{Nothing,NodeError}

The [`Loki.NodeError`](@ref) that failed or blocked a node in the last run.
"""
nodeerror(s::Session, id::AbstractString) =
    lock(() -> get(s.errors, String(id), nothing), s.lock)

"""
    Loki.isacausal(s::Session, id; port = nothing) -> Bool

Whether a node's output `port` — or, with `port = nothing`, any of its outputs — is
tainted by an acausal operator upstream.
"""
function isacausal(s::Session, id::AbstractString; port = nothing)
    return lock(s.lock) do
        node = getnode(s.graph, id)
        t = taint(s.graph)
        ports = port === nothing ? outputs(nodekind(node.kind)) : [Symbol(port)]
        any(p -> t[(node.id, p)], ports)
    end
end

function outputport(s::Session, id::String, port)
    node = getnode(s.graph, id)
    outs = outputs(nodekind(node.kind))
    port === nothing && return first(outs)
    Symbol(port) in outs || throw(ArgumentError("node $id has no output port $port"))
    return Symbol(port)
end

"""
    Loki.result(s::Session, id; port = nothing, context = "analysis")
        -> Union{Nothing,CausalFrame}

The cached result of a node's output `port` (its first by default) over the named
context, or `nothing` if it has not been evaluated since it last changed.
"""
function result(s::Session, id::AbstractString; port = nothing,
    context::AbstractString = "analysis")
    return lock(s.lock) do
        env = buildenv(s)
        nid = String(id)
        key = (nid, outputport(s, nid, port), nodehashes(s.graph, env)[nid],
            namedcontext(env, context))
        cacheget(s.cache, key)
    end
end

# --- runs --------------------------------------------------------------------------------

totargets(s::Session, id::AbstractString) =
    [(String(id), p) for p in outputs(nodekind(getnode(s.graph, id).kind))]
totargets(s::Session, target::Tuple) =
    [(String(target[1]), outputport(s, String(target[1]), target[2]))]
totargets(s::Session, targets::AbstractVector) =
    unique!(reduce(vcat, [totargets(s, t) for t in targets]; init = Tuple{String,Symbol}[]))

"""
    Loki.run!(s::Session, targets; context = "analysis", progress = nothing) -> Run

Evaluate the watched `targets` — node ids (every output), `(id, port)` pairs, or a
vector of them — over the named context, cancelling any run in flight. The graph
is compiled here, under the session lock, so a bad parameter is recorded before
this returns; the pipelines are then streamed on a worker task, one chunk at a
time, checking for cancellation between chunks and calling
`progress(id, port, rows)` after each. Results go to the cache and statuses to the
session. Write nodes pass their input through; only [`Loki.write!`](@ref) writes.
"""
function run!(s::Session, targets; context::AbstractString = "analysis", progress = nothing)
    return lock(s.lock) do
        cancel!(s)
        env = buildenv(s)
        ctx = namedcontext(env, context)
        wanted = totargets(s, targets)
        run = Run(wanted, Threads.Atomic{Bool}(false), nothing)
        s.run = run
        c = Compilation(s.graph, env, ctx, nodehashes(s.graph, env), s.cache,
            Dict{String,NamedTuple}(), Set{String}())
        jobs = Job[]
        for (id, port) in wanted
            try
                # Source-text functions are newer than this code; see usercode.jl.
                p = Base.invokelatest(compileport!, c, id, port)
                push!(jobs, Job(id, port, c.hashes[id], p))
                s.status[id] = :running
                delete!(s.errors, id)
            catch err
                err isa InterruptException && rethrow()
                recorderror!(s, err, id)
            end
        end
        run.task = Threads.@spawn executerun(s, run, ctx, jobs, progress)
        run
    end
end

"""
    Loki.cancel!(s::Session) -> Session

Cancel the run in flight, if any; it stops before its next chunk.
"""
function cancel!(s::Session)
    lock(s.lock) do
        s.run === nothing || (s.run.cancelled[] = true)
    end
    return s
end

function executerun(s::Session, run::Run, ctx::Context, jobs::Vector{Job}, progress)
    for job in jobs
        run.cancelled[] && break
        frame = try
            Base.invokelatest(streamjob, run, ctx, job, progress)
        catch err
            err isa InterruptException && rethrow()
            lock(s.lock) do
                s.run === run && recorderror!(s, err, job.id)
            end
            continue
        end
        lock(s.lock) do
            if frame === nothing
                s.run === run && (s.status[job.id] = :idle)
            else
                cacheput!(s.cache, (job.id, job.port, job.hash, ctx), frame)
                s.run === run && get(s.status, job.id, :idle) === :running &&
                    (s.status[job.id] = :ok)
            end
        end
    end
    lock(s.lock) do
        s.run === run || return
        for (id, _) in run.targets
            get(s.status, id, :idle) === :running && (s.status[id] = :idle)
        end
    end
    return nothing
end

# Drain one job's chunks — `nothing` if cancelled part way. The chunks come from
# the pipeline's `run` directly (a recorded read of the field): `stream` would
# wrap each in a frame the cache would then have to copy back out.
function streamjob(run::Run, ctx::Context, job::Job, progress)
    chunks = DataFrame[]
    rows = 0
    for chunk in job.pipeline.run(ctx)
        run.cancelled[] && return nothing
        push!(chunks, chunk)
        rows += nrow(chunk)
        progress === nothing || progress(job.id, job.port, rows)
    end
    run.cancelled[] && return nothing
    return tagerrors(() -> CausalFrame(ctx, chunks), job.id)
end

function tagerrors(f, id::String)
    try
        return f()
    catch err
        err isa InterruptException && rethrow()
        throw(tagerror(err, id))
    end
end

# The failing node (a NodeError's, else the target itself) is `:error`; the target
# and every node between them are `:blocked`.
function recorderror!(s::Session, err, target::String)
    nerr = tagerror(err, target)
    failing = nerr.id
    if haskey(s.graph.nodes, failing)
        s.status[failing] = :error
        s.errors[failing] = nerr
    end
    if failing != target
        between =
            haskey(s.graph.nodes, failing) ?
            intersect(descendants(s.graph, failing), ancestors(s.graph, target)) : ()
        for id in (between..., target)
            s.status[id] = :blocked
            s.errors[id] = nerr
        end
    end
    return s
end

"""
    Loki.write!(s::Session, id; context = "analysis") -> Session

Evaluate the write node `id` over the named context for its side effect — the
only way a write node writes. Runs on the calling task; an error is raised as a
[`Loki.NodeError`](@ref).
"""
function write!(s::Session, id::AbstractString; context::AbstractString = "analysis")
    nid = String(id)
    ctx, p = lock(s.lock) do
        node = getnode(s.graph, nid)
        iswrite(nodekind(node.kind)) ||
            throw(ArgumentError("node $nid ($(node.kind)) is not a write node"))
        env = buildenv(s)
        ctx = namedcontext(env, context)
        c = Compilation(s.graph, env, ctx, nodehashes(s.graph, env), s.cache,
            Dict{String,NamedTuple}(), Set([nid]))
        ctx, Base.invokelatest(compileport!, c, nid, first(outputs(nodekind(node.kind))))
    end
    Base.invokelatest(scan, ctx, p)
    return s
end

"""
    Loki.freeze!(s::Session, id; port = nothing, name = "frozen_" * id,
                 context = "analysis") -> String

Load a node's output over the named context — from the cache when it is there —
and hold the frame as the table `name`, pinning an intermediate result to branch
from. Returns the table name. The frozen frame keeps `readtable`'s frame
semantics: a `table` node reading it refuses a context outside the frame's own.
"""
function freeze!(s::Session, id::AbstractString; port = nothing,
    name::AbstractString = "frozen_" * String(id), context::AbstractString = "analysis")
    nid = String(id)
    frame = result(s, nid; port, context)
    if frame === nothing
        ctx, p = lock(s.lock) do
            env = buildenv(s)
            ctx = namedcontext(env, context)
            c = Compilation(s.graph, env, ctx, nodehashes(s.graph, env), s.cache,
                Dict{String,NamedTuple}(), Set{String}())
            ctx, Base.invokelatest(compileport!, c, nid, outputport(s, nid, port))
        end
        frame = Base.invokelatest(load, ctx, p)
    end
    addtable!(s, name, frame)
    return String(name)
end
