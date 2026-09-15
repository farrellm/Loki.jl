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
        print(io, isempty(positional) ? "; " : "; ")
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
