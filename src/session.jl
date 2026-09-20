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
    const subscribers::Vector{Subscriber}
    seq::Int
    # Set while a batch of edits replays into the session — opening a file — so a
    # hundred `addnode!`s are one `graph_changed` rather than a hundred.
    quiet::Bool
    # The file this session was last saved to or opened from, so a browser can
    # show what it is looking at and `Save` can overwrite without asking again.
    file::Union{Nothing,String}
    # The web server, once there is one. Untyped for the same reason
    # `Compilation.cache` is: it is defined later than this.
    server::Any
end

function Session(; tables = (;), contexts = (;), prelude::AbstractString = "",
    cachebytes::Integer = 2^30)
    return Session(Graph(),
        Dict{String,Context}(String(k) => v for (k, v) in pairs(contexts)),
        Dict{String,Any}(String(k) => v for (k, v) in pairs(tables)),
        UserCode(; prelude), ResultCache(cachebytes), Dict{String,Symbol}(),
        Dict{String,Exception}(), nothing, ReentrantLock(), Subscriber[], 0, false,
        nothing, nothing)
end

# --- events ---------------------------------------------------------------------

"""
    Loki.subscribe!(s::Session; buffer = 256) -> Loki.Subscriber

Watch every change to the session. Read the returned [`Loki.Subscriber`](@ref)
with [`Loki.nextevent`](@ref) or by iterating it, and end the subscription with
[`Loki.unsubscribe!`](@ref) — which a watcher must do, or its queue fills and
its events are dropped.
"""
function subscribe!(s::Session; buffer::Integer = 256)
    return lock(s.lock) do
        sub = Subscriber(length(s.subscribers) + 1, buffer)
        push!(s.subscribers, sub)
        sub
    end
end

"""
    Loki.unsubscribe!(s::Session, sub::Loki.Subscriber) -> Session

End a subscription and close its queue, which ends anything iterating it.
"""
function unsubscribe!(s::Session, sub::Subscriber)
    lock(s.lock) do
        filter!(x -> x !== sub, s.subscribers)
    end
    close(sub)
    return s
end

"""
    Loki.emit!(s::Session, kind::Symbol, payload::AbstractDict) -> Loki.Event

Broadcast one change to every subscriber, attributed to
[`Loki.currentorigin`](@ref). Offering is non-blocking, so this is safe to call
with the session lock held — which is the point: events then carry the same
order the mutations did.
"""
emit!(s::Session, kind::Symbol, payload::AbstractDict) =
    emit!(s, kind, payload, currentorigin())

function emit!(s::Session, kind::Symbol, payload::AbstractDict, origin::Symbol)
    return lock(s.lock) do
        e = Event(kind, origin, (s.seq += 1), time(),
            Dict{String,Any}(String(k) => v for (k, v) in pairs(payload)))
        s.quiet && return e
        for sub in s.subscribers
            offer!(sub, e)
        end
        e
    end
end

# A graph edit: what changed, and which nodes it invalidated (the client marks
# those idle rather than receiving one status event per node).
graphchanged!(s::Session, change::AbstractString; kwargs...) =
    emit!(s, :graph_changed,
        Dict{String,Any}("change" => change,
            (String(k) => v for (k, v) in pairs(kwargs))...))

function statuschanged!(s::Session, id::AbstractString)
    err = get(s.errors, String(id), nothing)
    return emit!(s, :node_status,
        Dict{String,Any}("id" => String(id),
            "status" => String(get(s.status, String(id), :idle)),
            "error" =>
                err === nothing ? nothing :
                Dict{String,Any}(
                    "node" => err isa NodeError ? err.id : String(id),
                    "message" => sprint(showerror, err))))
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
        graphchanged!(s, "setcontext"; name = String(name), context = contextevent(ctx))
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
        graphchanged!(s, "addtable"; name = String(name), table = tableevent(table))
    end
    return s
end

# A table without its rows: how many, and what columns.
function tableevent(table)
    table isa CausalFrame && return merge(frameevent(table),
        Dict{String,Any}("frame" => true))
    sch = Tables.schema(table)
    rows = Tables.rowcount(Tables.columns(table))
    return Dict{String,Any}("frame" => false, "rows" => rows,
        "columns" => sch === nothing ? String[] : [String(n) for n in sch.names],
        "types" => sch === nothing ? String[] : [string(T) for T in sch.types])
end

"""
    Loki.setprelude!(s::Session, prelude::AbstractString) -> Session

Replace the session's prelude of helper definitions; see
[`Loki.setprelude!`](@ref)`(::UserCode, …)`.
"""
function setprelude!(s::Session, prelude::AbstractString)
    lock(s.lock) do
        setprelude!(s.usercode, prelude)
        # Every source-text parameter is re-evaluated, so everything that holds
        # one is stale — which is every node, as far as the client need care.
        graphchanged!(s, "setprelude"; invalidated = sort!(collect(keys(s.graph.nodes))))
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
        nid = addnode!(s.graph, kind, params; kwargs...)
        graphchanged!(s, "addnode"; id = nid, node = nodeevent(getnode(s.graph, nid)))
        nid
    end
end

function updatenode!(s::Session, id::AbstractString, params::AbstractDict)
    lock(s.lock) do
        setparams!(s.graph, id, params)
        affected = invalidate!(s, String(id))
        graphchanged!(s, "updatenode"; id = String(id),
            node = nodeevent(getnode(s.graph, id)), invalidated = affected)
    end
    return s
end

"""
    Loki.setposition!(s::Session, id, position) -> Session

Move a node on the canvas. Positions play no part in evaluation, so this
invalidates nothing — dragging a node does not throw its result away.
"""
function setposition!(s::Session, id::AbstractString, position)
    lock(s.lock) do
        node = setposition!(s.graph, id, position)
        graphchanged!(s, "position"; id = node.id, node = nodeevent(node))
    end
    return s
end

function removenode!(s::Session, id::AbstractString)
    lock(s.lock) do
        getnode(s.graph, id)
        affected = invalidate!(s, String(id))
        removenode!(s.graph, id)
        delete!(s.status, id)
        delete!(s.errors, id)
        graphchanged!(s, "removenode"; id = String(id), invalidated = affected)
    end
    return s
end

function connect!(s::Session, from, to; kwargs...)
    return lock(s.lock) do
        eid = connect!(s.graph, from, to; kwargs...)
        affected = invalidate!(s, String(to[1]))
        edge = s.graph.edges[findfirst(e -> e.id == eid, s.graph.edges)]
        graphchanged!(s, "connect"; id = eid, edge = edgeevent(edge),
            invalidated = affected)
        eid
    end
end

function disconnect!(s::Session, id::AbstractString)
    lock(s.lock) do
        i = findfirst(e -> e.id == id, s.graph.edges)
        affected = i === nothing ? String[] : invalidate!(s, s.graph.edges[i].to[1])
        disconnect!(s.graph, id)
        graphchanged!(s, "disconnect"; id = String(id), invalidated = affected)
    end
    return s
end

# The nodes an edit made stale: the node itself and everything downstream. They
# are reported as one list on the `graph_changed` event rather than as a status
# event each, which would be dozens of messages for one keystroke.
function invalidate!(s::Session, id::String)
    affected = push!(descendants(s.graph, id), id)
    cachedrop!(s.cache, k -> k[1] in affected)
    for a in affected
        s.status[a] = :idle
        delete!(s.errors, a)
    end
    return sort!(collect(affected))
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
        # The cancelled run no longer owns the session's statuses, so it cannot
        # settle its unfinished targets itself.
        if s.run !== nothing
            for (id, _) in s.run.targets
                get(s.status, id, :idle) === :running && (s.status[id] = :idle)
            end
        end
        env = buildenv(s)
        ctx = namedcontext(env, context)
        wanted = totargets(s, targets)
        run = Run(wanted, Threads.Atomic{Bool}(false), nothing;
            origin = currentorigin())
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
                statuschanged!(s, id)
            catch err
                err isa InterruptException && rethrow()
                recorderror!(s, err, id)
            end
        end
        runprogress!(s, run, "started"; targets = wanted, context = String(context))
        run.task = Threads.@spawn executerun(s, run, ctx, jobs, progress)
        run
    end
end

runprogress!(s::Session, run::Run, state::AbstractString; kwargs...) =
    emit!(s, :run_progress,
        Dict{String,Any}("state" => state,
            (
                String(k) =>
                    k === :targets ?
                    Any[Any[id, String(port)] for (id, port) in v] : v
                for (k, v) in pairs(kwargs)
            )...), run.origin)

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

# The caller's `progress` callback, plus a throttled `run_progress` event. A
# pipeline that yields a thousand small chunks would otherwise send a thousand
# messages for one run.
function progressreporter(s::Session, run::Run, progress)
    return function (id::String, port::Symbol, rows::Int)
        progress === nothing || progress(id, port, rows)
        now = time()
        last = get(run.lastprogress, (id, port), 0.0)
        now - last < PROGRESSINTERVAL && return nothing
        run.lastprogress[(id, port)] = now
        runprogress!(s, run, "running"; id, port = String(port), rows)
        return nothing
    end
end

function executerun(s::Session, run::Run, ctx::Context, jobs::Vector{Job}, progress)
    report = progressreporter(s, run, progress)
    for (i, job) in enumerate(jobs)
        run.cancelled[] && break
        frame = try
            Base.invokelatest(streamjob, run, ctx, job, report)
        catch err
            err isa InterruptException && rethrow()
            lock(s.lock) do
                s.run === run && recorderror!(s, err, job.id)
            end
            continue
        end
        lock(s.lock) do
            # A superseded run owns nothing of the session any more — not its
            # statuses and not its cache. Its frame is keyed by an upstream hash
            # that is still correct, but the session it was computed for may since
            # have been reset or reopened, and refilling that cache would resurrect
            # a result for a graph that no longer exists.
            s.run === run || return
            if frame === nothing
                s.status[job.id] = :idle
                statuschanged!(s, job.id)
            else
                cacheput!(s.cache, (job.id, job.port, job.hash, ctx), frame)
                emit!(s, :result_ready,
                    merge(frameevent(frame),
                        Dict{String,Any}("id" => job.id, "port" => String(job.port),
                            "context" => contextevent(ctx))), run.origin)
                # A node is :ok once its last watched port is in, not its first.
                if get(s.status, job.id, :idle) === :running &&
                   !any(j -> j.id == job.id, view(jobs, (i+1):lastindex(jobs)))
                    s.status[job.id] = :ok
                    statuschanged!(s, job.id)
                end
            end
        end
    end
    lock(s.lock) do
        s.run === run || return
        for (id, _) in run.targets
            if get(s.status, id, :idle) === :running
                s.status[id] = :idle
                statuschanged!(s, id)
            end
        end
        runprogress!(s, run, run.cancelled[] ? "cancelled" : "done";
            targets = run.targets)
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
    haskey(s.graph.nodes, failing) && statuschanged!(s, failing)
    if failing != target
        between =
            haskey(s.graph.nodes, failing) ?
            intersect(descendants(s.graph, failing), ancestors(s.graph, target)) : ()
        for id in (between..., target)
            s.status[id] = :blocked
            s.errors[id] = nerr
            statuschanged!(s, id)
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
    emit!(s, :log,
        Dict{String,Any}("level" => "info", "id" => nid,
            "message" => "wrote $(getnode(s.graph, nid).kind) node $nid"))
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
    graphchanged!(s, "freeze"; id = nid, name = String(name), table = tableevent(frame))
    return String(name)
end
