# Events: every mutation of a session, broadcast to whoever is watching — a
# browser's WebSocket, and in Milestone 4 an MCP client. There is one graph and
# one lock, so the user sees what an agent did and the agent is told what the
# user changed.
#
# Two rules shape everything here. Broadcasting happens while the session lock is
# held, so events are totally ordered with the mutations that caused them — which
# is only safe because offering an event never blocks. And every event carries a
# monotonic `seq`, so a client that sees a gap knows to refetch rather than
# believe a stale picture: events are a live-update convenience, and the REST
# state is the truth.

using Base.ScopedValues: ScopedValue, with

"""
    Loki.Event

One broadcast change: its `kind` (`:graph_changed`, `:node_status`,
`:run_progress`, `:result_ready` or `:log`), the `origin` that caused it
(`:ui`, `:mcp` or `:repl`), a monotonic `seq`, the `time` it happened, and a
JSON-like `payload`.
"""
struct Event
    kind::Symbol
    origin::Symbol
    seq::Int
    time::Float64
    payload::Dict{String,Any}
end

JSON3.StructTypes.StructType(::Type{Event}) = JSON3.StructTypes.Struct()

Base.show(io::IO, e::Event) =
    print(io, "Event(:", e.kind, ", ", e.origin, ", seq = ", e.seq, ")")

"""
    Loki.Subscriber

One watcher's queue of [`Loki.Event`](@ref)s, from [`Loki.subscribe!`](@ref).
Read it with [`Loki.nextevent`](@ref) or by iterating it; it ends when the
subscription is closed.

The queue is bounded and is never blocked on. A watcher that has stopped reading
— a WebSocket whose peer has gone away without closing — loses events and has
them counted in `dropped`, rather than stalling the session lock for everyone
else. The gap shows up as a jump in `seq`.
"""
mutable struct Subscriber
    const id::Int
    const channel::Channel{Event}
    const capacity::Int
    const queued::Threads.Atomic{Int}
    dropped::Int
end

Subscriber(id::Integer, capacity::Integer) =
    Subscriber(Int(id), Channel{Event}(Int(capacity)), Int(capacity),
        Threads.Atomic{Int}(0), 0)

Base.isopen(sub::Subscriber) = isopen(sub.channel)
Base.close(sub::Subscriber) = close(sub.channel)

# The one thing a broadcast does. It must never block: it runs under the session
# lock, and a `put!` to a full channel would hold that lock until the slowest
# reader caught up. The queue is counted here rather than with `Base.n_avail`,
# which is internal, and a full queue drops rather than evicting the oldest,
# which would race the reader's `take!`.
function offer!(sub::Subscriber, e::Event)
    isopen(sub) || return false
    if sub.queued[] >= sub.capacity
        sub.dropped += 1
        return false
    end
    Threads.atomic_add!(sub.queued, 1)
    try
        put!(sub.channel, e)
    catch err
        err isa InterruptException && rethrow()
        Threads.atomic_sub!(sub.queued, 1)
        return false
    end
    return true
end

"""
    Loki.nextevent(sub::Loki.Subscriber) -> Union{Nothing,Loki.Event}

The next event, blocking until there is one; `nothing` once the subscription has
been closed and drained.
"""
function nextevent(sub::Subscriber)
    e = try
        take!(sub.channel)
    catch err
        err isa InvalidStateException && return nothing
        rethrow()
    end
    Threads.atomic_sub!(sub.queued, 1)
    return e
end

Base.IteratorSize(::Type{Subscriber}) = Base.SizeUnknown()
Base.eltype(::Type{Subscriber}) = Event

function Base.iterate(sub::Subscriber, ::Nothing = nothing)
    e = nextevent(sub)
    return e === nothing ? nothing : (e, nothing)
end

# --- origin --------------------------------------------------------------------

# Who asked. A scoped value rather than a keyword on ten mutators: five of them
# forward `kwargs...` straight to their `Graph` method, and every internal replay
# — `opensession!` adding a hundred nodes, `freeze!` calling `addtable!` — would
# have to thread it, where one missed call site silently mislabels a change.
const ORIGIN = ScopedValue{Symbol}(:repl)

"""
    Loki.withorigin(f, origin::Symbol)

Run `f` with every session mutation it makes attributed to `origin` — `:ui` for
the HTTP handler, `:mcp` for an agent, and `:repl`, the default, for everyone
else. A task started inside `f` inherits the attribution, which is how a run's
worker reports the origin of the request that started it.
"""
withorigin(f, origin::Symbol) = with(f, ORIGIN => Symbol(origin))

"""
    Loki.currentorigin() -> Symbol

The origin [`Loki.withorigin`](@ref) is currently attributing changes to.
"""
currentorigin() = ORIGIN[]

# --- payload helpers -----------------------------------------------------------

nodeevent(node::Node) = Dict{String,Any}("id" => node.id, "kind" => node.kind,
    "params" => node.params,
    "position" => Any[node.position[1], node.position[2]])

edgeevent(e::Edge) = Dict{String,Any}("id" => e.id,
    "from" => Any[e.from[1], String(e.from[2])],
    "to" => Any[e.to[1], String(e.to[2])])

# A context on the wire. Deliberately not `contextjson`, which refuses a time
# type a session file cannot store: an event is a notification, and an exotic
# context must not make editing one throw.
contextevent(ctx::Context{T}) where {T} =
    Dict{String,Any}("timetype" => string(nameof(T)), "start" => jsontime(ctx.start),
        "stop" => jsontime(ctx.stop))

# What a result is, without its rows: the client asks for a page of those when it
# wants them. Neither `nrow` nor `Tables.schema` scans the frame.
function frameevent(frame::CausalFrame)
    sch = Tables.schema(frame)
    return Dict{String,Any}("rows" => nrow(frame),
        "columns" => [String(n) for n in sch.names],
        "types" => [string(T) for T in sch.types])
end

"""
    Loki.eventjson(e::Loki.Event) -> Dict{String,Any}

An event as the object a client receives: `{"event", "origin", "seq", "time",
"payload"}`.
"""
eventjson(e::Event) = Dict{String,Any}("event" => String(e.kind),
    "origin" => String(e.origin), "seq" => e.seq, "time" => e.time,
    "payload" => e.payload)
