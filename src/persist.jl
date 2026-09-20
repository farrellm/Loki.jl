# Persistence: a session as a `.loki.json` file — the contexts, the prelude, the
# graph, and the tables by path. No data lives in the file itself, and parameters
# hold source text rather than evaluated values, so a session file is as portable
# as the script it exports.
#
# The header is CausalFrames' JLS precedent: a foreign or future file is reported
# as such rather than as a parse failure.

const SESSIONFORMAT = "loki"
const SESSIONVERSION = 1

"""
    Loki.savesession(path, s::Session) -> path

Write the session to `path` as `.loki.json`: its named contexts, its prelude, the
graph's nodes (with their canvas positions) and edges, and its tables, each
snapshotted into a `<stem>.tables/` directory beside the file and referenced by a
relative path (see [`Loki.savetable`](@ref)).

The graph's next id is saved too, so an id freed before saving is not handed out
again after opening. What a node holds is JSON-like already — source text, never
an evaluated value — so the file travels as far as the exported script does.

The session remembers the file afterwards as `s.file`, so a second save
overwrites it without being told where again.
"""
function savesession(path::AbstractString, s::Session)
    lock(s.lock) do
        base = dirname(abspath(path))
        entries = tableentries(s, path, base)
        doc = (; format = SESSIONFORMAT, version = SESSIONVERSION,
            contexts = contextsjson(s.contexts), prelude = s.usercode.prelude,
            nextid = s.graph.nextid, nodes = nodesjson(s.graph),
            edges = edgesjson(s.graph), tables = entries)
        open(io -> JSON3.pretty(io, JSON3.write(doc)), path, "w")
        s.file = abspath(path)
    end
    return String(path)
end

"""
    Loki.opensession(path; cachebytes = 2^30) -> Session

Read back what [`Loki.savesession`](@ref) wrote, as a fresh session. Nodes are
added and edges connected through the session's own commands, so every parameter
is checked as it would be on an edit, and a node the file cannot rebuild is a
[`Loki.NodeError`](@ref) naming it. A file that is not a Loki session, or one
written by a newer Loki, says so.

The session it returns remembers `path` as `s.file`.

[`Loki.opensession!`](@ref) reads one into a session that is already running.
"""
opensession(path::AbstractString; cachebytes::Integer = 2^30) =
    readinto!(Session(; cachebytes), path)

"""
    Loki.opensession!(s::Session, path) -> Session

Read a session file into `s`, replacing its contexts, tables, prelude and graph
— the session object itself is kept, so a REPL binding and a running server go
on pointing at the same session.

The file is read into a throwaway session first, so one the running Loki cannot
rebuild — an unknown node kind, a parameter that no longer validates — leaves
`s` exactly as it was rather than half replaced, `s.file` included. The whole
swap is one `graph_changed` event.
"""
function opensession!(s::Session, path::AbstractString)
    fresh = readinto!(Session(; cachebytes = s.cache.budget), path)
    lock(s.lock) do
        cancel!(s)
        adopt!(s, fresh)
    end
    graphchanged!(s, "open"; path = String(path),
        invalidated = sort!(collect(keys(s.graph.nodes))))
    return s
end

"""
    Loki.reset!(s::Session) -> Session

Empty a session: cancel the run in flight, and drop its graph, contexts, tables,
prelude, cached results and statuses, and forget the file it came from. The
session object survives, which is what lets [`Loki.opensession!`](@ref) replace
what a server is serving.

Broadcast as one `graph_changed`, so a browser watching the session sees it go.
"""
function reset!(s::Session)
    emptied = lock(s.lock) do
        ids = sort!(collect(keys(s.graph.nodes)))
        emptysession!(s)
        ids
    end
    graphchanged!(s, "reset"; invalidated = emptied)
    return s
end

# The emptying itself, without the event: `adopt!` follows it with a fill, and
# the swap is announced once rather than as a clear and then an open.
function emptysession!(s::Session)
    lock(s.lock) do
        cancel!(s)
        s.run = nothing
        empty!(s.graph.nodes)
        empty!(s.graph.order)
        empty!(s.graph.edges)
        s.graph.nextid = 0
        empty!(s.contexts)
        empty!(s.tables)
        empty!(s.status)
        empty!(s.errors)
        cachedrop!(s.cache, _ -> true)
        setprelude!(s.usercode, "")
        s.file = nothing
    end
    return s
end

# Take over everything `fresh` holds. Nothing here can fail — the file was read
# into `fresh` already — so a session is never left half replaced.
function adopt!(s::Session, fresh::Session)
    emptysession!(s)
    merge!(s.contexts, fresh.contexts)
    merge!(s.tables, fresh.tables)
    setprelude!(s.usercode, fresh.usercode.prelude)
    merge!(s.graph.nodes, fresh.graph.nodes)
    append!(s.graph.order, fresh.graph.order)
    append!(s.graph.edges, fresh.graph.edges)
    s.graph.nextid = fresh.graph.nextid
    s.file = fresh.file
    return s
end

# The file, replayed through the session's own commands so every parameter is
# checked as it would be on an edit. Quiet: opening is one event, not one per
# node.
function readinto!(s::Session, path::AbstractString)
    doc = readsession(path)
    was = s.quiet
    s.quiet = true
    try
        setprelude!(s, String(get(doc, :prelude, "")))
        for (name, entry) in pairs(doc.contexts)
            setcontext!(s, String(name), readcontext(entry))
        end
        base = dirname(abspath(path))
        for entry in get(doc, :tables, ())
            addtable!(s, String(entry.name), loadtable(tablefile(entry, base)))
        end
        for node in doc.nodes
            id = String(node.id)
            try
                addnode!(s, String(node.kind), plainjson(node.params);
                    id, position = (node.position[1], node.position[2]))
            catch err
                err isa InterruptException && rethrow()
                throw(tagerror(err, id))
            end
        end
        for edge in doc.edges
            connect!(s, (String(edge.from[1]), Symbol(edge.from[2])),
                (String(edge.to[1]), Symbol(edge.to[2])); id = String(edge.id))
        end
        s.graph.nextid = max(Int(get(doc, :nextid, 0)), s.graph.nextid)
        s.file = abspath(path)
    finally
        s.quiet = was
    end
    return s
end

function readsession(path::AbstractString)
    text = read(path, String)
    doc = try
        JSON3.read(text)
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("$path is not a Loki session file: it is not JSON"))
    end
    (doc isa JSON3.Object && get(doc, :format, nothing) == SESSIONFORMAT) ||
        throw(ArgumentError("$path is not a Loki session file"))
    version = get(doc, :version, nothing)
    version isa Integer ||
        throw(ArgumentError("$path is not a Loki session file: it has no version"))
    version <= SESSIONVERSION || throw(ArgumentError("$path was written by a newer \
        Loki (format version $version); this one reads version $SESSIONVERSION"))
    # The sections `opensession` reads outright. A missing one is a truncated file,
    # not an empty session: `prelude`, `nextid` and `tables` are the optional ones.
    for (name, T) in ((:contexts, JSON3.Object), (:nodes, JSON3.Array),
        (:edges, JSON3.Array))
        get(doc, name, nothing) isa T ||
            throw(ArgumentError("$path is not a Loki session file: it has no $name"))
    end
    return doc
end

# --- the graph as data ----------------------------------------------------------

nodesjson(g::Graph) = [
    (; id = node.id, kind = node.kind, params = node.params,
        position = [node.position[1], node.position[2]])
    for node in (g.nodes[id] for id in g.order)
]

edgesjson(g::Graph) = [
    (; id = e.id, from = [e.from[1], String(e.from[2])],
        to = [e.to[1], String(e.to[2])]) for e in g.edges
]

# Contexts keyed by name, in a fixed order: a session file is meant to be diffed.
function contextsjson(contexts::Dict{String,Context})
    names = sort!(collect(keys(contexts)))
    return NamedTuple{Tuple(Symbol.(names))}(Tuple(contextjson(contexts[n]) for n in names))
end

# The time types `readcontext` knows how to name and rebuild. A context outside
# them is refused at the save rather than written as a file nothing can open.
const CONTEXTTIMES = ("Int64", "Float64", "Date", "DateTime")

function contextjson(ctx::Context{T}) where {T}
    timetype = String(nameof(T))
    timetype in CONTEXTTIMES ||
        throw(ArgumentError("cannot save a context whose time is a $T"))
    return (; timetype, start = timejson(ctx.start), stop = timejson(ctx.stop))
end

timejson(t::Integer) = t
timejson(t::AbstractFloat) = t
timejson(t::Union{Dates.Date,Dates.DateTime}) = string(t)
timejson(t) = throw(ArgumentError("cannot save a context whose time is a $(typeof(t))"))

function readcontext(entry)
    timetype = String(entry.timetype)
    timetype == "Int64" && return Context(Int64(entry.start), Int64(entry.stop))
    timetype == "Float64" && return Context(Float64(entry.start), Float64(entry.stop))
    timetype == "Date" &&
        return Context(Dates.Date(String(entry.start)), Dates.Date(String(entry.stop)))
    timetype == "DateTime" && return Context(Dates.DateTime(String(entry.start)),
        Dates.DateTime(String(entry.stop)))
    return throw(ArgumentError("unsupported context time type $(repr(timetype))"))
end

# --- tables by path --------------------------------------------------------------

function tableentries(s::Session, path::AbstractString, base::AbstractString)
    names = sort!(collect(keys(s.tables)))
    dir = tabledir(path)
    isempty(names) && !isdir(dir) && return NamedTuple[]
    mkpath(dir)
    files = [savetable(dir, name, s.tables[name]) for name in names]
    prunetables(dir, Set(basename(f.path) for f in files))
    return [tableentry(name, file, base) for (name, file) in zip(names, files)]
end

# A `<stem>.tables/` directory is Loki's: a table dropped or renamed since the last
# save, or one whose frame now needs JLS where it needed parquet, leaves a snapshot
# nothing references. Only the two extensions `savetable` writes are swept, so
# anything else in the directory is left alone.
function prunetables(dir::AbstractString, keep::Set{String})
    for name in readdir(dir)
        name in keep && continue
        file = joinpath(dir, name)
        isfile(file) && last(splitext(name)) in (".parquet", ".jls") && rm(file)
    end
    return nothing
end

tableentry(name::AbstractString, file::TableFile, base::AbstractString) =
    (; name = String(name), path = relpath(file.path, base), format = String(file.format),
        frame = file.frame,
        context = file.context === nothing ? nothing : contextjson(file.context))

tablefile(entry, base::AbstractString) =
    TableFile(joinpath(base, String(entry.path)), Symbol(entry.format), entry.frame,
        entry.frame ? readcontext(entry.context) : nothing)

# `analysis.loki.json` keeps its tables in `analysis.tables/`.
function tabledir(path::AbstractString)
    name = String(path)
    for suffix in (".loki.json", ".json")
        endswith(name, suffix) && return chop(name; tail = length(suffix)) * ".tables"
    end
    return name * ".tables"
end

# JSON3's views are read-only and typed by the document; a node's parameters are
# ordinary values again before they reach `validateparams`.
plainjson(x::JSON3.Object) = Dict{String,Any}(String(k) => plainjson(v) for (k, v) in x)
plainjson(x::JSON3.Array) = Any[plainjson(v) for v in x]
plainjson(x::AbstractString) = String(x)
plainjson(x) = x
