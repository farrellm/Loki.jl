# Compiling a graph: building each node's output pipelines from its inputs'
# pipelines, with every error attributed to the node that raised it, and with
# cached results substituted for the nodes that have them.

"""
    Loki.NodeError(id, exception)

An error raised while building or running node `id`, wrapping the original
`exception`. Runs record it on the failing node, and nodes downstream of it are
blocked.
"""
struct NodeError <: Exception
    id::String
    exception::Any
end

function Base.showerror(io::IO, e::NodeError)
    print(io, "NodeError: node ", e.id, ": ")
    return showerror(io, e.exception)
end

tagerror(err::NodeError, ::String) = err
tagerror(err, id::String) = NodeError(id, err)

"""
    Loki.tagged(p::CausalPipeline, id) -> CausalPipeline

The pipeline `p`, with every exception raised while running it — by its `run` or
while iterating its chunks — rethrown as a [`Loki.NodeError`](@ref) for `id`,
unless it already is one. Tags nest, and the innermost wins, so an error deep in a
lazy iterator lands on the node that actually failed.
"""
function tagged(p::CausalPipeline, id::AbstractString)
    nid = String(id)
    return CausalPipeline() do ctx::Context
        chunks = try
            p.run(ctx)
        catch err
            err isa InterruptException && rethrow()
            throw(tagerror(err, nid))
        end
        return TaggedChunks(chunks, nid)
    end
end

struct TaggedChunks{I}
    inner::I
    id::String
end

Base.IteratorSize(::Type{<:TaggedChunks}) = Base.SizeUnknown()
Base.eltype(::Type{TaggedChunks{I}}) where {I} = eltype(I)

function Base.iterate(t::TaggedChunks, state...)
    try
        return iterate(t.inner, state...)
    catch err
        err isa InterruptException && rethrow()
        throw(tagerror(err, t.id))
    end
end

"""
    Loki.cachedsource(frame::CausalFrame, fallback::CausalPipeline) -> CausalPipeline

A pipeline serving `frame` — through `readtable`, sharing its chunks — when run
over exactly `context(frame)`, and running `fallback` over any other context.
Equality is the test: a wider context is one the frame knows nothing about, and a
narrower one would be wrong for any stateful pipeline, whose result over a
sub-context differs from a slice of its result.
"""
function cachedsource(frame::CausalFrame, fallback::CausalPipeline)
    return CausalPipeline() do ctx::Context
        return ctx == context(frame) ? readtable(frame).run(ctx) : fallback.run(ctx)
    end
end

# One compilation of a session's graph over a context: the upstream hash of every
# node, the outputs built so far, and the write nodes allowed to write (all
# others pass their input through).
struct Compilation
    graph::Graph
    env::BuildEnv
    context::Context
    hashes::Dict{String,UInt}
    cache::Any                      # ResultCache (engine.jl)
    outputs::Dict{String,NamedTuple}
    writes::Set{String}
end

# Each node's upstream hash covers its kind, its parameters, the prelude, what its
# parameters name (a table's identity, a context's value) and, in input order, the
# hashes of the ports feeding it — so an edit changes exactly the node and its
# descendants.
function nodehashes(g::Graph, env::BuildEnv)
    hashes = Dict{String,UInt}()
    base = hash(env.usercode.prelude)
    for id in topoorder(g)
        node = g.nodes[id]
        kind = nodekind(node.kind)
        h = referencehash(kind, node.params, env, hash(node.kind, hash(node.params, base)))
        for e in inedges(g, id)
            h = hash((e.from[2], e.to[2], hashes[e.from[1]]), h)
        end
        hashes[id] = h
    end
    return hashes
end

referencehash(::NodeKind, params, env::BuildEnv, h::UInt) = h
function referencehash(kind::OpKind, params, env::BuildEnv, h::UInt)
    for spec in kind.params
        name = get(params, spec.name, nothing)
        name isa AbstractString || continue
        if spec.type === :table && haskey(env.tables, name)
            h = hash(objectid(env.tables[name]), h)
        elseif spec.type === :context && haskey(env.contexts, name)
            h = hash(env.contexts[name], h)
        end
    end
    return h
end

# The node's output pipelines, tagged with its id, each replaced by a cached source
# where the cache holds its result over the compilation's context.
function compilenode!(c::Compilation, id::String)
    haskey(c.outputs, id) && return c.outputs[id]
    node = getnode(c.graph, id)
    kind = nodekind(node.kind)
    ins = Dict{Symbol,Any}()
    for port in inputs(kind)
        pipes = CausalPipeline[
            getproperty(compilenode!(c, e.from[1]), e.from[2])
            for e in inedges(c.graph, id) if e.to[2] === port.name
        ]
        ins[port.name] = if port.variadic
            pipes
        elseif isempty(pipes)
            port.optional || throw(
                NodeError(id,
                    ArgumentError("input port $(port.name) is not connected")),
            )
            nothing
        else
            only(pipes)
        end
    end
    built = if iswrite(kind) && !(id in c.writes)
        # Watching never writes: a write node not asked to passes its input on.
        NamedTuple{Tuple(outputs(kind))}(ntuple(_ -> ins[:in], length(outputs(kind))))
    else
        try
            build(kind, node.params, ins, c.env)
        catch err
            err isa InterruptException && rethrow()
            throw(tagerror(err, id))
        end
    end
    h = c.hashes[id]
    outs = map(keys(built)) do port
        p = tagged(built[port], id)
        # A write node asked to write must run: its cached result is the passthrough
        # a watching run stored under the same key, and serving it writes nothing.
        frame = id in c.writes ? nothing : cacheget(c.cache, (id, port, h, c.context))
        frame === nothing ? p : cachedsource(frame, p)
    end
    return c.outputs[id] = NamedTuple{keys(built)}(outs)
end

function compileport!(c::Compilation, id::String, port::Symbol)
    outs = compilenode!(c, id)
    port in keys(outs) || throw(ArgumentError("node $id has no output port $port"))
    return getproperty(outs, port)
end
