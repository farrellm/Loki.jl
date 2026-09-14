# The analysis graph: nodes with stable string ids, and edges from an output port
# to an input port. Every port carries a CausalPipeline, so the only check an edge
# needs beyond port existence is arity — and that it closes no cycle. Positions
# are stored for the canvas and play no part in evaluation.

"""
    Loki.Node

A graph node: a stable `id`, the name of its registered `kind`, its `params`
(JSON-like values, with Julia source text for expressions — see
[`Loki.Param`](@ref)), and a canvas `position` that plays no part in evaluation.
"""
mutable struct Node
    const id::String
    const kind::String
    params::Dict{String,Any}
    position::Tuple{Float64,Float64}
end

"""
    Loki.Edge

An edge `id` from the output port `from = (node id, port)` to the input port
`to = (node id, port)`.
"""
struct Edge
    id::String
    from::Tuple{String,Symbol}
    to::Tuple{String,Symbol}
end

"""
    Loki.Graph()

A directed acyclic graph of [`Loki.Node`](@ref)s and [`Loki.Edge`](@ref)s, edited
with [`Loki.addnode!`](@ref), [`Loki.setparams!`](@ref),
[`Loki.removenode!`](@ref), [`Loki.connect!`](@ref) and
[`Loki.disconnect!`](@ref). Every edit is checked where it is made: the kind and
parameters when a node is added or edited, ports, arity and acyclicity when an
edge is connected.
"""
mutable struct Graph
    const nodes::Dict{String,Node}
    const order::Vector{String}  # insertion order, for stable listings
    const edges::Vector{Edge}    # connection order, which orders a variadic port
    nextid::Int
end
Graph() = Graph(Dict{String,Node}(), String[], Edge[], 0)

function freshid!(g::Graph, prefix::String)
    while true
        g.nextid += 1
        id = string(prefix, g.nextid)
        haskey(g.nodes, id) || any(e -> e.id == id, g.edges) || return id
    end
end

function getnode(g::Graph, id::AbstractString)
    node = get(g.nodes, String(id), nothing)
    node === nothing && throw(ArgumentError("no node $(repr(id)) in the graph"))
    return node
end

"""
    Loki.addnode!(g::Graph, kind::AbstractString, params = Dict(); id = nothing,
                  position = (0, 0)) -> String

Add a node of the registered `kind` and return its id — `id` if given (it must be
unused), otherwise a fresh `"n…"`. `params` are checked against the kind's
parameters.
"""
function addnode!(g::Graph, kind::AbstractString, params::AbstractDict = Dict{String,Any}();
    id::Union{Nothing,AbstractString} = nothing, position = (0.0, 0.0))
    k = nodekind(kind)
    stored = stringkeys(params)
    validateparams(k, stored)
    if id !== nothing && (haskey(g.nodes, id) || any(e -> e.id == id, g.edges))
        throw(ArgumentError("id $(repr(id)) is already in use"))
    end
    nid = id === nothing ? freshid!(g, "n") : String(id)
    g.nodes[nid] = Node(nid, String(kind), stored, Tuple{Float64,Float64}(position))
    push!(g.order, nid)
    return nid
end

"""
    Loki.setparams!(g::Graph, id, params) -> Node

Replace a node's parameters, checked against its kind's.
"""
function setparams!(g::Graph, id::AbstractString, params::AbstractDict)
    node = getnode(g, id)
    stored = stringkeys(params)
    validateparams(nodekind(node.kind), stored)
    node.params = stored
    return node
end

"""
    Loki.setposition!(g::Graph, id, position) -> Node

Move a node on the canvas.
"""
function setposition!(g::Graph, id::AbstractString, position)
    node = getnode(g, id)
    node.position = Tuple{Float64,Float64}(position)
    return node
end

"""
    Loki.removenode!(g::Graph, id) -> Graph

Remove a node and every edge touching it.
"""
function removenode!(g::Graph, id::AbstractString)
    node = getnode(g, id)
    filter!(e -> e.from[1] != node.id && e.to[1] != node.id, g.edges)
    delete!(g.nodes, node.id)
    filter!(!=(node.id), g.order)
    return g
end

"""
    Loki.connect!(g::Graph, from, to; id = nothing) -> String

Connect the output port `from = (node id, port)` to the input port
`to = (node id, port)` and return the edge's id. An `ArgumentError` if either port
does not exist, if `to` is a single port that is already connected, or if the edge
would close a cycle.
"""
function connect!(g::Graph, from, to; id::Union{Nothing,AbstractString} = nothing)
    fid, fport = String(from[1]), Symbol(from[2])
    tid, tport = String(to[1]), Symbol(to[2])
    fnode, tnode = getnode(g, fid), getnode(g, tid)
    fport in outputs(nodekind(fnode.kind)) ||
        throw(ArgumentError("node $fid ($(fnode.kind)) has no output port $fport"))
    ports = inputs(nodekind(tnode.kind))
    i = findfirst(p -> p.name === tport, ports)
    i === nothing &&
        throw(ArgumentError("node $tid ($(tnode.kind)) has no input port $tport"))
    ports[i].variadic || !any(e -> e.to == (tid, tport), g.edges) ||
        throw(ArgumentError("input port $tport of node $tid is already connected"))
    (fid == tid || fid in descendants(g, tid)) &&
        throw(ArgumentError("connecting $fid to $tid would close a cycle"))
    if id !== nothing && (haskey(g.nodes, id) || any(e -> e.id == id, g.edges))
        throw(ArgumentError("id $(repr(id)) is already in use"))
    end
    eid = id === nothing ? freshid!(g, "e") : String(id)
    push!(g.edges, Edge(eid, (fid, fport), (tid, tport)))
    return eid
end

"""
    Loki.disconnect!(g::Graph, id) -> Graph

Remove the edge `id`.
"""
function disconnect!(g::Graph, id::AbstractString)
    i = findfirst(e -> e.id == id, g.edges)
    i === nothing && throw(ArgumentError("no edge $(repr(id)) in the graph"))
    deleteat!(g.edges, i)
    return g
end

"""
    Loki.inedges(g::Graph, id) -> Vector{Edge}
    Loki.outedges(g::Graph, id) -> Vector{Edge}

The edges into or out of a node, in connection order.
"""
inedges(g::Graph, id::AbstractString) = filter(e -> e.to[1] == id, g.edges)
outedges(g::Graph, id::AbstractString) = filter(e -> e.from[1] == id, g.edges)

"""
    Loki.ancestors(g::Graph, id) -> Set{String}
    Loki.descendants(g::Graph, id) -> Set{String}

Every node upstream or downstream of a node, not including itself.
"""
ancestors(g::Graph, id::AbstractString) = reachable(g, String(id), e -> e.to, e -> e.from)
descendants(g::Graph, id::AbstractString) =
    reachable(g, String(id), e -> e.from, e -> e.to)

function reachable(g::Graph, id::String, near, far)
    seen = Set{String}()
    stack = [id]
    while !isempty(stack)
        current = pop!(stack)
        for e in g.edges
            near(e)[1] == current || continue
            next = far(e)[1]
            next in seen || (push!(seen, next); push!(stack, next))
        end
    end
    return seen
end

"""
    Loki.topoorder(g::Graph) -> Vector{String}

The node ids in topological order — every node after all of its inputs — with
ties broken by insertion order.
"""
function topoorder(g::Graph)
    indegree = Dict(id => 0 for id in g.order)
    for e in g.edges
        indegree[e.to[1]] += 1
    end
    ready = [id for id in g.order if indegree[id] == 0]
    order = String[]
    while !isempty(ready)
        id = popfirst!(ready)
        push!(order, id)
        for e in g.edges
            e.from[1] == id || continue
            indegree[e.to[1]] -= 1
            indegree[e.to[1]] == 0 && push!(ready, e.to[1])
        end
    end
    return order
end

"""
    Loki.taint(g::Graph) -> Dict{Tuple{String,Symbol},Bool}

For every output port `(node id, port)`, whether it depends on looking ahead in
time: the port is acausal itself ([`Loki.isacausal`](@ref)), or some input of its
node is fed by a tainted port. Taint is information, not a restriction.
"""
function taint(g::Graph)
    tainted = Dict{Tuple{String,Symbol},Bool}()
    for id in topoorder(g)
        node = g.nodes[id]
        kind = nodekind(node.kind)
        upstream = any(e -> tainted[e.from], inedges(g, id))
        for port in outputs(kind)
            tainted[(id, port)] = upstream || isacausal(kind, node.params, port)
        end
    end
    return tainted
end
