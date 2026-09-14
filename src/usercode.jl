# User code: expression parameters are Julia source text, evaluated in a module
# the session owns, after an optional prelude of helper definitions. Source text
# is what is stored, saved and exported, so a graph says exactly what was typed.
#
# This is arbitrary code execution by design; see DESIGN.md's "User code" for the
# containment, which is the server's.

"""
    Loki.UserCode(; prelude = "")

A session's user-code module: an anonymous module with `CausalFrames`, `Loki`,
`Dates` and `Statistics` in scope, into which the `prelude` — a block of helper
definitions — is evaluated first. Expression parameters are evaluated there by
[`Loki.evalcode`](@ref).
"""
mutable struct UserCode
    # Created on first use, so a session that evaluates no source text never makes
    # one — and can be built where modules cannot, such as a precompile workload.
    mod::Union{Nothing,Module}
    prelude::String
    # Source text → value, so a node rebuilt with unchanged parameters gets the
    # same function back. Reset with the module whenever the prelude changes.
    const values::Dict{String,Any}
end

function UserCode(; prelude::AbstractString = "")
    uc = UserCode(nothing, "", Dict{String,Any}())
    setprelude!(uc, prelude)
    return uc
end

# The modules are bound into the new module and `using`'d relatively, rather
# than resolved as packages, so it works whatever environment is active.
function usermodule()
    mod = Module(:LokiUserCode)
    for (name, used) in
        ((:CausalFrames, CausalFrames), (:Loki, Loki), (:Dates, Dates),
        (:Statistics, Statistics))
        Core.eval(mod, :(const $name = $used))
        Core.eval(mod, Expr(:using, Expr(:., :., name)))
    end
    return mod
end

"""
    Loki.setprelude!(uc::UserCode, prelude::AbstractString) -> UserCode

Replace the prelude: a fresh module is created and `prelude` evaluated into it, so
a definition removed from the prelude is gone. An error in the prelude is raised,
leaving the previous module and prelude in place.
"""
function setprelude!(uc::UserCode, prelude::AbstractString)
    mod = nothing
    if !isempty(strip(prelude))
        mod = usermodule()
        Base.include_string(mod, String(prelude), "prelude")
    end
    uc.mod = mod
    uc.prelude = String(prelude)
    empty!(uc.values)
    return uc
end

"""
    Loki.evalcode(uc::UserCode, source; what = "expression")

Evaluate one expression parameter in the user module: `source` is Julia source
text holding exactly one expression (a number is returned as is). A parse error
is an `ArgumentError` naming `what`. Values are cached by source text until the
prelude changes.
"""
evalcode(::UserCode, source::Real; what::AbstractString = "expression") = source

function evalcode(uc::UserCode, source::AbstractString; what::AbstractString = "expression")
    key = String(source)
    haskey(uc.values, key) && return uc.values[key]
    expr = try
        Meta.parse(key)
    catch err
        err isa Meta.ParseError || rethrow()
        throw(ArgumentError("cannot parse $what $(repr(key)): $(err.msg)"))
    end
    expr === nothing && throw(ArgumentError("$what is empty"))
    expr isa Expr && expr.head === :incomplete &&
        throw(ArgumentError("cannot parse $what $(repr(key)): incomplete expression"))
    mod = uc.mod === nothing ? (uc.mod = usermodule()) : uc.mod
    value = Core.eval(mod, expr)
    uc.values[key] = value
    return value
end

"""
    Loki.BuildEnv(; usercode = UserCode(), contexts = Dict(), tables = Dict())

What a node's parameters can name, handed to [`Loki.build`](@ref): the user-code
module that source text is evaluated in, and the session's named contexts and
in-memory tables.
"""
struct BuildEnv
    usercode::UserCode
    contexts::Dict{String,Context}
    tables::Dict{String,Any}
end

BuildEnv(; usercode::UserCode = UserCode(), contexts = Dict{String,Context}(),
    tables = Dict{String,Any}()) =
    BuildEnv(usercode, Dict{String,Context}(String(k) => v for (k, v) in pairs(contexts)),
        Dict{String,Any}(String(k) => v for (k, v) in pairs(tables)))

function namedcontext(env::BuildEnv, name::AbstractString)
    ctx = get(env.contexts, String(name), nothing)
    ctx === nothing && throw(ArgumentError("the session has no context $(repr(name))"))
    return ctx
end

function namedtable(env::BuildEnv, name::AbstractString)
    haskey(env.tables, String(name)) ||
        throw(ArgumentError("the session has no table $(repr(name))"))
    return env.tables[String(name)]
end
