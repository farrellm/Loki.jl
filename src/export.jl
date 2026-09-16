# Printing a graph as Julia source. Each node kind emits the expressions that
# reproduce its `build` (see `Loki.emit`), and this printer turns them into text.
#
# The printer is Loki's own rather than `string(::Expr)` because the output is a
# script a user reads, diffs and keeps under version control: it prints the
# small subset the kinds emit — calls with keywords, `|>` chains, bindings,
# tuples, vectors and symbols — in one stable spelling, and passes source-text
# parameters through exactly as they were typed.

"""
    Loki.Code(text)

Julia source text inside an emitted expression: a row function, an interval, a
model. It is printed **verbatim**, so an exported script says exactly what the
user typed, parenthesized only where the text would not parse as one argument.
Source text is what a node stores (see [`Loki.evalcode`](@ref)), so there is no
expression to splice.
"""
struct Code
    text::String
end

Code(text::AbstractString) = Code(String(text))
Code(x::Real) = Code(repr(x))

Base.:(==)(a::Code, b::Code) = a.text == b.text
Base.hash(c::Code, h::UInt) = hash(c.text, hash(:Code, h))

"""
    Loki.exprstring(x) -> String

The emitted expression `x` as script text; see [`Loki.emit`](@ref).
"""
function exprstring(x)
    io = IOBuffer()
    printexpr(io, x)
    return String(take!(io))
end

# --- the printer ---------------------------------------------------------------

printexpr(io::IO, s::Symbol) = print(io, s)
printexpr(io::IO, q::QuoteNode) = printsymbol(io, q.value)
printexpr(io::IO, ::Nothing) = print(io, "nothing")
printexpr(io::IO, s::AbstractString) = print(io, repr(String(s)))
printexpr(io::IO, b::Bool) = print(io, b)
printexpr(io::IO, n::Integer) = print(io, n)
printexpr(io::IO, x::AbstractFloat) = print(io, repr(x))

function printexpr(io::IO, c::Code)
    parens = needsparens(c)
    parens && print(io, "(")
    print(io, c.text)
    return parens && print(io, ")")
end

# A symbol as a literal: `:x`, or `Symbol("#x_difflag")` for the private names
# operators give their intermediate columns, which `:` cannot spell.
printsymbol(io::IO, s::Symbol) =
    Base.isidentifier(s) ? print(io, ":", s) : print(io, "Symbol(", repr(String(s)), ")")
printsymbol(io::IO, x) = printexpr(io, x)

# A field of a module or a named tuple — `tables.prices`, `Loki.fitinput` — where
# the name is written plainly rather than as a symbol literal.
printfield(io::IO, s::Symbol) =
    Base.isidentifier(s) ? print(io, s) : print(io, "var", repr(String(s)))
printfield(io::IO, x) = printexpr(io, x)

const INFIX = (:(|>), :(=>))

function printexpr(io::IO, e::Expr)
    h = e.head
    h === :call && return printcall(io, e)
    if h === :kw || h === :(=)
        printexpr(io, e.args[1])
        print(io, " = ")
        return printexpr(io, e.args[2])
    end
    h === :tuple && return printtuple(io, e.args)
    if h === :vect
        print(io, "[")
        printargs(io, e.args)
        return print(io, "]")
    end
    if h === :.
        printexpr(io, e.args[1])
        print(io, ".")
        return printfield(io, unquote(e.args[2]))
    end
    return throw(ArgumentError("cannot print a $(repr(h)) expression: $e"))
end

unquote(q::QuoteNode) = q.value
unquote(x) = x

function printcall(io::IO, e::Expr)
    f = e.args[1]
    rest = e.args[2:end]
    positional, keywords = splitargs(rest)
    if f in INFIX && length(positional) == 2 && isempty(keywords)
        printexpr(io, positional[1])
        print(io, " ", f, " ")
        return printexpr(io, positional[2])
    end
    printexpr(io, f)
    print(io, "(")
    printargs(io, positional)
    if !isempty(keywords)
        print(io, "; ")
        printargs(io, keywords)
    end
    return print(io, ")")
end

# Keywords reach the printer either as an `Expr(:parameters, …)` (what `:(f(; k
# = v))` builds) or as trailing `Expr(:kw, …)` args (what interpolation builds).
function splitargs(args)
    positional = Any[]
    keywords = Any[]
    for a in args
        if a isa Expr && a.head === :parameters
            append!(keywords, a.args)
        elseif a isa Expr && a.head === :kw
            push!(keywords, a)
        else
            push!(positional, a)
        end
    end
    return positional, keywords
end

function printargs(io::IO, args)
    for (i, a) in enumerate(args)
        i == 1 || print(io, ", ")
        printexpr(io, a)
    end
    return nothing
end

function printtuple(io::IO, args)
    named = !isempty(args) && all(a -> a isa Expr && a.head in (:kw, :(=)), args)
    print(io, named ? "(; " : "(")
    printargs(io, args)
    # `(x,)` is a one-element tuple; `(x)` is just `x`.
    length(args) == 1 && !named && print(io, ",")
    return print(io, ")")
end

# Source text is parenthesized unless it parses as something that stands alone as
# one argument. A row function does (`f(r -> r.x, 2)` passes two arguments); a
# block or an assignment does not (`f(x = 1)` would be a keyword).
const BAREHEADS = (:call, :ref, :curly, :., :vect, :tuple, :string, :macrocall, :->, :&&,
    :||, :comparison, :if)

function needsparens(c::Code)
    expr = try
        Meta.parse(c.text)
    catch
        return true
    end
    expr isa Expr || return false
    return !(expr.head in BAREHEADS)
end

# --- exporting a session ------------------------------------------------------

"""
    exportjulia(session; tables = :argument, targets = nothing, context = "analysis")
        -> String
    exportjulia(path, session; tables = :snapshot, …) -> path

The session's graph as a plain Julia script that runs without Loki's server: the
imports the session's user module has, the prelude verbatim, the named contexts
as `const` bindings, one binding per node output in topological order, and a
`load` of each target over the named context. The second method writes the script
to `path`.

`targets` are node ids or `(id, port)` pairs, as [`Loki.run!`](@ref) takes them;
by default the last run's targets, or every output port nothing else reads. A
node's binding is `p_<id>`, or `p_<id>_<port>` for a node with several outputs,
and a loaded frame's is `frame_<id>[_<port>]` — so including the script and
comparing those frames against the session's is what "the export is correct"
means.

The script holds what the targets need, as a run compiles them, and not the rest
of the graph: a node the targets do not reach is left out, and cannot fail the
export by being half wired. Exporting every sink — the default with no run — does
reach such a node, and says so. A session file keeps the whole graph either way
(see [`Loki.savesession`](@ref)).

`tables` says where the session's in-memory tables come from:

- `:snapshot` writes each one beside the script (see [`Loki.savetable`](@ref))
  and defines `tables` to read them back;
- `:argument` leaves `tables` to the caller, who supplies a `NamedTuple` with a
  field per table the script reads.

A write node hanging off the exported pipelines keeps its binding, but nothing
downstream reads it and no target loads it — a run passes a write node's input
through, and including a script must not write files. The commented `scan` line
at the foot is how to run one.
"""
function exportjulia(s::Session; tables::Symbol = :argument, targets = nothing,
    context::AbstractString = "analysis", dir::Union{Nothing,AbstractString} = nothing)
    tables in (:argument, :snapshot) ||
        throw(ArgumentError("tables must be :argument or :snapshot, got $(repr(tables))"))
    tables === :snapshot && dir === nothing &&
        throw(
            ArgumentError("a table snapshot needs a directory to write into: \
            exportjulia(path, session)"))
    return lock(s.lock) do
        scripttext(s, tables, targets, String(context), dir)
    end
end

function exportjulia(path::AbstractString, s::Session; tables::Symbol = :snapshot,
    kwargs...)
    text = exportjulia(s; tables, dir = dirname(abspath(path)), kwargs...)
    write(path, text)
    return String(path)
end

const SCRIPTHEADER = "# Exported from a Loki session."

function scripttext(s::Session, tablemode::Symbol, targets, ctxname::String, dir)
    haskey(s.contexts, ctxname) ||
        throw(ArgumentError("the session has no context $(repr(ctxname))"))
    wanted = targets === nothing ? defaulttargets(s) : totargets(s, targets)
    keep = exportnodes(s.graph, wanted)
    bindings, body, calls, writes = bindinglines(s, wanted, keep)
    names = tablenames(s.graph, keep)
    snapshots = Dict{String,TableFile}()
    if tablemode === :snapshot
        for name in names
            snapshots[name] = savetable(dir, name, namedtable(buildenv(s), name))
        end
    end
    sections = [
        [SCRIPTHEADER; importlines(calls, snapshots)],
        preludelines(s),
        contextlines(s),
        tablelines(names, tablemode, snapshots),
        body,
        loadlines(s, wanted, bindings, ctxname, writes),
    ]
    return join([join(sec, "\n") for sec in sections if !isempty(sec)], "\n\n") * "\n"
end

# The ports a script ends by loading: the last run's, or every output nothing
# reads. A write node's output is never one of them.
function defaulttargets(s::Session)
    run = s.run
    if run !== nothing && !isempty(run.targets) &&
       all(t -> haskey(s.graph.nodes, t[1]), run.targets)
        return collect(run.targets)
    end
    g = s.graph
    wanted = Tuple{String,Symbol}[]
    for id in topoorder(g)
        kind = nodekind(g.nodes[id].kind)
        iswrite(kind) && continue
        for port in outputs(kind)
            any(e -> e.from == (id, port), g.edges) || push!(wanted, (id, port))
        end
    end
    return wanted
end

# The nodes a script holds: what the targets need, as a run compiles them, plus
# the write nodes hanging off that much of the graph. A write is an endpoint no
# target loads, but the script still shows it and the commented `scan` line that
# runs it; one fed by nothing, or by a node this leaves out, is left out too.
function exportnodes(g::Graph, wanted)
    keep = Set{String}(id for (id, _) in wanted)
    for (id, _) in wanted
        union!(keep, ancestors(g, id))
    end
    for id in topoorder(g)
        iswrite(nodekind(g.nodes[id].kind)) || continue
        up = ancestors(g, id)
        isempty(up) || !issubset(up, keep) || push!(keep, id)
    end
    return keep
end

# One binding per node output that something reads or loads, in topological
# order, with each node's errors attributed to it as a run's are. Only the nodes
# in `keep` are emitted, so a node the targets do not reach cannot fail the
# export any more than it fails a run.
function bindinglines(s::Session, wanted, keep)
    g = s.graph
    bindings = Dict{Tuple{String,Symbol},Symbol}()
    lines = String[]
    calls = Set{Symbol}()
    writes = Tuple{String,Symbol}[]
    for id in topoorder(g)
        id in keep || continue
        node = g.nodes[id]
        kind = nodekind(node.kind)
        ins = Dict{Symbol,Any}()
        for port in inputs(kind)
            fed = [
                inputbinding(bindings, g, e.from)
                for e in inedges(g, id) if e.to[2] === port.name
            ]
            ins[port.name] = if port.variadic
                fed
            elseif isempty(fed)
                port.optional || throw(
                    NodeError(id,
                        ArgumentError("input port $(port.name) is not connected")),
                )
                nothing
            else
                only(fed)
            end
        end
        emitted = try
            emit(kind, node.params, ins)
        catch err
            err isa InterruptException && rethrow()
            throw(tagerror(err, id))
        end
        iswrite(kind) && push!(writes, (id, first(outputs(kind))))
        for port in outputs(kind)
            iswrite(kind) || (id, port) in wanted ||
                any(e -> e.from == (id, port), g.edges) || continue
            name = bindingname(g, id, port)
            bindings[(id, port)] = name
            collectcalls!(calls, emitted[port])
            push!(lines, exprstring(Expr(:(=), name, emitted[port])))
        end
    end
    return bindings, lines, calls, writes
end

# A run compiles a write node as a pass-through of its input, so what a consumer
# reads is that input's binding, not the one that writes the file.
function inputbinding(bindings, g::Graph, from::Tuple{String,Symbol})
    id, port = from
    kind = nodekind(g.nodes[id].kind)
    if iswrite(kind)
        through = first(inputs(kind)).name
        i = findfirst(e -> e.to == (id, through), g.edges)
        i === nothing && throw(NodeError(id,
            ArgumentError("input port $through is not connected")))
        return inputbinding(bindings, g, g.edges[i].from)
    end
    return bindings[(id, port)]
end

# A node with one output is named by its id alone; one with several carries the
# port too.
portsuffix(g::Graph, id::AbstractString, port::Symbol) =
    length(outputs(nodekind(g.nodes[id].kind))) == 1 ? nothing : port

bindingname(g::Graph, id::AbstractString, port::Symbol) =
    scriptname("p_", id, portsuffix(g, id, port))

framename(g::Graph, id::AbstractString, port::Symbol) =
    scriptname("frame_", id, portsuffix(g, id, port))

function scriptname(prefix::String, id::AbstractString, port)
    name = port === nothing ? Symbol(prefix, id) : Symbol(prefix, id, "_", port)
    Base.isidentifier(name) ||
        throw(ArgumentError("node id $(repr(id)) does not make a Julia identifier, \
            so it cannot be exported"))
    return name
end

collectcalls!(names::Set{Symbol}, x) = names
function collectcalls!(names::Set{Symbol}, e::Expr)
    e.head === :call && e.args[1] isa Symbol && push!(names, e.args[1])
    for a in e.args
        collectcalls!(names, a)
    end
    return names
end

# The acausal names a script calls are imported by name, which is where the
# dependence on looking ahead is meant to be visible.
const ACAUSALNAMES = (("Loki.Acausal", (:insample,)),
    ("CausalFrames.Acausal", (:lead, :futurejoin)))

function importlines(calls::Set{Symbol}, snapshots)
    lines = ["using CausalFrames, Loki, Dates, Statistics"]
    extras = String[]
    (:readparquet in calls || :writeparquet in calls) &&
        append!(extras, ["DuckDB", "Parquet2"])
    files = collect(values(snapshots))
    any(f -> f.format === :parquet, files) && push!(extras, "Parquet2")
    any(f -> f.format === :parquet && !f.frame, files) && push!(extras, "DataFrames")
    isempty(extras) || push!(lines, "using " * join(sort!(unique!(extras)), ", "))
    for (mod, names) in ACAUSALNAMES
        used = [String(n) for n in names if n in calls]
        isempty(used) || push!(lines, "using $mod: " * join(used, ", "))
    end
    return lines
end

preludelines(s::Session) =
    isempty(strip(s.usercode.prelude)) ? String[] : [strip(s.usercode.prelude)]

function contextlines(s::Session)
    lines = String[]
    for name in sort!(collect(keys(s.contexts)))
        Base.isidentifier(name) ||
            throw(ArgumentError("context name $(repr(name)) is not a Julia identifier, \
                so it cannot be exported"))
        push!(lines, "const $name = " * exprstring(contextexpr(s.contexts[name])))
    end
    return lines
end

contextexpr(ctx::Context) = Expr(:call, :Context, timeexpr(ctx.start), timeexpr(ctx.stop))

timeexpr(t::Integer) = t
timeexpr(t::AbstractFloat) = t
timeexpr(t::Dates.Date) =
    Expr(:call, :Date, Dates.year(t), Dates.month(t), Dates.day(t))
function timeexpr(t::Dates.DateTime)
    parts = Any[Dates.year(t), Dates.month(t), Dates.day(t), Dates.hour(t),
        Dates.minute(t), Dates.second(t), Dates.millisecond(t)]
    while length(parts) > 3 && last(parts) == 0
        pop!(parts)
    end
    return Expr(:call, :DateTime, parts...)
end
timeexpr(t) =
    throw(ArgumentError("cannot export a context whose time is a $(typeof(t))"))

# The tables the exported nodes name, in the order they name them: a table only a
# left-out node reads is neither declared nor snapshotted.
function tablenames(g::Graph, keep)
    names = String[]
    for id in topoorder(g)
        id in keep || continue
        node = g.nodes[id]
        kind = nodekind(node.kind)
        kind isa OpKind || continue
        for spec in kind.params
            spec.type === :table || continue
            name = get(node.params, spec.name, nothing)
            name isa AbstractString && !(name in names) && push!(names, String(name))
        end
    end
    return names
end

function tablelines(names, tablemode::Symbol, snapshots)
    isempty(names) && return String[]
    for name in names
        Base.isidentifier(name) ||
            throw(ArgumentError("table name $(repr(name)) is not a Julia identifier, \
                so it cannot be exported"))
    end
    tablemode === :snapshot || return [
        "# `tables`: supplied by the caller, with a field per table — " *
        join(names, ", "),
    ]
    # One field per line: a snapshot's expression carries a path, and a row of
    # them on one line is neither readable nor diffable.
    lines = ["const SCRIPTDIR = @__DIR__", "tables = (;"]
    for name in names
        push!(lines, "    $name = " * exprstring(tableexpr(snapshots[name])) * ",")
    end
    push!(lines, ")")
    return lines
end

function loadlines(s::Session, wanted, bindings, ctxname::String, writes)
    g = s.graph
    lines = String[]
    for (id, port) in wanted
        haskey(bindings, (id, port)) || continue
        # A run watching a write node passes its input through, so the port can be
        # one of the run's targets; loading it here would write the file instead.
        iswrite(nodekind(g.nodes[id].kind)) && continue
        push!(lines,
            exprstring(
                Expr(:(=), framename(g, id, port),
                    Expr(:call, :load, Symbol(ctxname), bindings[(id, port)])),
            ))
    end
    for (id, port) in writes
        push!(lines, "# scan($ctxname, $(bindings[(id, port)]))  # runs the write")
    end
    return lines
end
