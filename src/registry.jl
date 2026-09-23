# The node-kind registry: what a graph node can be. A kind declares its ports, its
# parameters — as specs, from which the JSON Schema shared by the web inspector
# and the MCP tools is generated — how to build its output pipelines from its
# inputs, and which of its outputs are acausal.

"""
    Loki.NodeKind

The supertype of node kinds. A kind implements [`Loki.inputs`](@ref),
[`Loki.outputs`](@ref), [`Loki.paramschema`](@ref) and [`Loki.build`](@ref), and
optionally [`Loki.validateparams`](@ref), [`Loki.isacausal`](@ref) and
[`Loki.iswrite`](@ref); [`Loki.register_nodekind!`](@ref) makes it available to
graphs. Most kinds are [`Loki.OpKind`](@ref)s.
"""
abstract type NodeKind end

"""
    Loki.Port(name::Symbol; variadic = false, optional = false)

An input port of a node kind. A `variadic` port takes any number of edges and
hands them to `build` in connection order (`merge`'s inputs); an `optional` one
may be left unconnected. Every other port takes exactly one edge.
"""
struct Port
    name::Symbol
    variadic::Bool
    optional::Bool
end
Port(name::Symbol; variadic::Bool = false, optional::Bool = false) =
    Port(name, variadic, optional)

const PARAMTYPES = (:string, :integer, :number, :boolean, :enum, :integers, :column,
    :columns, :code, :context, :table, :summarizers, :path)

"""
    Loki.Param(name, type::Symbol; required = false, default = nothing,
               description = "", choices = String[], suffixes = String[])

A node kind's parameter. Parameter values are JSON-like, so a graph saves and
travels as data; `type` is one of:

| `type` | Value |
|---|---|
| `:string`, `:integer`, `:number`, `:boolean` | as named |
| `:enum` | one of `choices` |
| `:integers` | a vector of integers |
| `:column` | a column name |
| `:columns` | a column name or a vector of them |
| `:code` | Julia source text (or a number), evaluated in the session's user module |
| `:context` | the name of a session context |
| `:table` | the name of a session table |
| `:summarizers` | a vector of `{"summarizer", "columns", "options"}` dictionaries |
| `:path` | a file path on the machine Loki runs on; `suffixes` names the files the browser's picker offers |

An unset optional parameter takes `default`.
"""
struct Param
    name::String
    type::Symbol
    required::Bool
    default::Any
    description::String
    choices::Vector{String}
    suffixes::Vector{String}
end

function Param(name::AbstractString, type::Symbol; required::Bool = false,
    default = nothing, description::AbstractString = "", choices = String[],
    suffixes = String[])
    type in PARAMTYPES || throw(ArgumentError("unknown parameter type $(repr(type))"))
    type === :enum && isempty(choices) &&
        throw(ArgumentError("enum parameter $name needs choices"))
    type === :path || isempty(suffixes) ||
        throw(ArgumentError("only a path parameter takes suffixes, and $name is $type"))
    return Param(String(name), type, required, default, String(description),
        collect(String, choices), collect(String, suffixes))
end

"""
    Loki.inputs(kind::NodeKind) -> Vector{Loki.Port}

The kind's input ports.
"""
function inputs end

"""
    Loki.outputs(kind::NodeKind) -> Vector{Symbol}

The kind's output port names; every output carries a `CausalPipeline`.
"""
function outputs end

"""
    Loki.paramschema(kind::NodeKind) -> Dict{String,Any}

A JSON Schema for the kind's parameters: rendered as a form by the web inspector
and published as a tool's input schema by the MCP server, so the user and an agent
edit the same vocabulary.
"""
function paramschema end

"""
    Loki.build(kind::NodeKind, params::Dict{String,Any}, inputs::Dict{Symbol,Any}, env)
        -> NamedTuple

Build the kind's output pipelines, one per output port, from its parameters and
its input pipelines: `inputs[port]` is a `CausalPipeline` for a single port, a
vector of them for a variadic one, and `nothing` for an unconnected optional one.
`env` resolves what parameters refer to by name (contexts, tables, user code).
`build` calls the real operator constructors, so a bad parameter raises here.
"""
function build end

"""
    Loki.emit(kind::NodeKind, params::Dict{String,Any}, inputs::Dict{Symbol,Any})
        -> NamedTuple

The script expressions reproducing [`Loki.build`](@ref), one per output port —
the same shape `build` returns, with an `Expr` in place of each
`CausalPipeline`. `inputs[port]` is the `Symbol` a connected input is bound to
in the script, a vector of them for a variadic port, and `nothing` for an
unconnected optional one; source-text parameters travel as [`Loki.Code`](@ref).
A kind that does not implement `emit` cannot be exported.
"""
function emit end

"""
    Loki.validateparams(kind::NodeKind, params::AbstractDict) -> Dict{String,Any}

Check `params` against the kind's parameters, raising an `ArgumentError` for an
unknown, missing or mistyped one, and return them with defaults filled in. This
is what [`Loki.build`](@ref) and [`Loki.emit`](@ref) use, so a node is complete
by the time it is built.

[`Loki.checkparams`](@ref) is the weaker check a graph edit makes.
"""
validateparams(::NodeKind, params::AbstractDict) = stringkeys(params)

"""
    Loki.checkparams(kind::NodeKind, params::AbstractDict) -> Dict{String,Any}

Check `params` as far as an *edit* can: an unknown or mistyped parameter is an
`ArgumentError`, but a missing required one is not.

A node is placed before it is filled in — from the palette, a kind arrives with
no parameters at all — so requiring them at the edit would make the canvas
impossible to use. An incomplete node is not invalid, it is unfinished: it sits
`:idle` until something asks for it, and then fails on itself with the parameter
named, which is where the user is looking anyway. It is the same rule the
exporter follows for a half-wired node.
"""
checkparams(k::NodeKind, params::AbstractDict) = validateparams(k, params)

stringkeys(params::AbstractDict) = Dict{String,Any}(String(k) => v for (k, v) in params)

"""
    Loki.isacausal(kind::NodeKind, params, port::Symbol) -> Bool

Whether the kind's output `port` looks ahead in time. A graph's taint starts at
these ports and flows to everything downstream. Defaults to `false`.
"""
isacausal(::NodeKind, params, port::Symbol) = false

"""
    Loki.iswrite(kind::NodeKind) -> Bool

Whether the kind writes a file. A run never evaluates a write node as a side
effect of watching a node downstream; only an explicit write does. Defaults to
`false`.
"""
iswrite(::NodeKind) = false

# --- OpKind --------------------------------------------------------------------

"""
    Loki.OpKind(name; category, build, emit = nothing, inputs = Port[],
                outputs = [:out], params = Param[], acausal = Symbol[],
                write = false, doc = "")

A node kind described by data. `build(params, inputs, env)` receives the
validated parameters (defaults filled in) and returns a `NamedTuple` with one
pipeline per output; `emit(params, inputs)` returns the same shape as script
expressions (see [`Loki.emit`](@ref)), and a kind without one cannot be
exported; the outputs named in `acausal` look ahead in time; `write` marks a
file sink; `category` groups the kind in the palette.
"""
struct OpKind <: NodeKind
    name::String
    category::String
    doc::String
    inputs::Vector{Port}
    outputs::Vector{Symbol}
    params::Vector{Param}
    builder::Any
    emitter::Any
    acausal::Vector{Symbol}
    write::Bool
end

function OpKind(name::AbstractString; category::AbstractString, build, emit = nothing,
    inputs = Port[], outputs = [:out], params = Param[], acausal = Symbol[],
    write::Bool = false, doc::AbstractString = "")
    ins = collect(Port, inputs)
    outs = collect(Symbol, outputs)
    ps = collect(Param, params)
    isempty(outs) && throw(ArgumentError("node kind $name needs an output"))
    allunique(p.name for p in ins) ||
        throw(ArgumentError("node kind $name has duplicate input ports"))
    allunique(outs) || throw(ArgumentError("node kind $name has duplicate output ports"))
    allunique(p.name for p in ps) ||
        throw(ArgumentError("node kind $name has duplicate parameters"))
    acs = collect(Symbol, acausal)
    acs ⊆ outs || throw(ArgumentError("node kind $name: acausal ports must be outputs"))
    return OpKind(String(name), String(category), String(doc), ins, outs, ps, build, emit,
        acs, write)
end

inputs(k::OpKind) = k.inputs
outputs(k::OpKind) = k.outputs
isacausal(k::OpKind, params, port::Symbol) = port in k.acausal
iswrite(k::OpKind) = k.write

function build(k::OpKind, params::AbstractDict, inputs::AbstractDict, env)
    out = k.builder(validateparams(k, params), inputs, env)
    (out isa NamedTuple && collect(keys(out)) == k.outputs) || throw(
        ArgumentError("node kind $(k.name) built $(typeof(out)), not a NamedTuple of \
            its outputs $(k.outputs)"))
    return out
end

function emit(k::OpKind, params::AbstractDict, inputs::AbstractDict)
    k.emitter === nothing &&
        throw(ArgumentError("node kind $(k.name) cannot be exported: it has no emit"))
    out = k.emitter(validateparams(k, params), inputs)
    (out isa NamedTuple && collect(keys(out)) == k.outputs) || throw(
        ArgumentError("node kind $(k.name) emitted $(typeof(out)), not a NamedTuple of \
            its outputs $(k.outputs)"))
    return out
end

"""
    Loki.canemit(kind::NodeKind) -> Bool

Whether the kind implements [`Loki.emit`](@ref), and so can be exported.
"""
canemit(k::OpKind) = k.emitter !== nothing
canemit(k::NodeKind) = hasmethod(emit, Tuple{typeof(k),Dict{String,Any},Dict{Symbol,Any}})

function checkparams(k::OpKind, params::AbstractDict)
    out = stringkeys(params)
    for (name, value) in out
        i = findfirst(p -> p.name == name, k.params)
        i === nothing &&
            throw(ArgumentError("node kind $(k.name) has no parameter $(repr(name))"))
        spec = k.params[i]
        value === nothing || paramok(spec, value) ||
            throw(
                ArgumentError(
                    "$(k.name) parameter $name must be $(describeparam(spec)), got \
                $(repr(value))",
                ))
    end
    return out
end

function validateparams(k::OpKind, params::AbstractDict)
    out = checkparams(k, params)
    for spec in k.params
        get(out, spec.name, nothing) === nothing || continue
        spec.required &&
            throw(ArgumentError("node kind $(k.name) needs the parameter $(spec.name)"))
        out[spec.name] = spec.default
    end
    return out
end

isstrings(v) = v isa AbstractVector && all(x -> x isa AbstractString, v)
isinteger_(v) = v isa Integer && !(v isa Bool)

function paramok(spec::Param, v)
    t = spec.type
    t in (:string, :path, :column, :context, :table) && return v isa AbstractString
    t === :enum && return v isa AbstractString && v in spec.choices
    t === :integer && return isinteger_(v)
    t === :number && return v isa Real && !(v isa Bool)
    t === :boolean && return v isa Bool
    t === :integers && return v isa AbstractVector && all(isinteger_, v)
    t === :columns && return v isa AbstractString || isstrings(v)
    t === :code && return v isa AbstractString || (v isa Real && !(v isa Bool))
    t === :summarizers && return v isa AbstractVector && all(x -> x isa AbstractDict, v)
    return false
end

function describeparam(spec::Param)
    t = spec.type
    t === :enum && return "one of $(join(repr.(spec.choices), ", "))"
    t === :integers && return "a vector of integers"
    t === :columns && return "a column name or a vector of them"
    t === :code && return "Julia source text"
    t === :summarizers && return "a vector of summarizer entries"
    t === :path && return "a file path"
    t in (:column, :context, :table) && return "the name of a $t"
    return "a$(t === :integer ? "n" : "") $t"
end

function paramschema(k::OpKind)
    props = Dict{String,Any}()
    for spec in k.params
        s = jsonschema(spec)
        isempty(spec.description) || (s["description"] = spec.description)
        spec.default === nothing || (s["default"] = spec.default)
        props[spec.name] = s
    end
    return Dict{String,Any}("title" => k.name, "description" => k.doc,
        "type" => "object", "properties" => props,
        "required" => [p.name for p in k.params if p.required],
        "additionalProperties" => false)
end

const STRINGSCHEMA = Dict{String,Any}("type" => "string")

function jsonschema(spec::Param)
    t = spec.type
    t in (:string, :integer, :number, :boolean) &&
        return Dict{String,Any}("type" => String(t))
    t === :enum && return Dict{String,Any}("type" => "string", "enum" => spec.choices)
    t === :integers &&
        return Dict{String,Any}("type" => "array",
            "items" => Dict{String,Any}("type" => "integer"))
    # Loki's own vocabulary rides in "x-loki": column pickers, code editors,
    # context and table pickers, the file picker, the summarizer list editor.
    if t === :path
        s = Dict{String,Any}("type" => "string", "x-loki" => "path")
        isempty(spec.suffixes) || (s["x-loki-suffixes"] = spec.suffixes)
        return s
    end
    t in (:column, :context, :table) &&
        return Dict{String,Any}("type" => "string", "x-loki" => String(t))
    t === :code &&
        return Dict{String,Any}("type" => ["string", "number"], "x-loki" => "code")
    t === :columns &&
        return Dict{String,Any}("x-loki" => "columns",
            "anyOf" => [STRINGSCHEMA,
                Dict{String,Any}("type" => "array", "items" => STRINGSCHEMA)])
    return Dict{String,Any}("type" => "array", "x-loki" => "summarizers",
        "items" => Dict{String,Any}("type" => "object",
            "required" => ["summarizer"],
            "properties" => Dict{String,Any}("summarizer" => STRINGSCHEMA,
                "columns" =>
                    Dict{String,Any}("type" => "array", "items" => STRINGSCHEMA),
                "options" => Dict{String,Any}("type" => "object"))))
end

# --- the registry ----------------------------------------------------------------

const NODEKINDS = Dict{String,NodeKind}()

"""
    Loki.register_nodekind!(name::AbstractString, kind::NodeKind) -> NodeKind
    Loki.register_nodekind!(kind::OpKind) -> OpKind

Make `kind` available to graphs under `name` (an `OpKind`'s own name), replacing
any kind registered under that name.
"""
function register_nodekind!(name::AbstractString, kind::NodeKind)
    NODEKINDS[String(name)] = kind
    return kind
end
register_nodekind!(kind::OpKind) = register_nodekind!(kind.name, kind)

"""
    Loki.nodekind(name::AbstractString) -> NodeKind

The kind registered under `name`; an `ArgumentError` if there is none.
"""
function nodekind(name::AbstractString)
    kind = get(NODEKINDS, String(name), nothing)
    kind === nothing && throw(ArgumentError("unknown node kind $(repr(name))"))
    return kind
end

"""
    Loki.nodekinds() -> Vector{String}

The names of every registered node kind, sorted.
"""
nodekinds() = sort!(collect(keys(NODEKINDS)))
