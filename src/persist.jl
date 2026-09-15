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
    end
    return String(path)
end

"""
    Loki.opensession(path; cachebytes = 2^30) -> Session

Read back what [`Loki.savesession`](@ref) wrote. Nodes are added and edges
connected through the session's own commands, so every parameter is checked as it
would be on an edit, and a node the file cannot rebuild is a
[`Loki.NodeError`](@ref) naming it. A file that is not a Loki session, or one
written by a newer Loki, says so.
"""
function opensession(path::AbstractString; cachebytes::Integer = 2^30)
    doc = readsession(path)
    s = Session(; cachebytes)
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

contextjson(ctx::Context{T}) where {T} =
    (; timetype = String(nameof(T)), start = timejson(ctx.start), stop = timejson(ctx.stop))

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
    isempty(names) && return NamedTuple[]
    dir = tabledir(path)
    mkpath(dir)
    return [tableentry(name, savetable(dir, name, s.tables[name]), base) for name in names]
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
