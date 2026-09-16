# The node kinds wrapping CausalFrames' exported operators, one to one, with their
# keyword arguments as parameters. Parameters are JSON-like: column names are
# strings, and anything that is a Julia value rather than a name — an interval, a
# tolerance, a predicate, a row function, a model, a type dictionary — is source
# text evaluated in the session's user module (see usercode.jl).

# --- parameter helpers -----------------------------------------------------------

paramsym(v) = v === nothing ? nothing : Symbol(v)
paramkey(v) =
    v === nothing ? nothing :
    v isa AbstractString ? Symbol(v) : Symbol[Symbol(c) for c in v]
paramcolumns(v) =
    v === nothing ? Symbol[] :
    v isa AbstractString ? [Symbol(v)] : Symbol[Symbol(c) for c in v]
paramcode(env::BuildEnv, params::AbstractDict, name::String) =
    params[name] === nothing ? nothing :
    evalcode(env.usercode, params[name]; what = "parameter $name")

function requiredcode(env::BuildEnv, params::AbstractDict, name::String)
    params[name] === nothing && throw(ArgumentError("the parameter $name is required"))
    return paramcode(env, params, name)
end

# A column selection: the named `columns`, plus a `match` expression (a Regex or a
# predicate on the column name) when given.
function selectors(env::BuildEnv, params::AbstractDict)
    sels = Any[paramcolumns(params["columns"])...]
    match = paramcode(env, params, "match")
    match === nothing || push!(sels, match)
    isempty(sels) &&
        throw(ArgumentError("select at least one column, by name or with match"))
    return sels
end

function atleastone(ps, what::String)
    isempty(ps) && throw(ArgumentError("$what needs at least one input"))
    return ps
end

# --- emit helpers ---------------------------------------------------------------
#
# One converter per `build` converter, turning the same parameter into script
# text instead of a value: `paramsym`/`emitsym`, `paramkey`/`emitkey`, and so on.
# A keyword whose value is `nothing` is left out of the call, and `unless` drops
# one that is already the operator's own default, so a script says what the user
# chose and nothing more.

# `f(args...; kwargs...)`, without the keywords whose value is `nothing`.
function opcall(f, args...; kwargs...)
    kws = Any[Expr(:kw, Symbol(k), v) for (k, v) in pairs(kwargs) if v !== nothing]
    isempty(kws) && return Expr(:call, f, args...)
    return Expr(:call, f, Expr(:parameters, kws...), args...)
end

emitpipe(input, call) = Expr(:call, :|>, input, call)

unless(value, default) = value == default ? nothing : value

emitsym(v) = v === nothing ? nothing : QuoteNode(Symbol(v))
emitkey(v) =
    v === nothing ? nothing :
    v isa AbstractString ? QuoteNode(Symbol(v)) :
    Expr(:vect, Any[QuoteNode(Symbol(c)) for c in v]...)
emitcolumns(v) = Any[QuoteNode(c) for c in paramcolumns(v)]
emitcode(params::AbstractDict, name::String) =
    get(params, name, nothing) === nothing ? nothing : Code(params[name])

function emitrequiredcode(params::AbstractDict, name::String)
    get(params, name, nothing) === nothing &&
        throw(ArgumentError("the parameter $name is required"))
    return emitcode(params, name)
end

# A column selection, as `build`'s `selectors` spells it: the named columns and
# then the `match` expression.
function emitselectors(params::AbstractDict)
    sels = emitcolumns(params["columns"])
    match = emitcode(params, "match")
    match === nothing || push!(sels, match)
    isempty(sels) &&
        throw(ArgumentError("select at least one column, by name or with match"))
    return sels
end

# A session table is a field of the script's `tables`; a context is the `const`
# binding the script gives it.
emittable(name) = Expr(:., :tables, QuoteNode(Symbol(name)))
emitcontext(name) = Symbol(name)

# `A.B.c`, for the names a script cannot reach unqualified.
qualified(parts::Symbol...) =
    foldl((mod, name) -> Expr(:., mod, QuoteNode(name)), parts[2:end]; init = parts[1])

const KEY = Param("key", :columns; description = "key column(s): state is kept per key")
const SELECTION = [
    Param("columns", :columns; description = "column names"),
    Param("match", :code; description = "a Regex or a predicate on the column name"),
]
const SUMMARIZERLIST = Param("summarizers", :summarizers; required = true)
const ONEINPUT = [Port(:in)]

# --- summarizer entries --------------------------------------------------------------

# A summarizer entry is described once and read twice: `summarizer` builds the
# value, `emitsummarizer` prints the constructor call. `columns` is the number of
# column arguments (-1: one vector of at least one), `positional` the required
# options passed after them, `keywords` the optional ones; each option carries a
# converter tag with both a value form and an expression form.
struct SummarizerSpec
    name::String
    make::Any
    columns::Int
    positional::Vector{Pair{String,Symbol}}
    keywords::Vector{Pair{String,Symbol}}
    emitter::Any    # `nothing`: the generic `Name(columns…, positional…; keywords…)`
end

SummarizerSpec(name::AbstractString, make; columns::Int, positional = (),
    keywords = (), emit = nothing) =
    SummarizerSpec(String(name), make, columns,
        Pair{String,Symbol}[String(k) => v for (k, v) in positional],
        Pair{String,Symbol}[String(k) => v for (k, v) in keywords], emit)

optionvalue(::Val{:asis}, v, ::BuildEnv) = v
optionvalue(::Val{:symbol}, v, ::BuildEnv) = Symbol(v)
optionvalue(::Val{:tuple}, v, ::BuildEnv) = Tuple(v)
optionvalue(::Val{:code}, v, env::BuildEnv) =
    evalcode(env.usercode, v; what = "summarizer option")

optionexpr(::Val{:asis}, v) = v
optionexpr(::Val{:symbol}, v) = QuoteNode(Symbol(v))
optionexpr(::Val{:tuple}, v) = Expr(:tuple, v...)
optionexpr(::Val{:code}, v) = Code(v)

# Both paths reject the same entries, so what exports is what the session built.
function checkentry(spec::SummarizerSpec, cols::Vector{Symbol}, opts::Dict{String,Any})
    if spec.columns < 0
        isempty(cols) && throw(ArgumentError("$(spec.name) needs at least one column"))
    elseif length(cols) != spec.columns
        throw(ArgumentError("$(spec.name) takes $(spec.columns) column(s), \
            got $(length(cols))"))
    end
    known = [first.(spec.positional); first.(spec.keywords)]
    for k in keys(opts)
        k in known || throw(ArgumentError("$(spec.name) has no option $(repr(k))"))
    end
    for (k, _) in spec.positional
        haskey(opts, k) ||
            throw(ArgumentError("$(spec.name) needs the option $(repr(k))"))
    end
    return nothing
end

function makesummarizer(spec::SummarizerSpec, cols::Vector{Symbol},
    opts::Dict{String,Any}, env::BuildEnv)
    checkentry(spec, cols, opts)
    pos = Any[optionvalue(Val(tag), opts[k], env) for (k, tag) in spec.positional]
    kws = (;
        (
            Symbol(k) => optionvalue(Val(tag), opts[k], env)
            for (k, tag) in spec.keywords if haskey(opts, k)
        )...
    )
    colargs = spec.columns < 0 ? (cols,) : Tuple(cols)
    return spec.make(colargs..., pos...; kws...)
end

function emitsummarizerspec(spec::SummarizerSpec, cols::Vector{Symbol},
    opts::Dict{String,Any})
    checkentry(spec, cols, opts)
    spec.emitter === nothing || return spec.emitter(cols, opts)
    pos = Any[optionexpr(Val(tag), opts[k]) for (k, tag) in spec.positional]
    kws = Pair{Symbol,Any}[
        Symbol(k) => optionexpr(Val(tag), opts[k])
        for (k, tag) in spec.keywords if haskey(opts, k)
    ]
    colargs = spec.columns < 0 ? Any[Expr(:vect, columnexprs(cols)...)] : columnexprs(cols)
    return opcall(Symbol(spec.name), colargs..., pos...; kws...)
end

columnexprs(cols) = Any[QuoteNode(c) for c in cols]

# `FitModel(model, columns, response; …)` takes its model first, so it prints its
# own call rather than the generic shape.
emitfitmodel(cols::Vector{Symbol}, opts::Dict{String,Any}) =
    opcall(:FitModel, emitrequiredcode(opts, "model"),
        Expr(:vect, columnexprs(cols)...), QuoteNode(Symbol(opts["response"]));
        name = haskey(opts, "name") ? QuoteNode(Symbol(opts["name"])) : nothing,
        verbosity = get(opts, "verbosity", nothing))

const SUMMARIZERS = Dict{String,SummarizerSpec}(
    "Count" => SummarizerSpec("Count", Count; columns = 0),
    "CountDistinct" => SummarizerSpec("CountDistinct", CountDistinct; columns = 1),
    "Sum" => SummarizerSpec("Sum", Sum; columns = 1),
    "Product" => SummarizerSpec("Product", Product; columns = 1),
    "Mean" => SummarizerSpec("Mean", Mean; columns = 1),
    "Min" => SummarizerSpec("Min", Min; columns = 1),
    "Max" => SummarizerSpec("Max", Max; columns = 1),
    "First" => SummarizerSpec("First", First; columns = 1),
    "Last" => SummarizerSpec("Last", Last; columns = 1),
    "SumPower" =>
        SummarizerSpec("SumPower", SumPower; columns = 1, positional = ("n" => :asis,)),
    "Moment" =>
        SummarizerSpec("Moment", Moment; columns = 1, positional = ("n" => :asis,)),
    "Variance" => SummarizerSpec("Variance", Variance; columns = 1,
        keywords = ("corrected" => :asis,)),
    "Std" =>
        SummarizerSpec("Std", Std; columns = 1, keywords = ("corrected" => :asis,)),
    "DotProduct" => SummarizerSpec("DotProduct", DotProduct; columns = 2),
    "Correlation" => SummarizerSpec("Correlation", Correlation; columns = 2),
    "Covariance" => SummarizerSpec("Covariance", Covariance; columns = 2,
        keywords = ("corrected" => :asis,)),
    "LinearRegression" => SummarizerSpec("LinearRegression", LinearRegression;
        columns = -1, positional = ("response" => :symbol,),
        keywords = ("intercept" => :asis, "name" => :symbol)),
    # `model` is positional here, not a keyword: it is required, and `checkentry`
    # must reject an entry without it on both paths, as `emitfitmodel` does.
    "FitModel" => SummarizerSpec("FitModel",
        (cols, response, model; kws...) -> FitModel(model, cols, response; kws...);
        columns = -1, positional = ("response" => :symbol, "model" => :code),
        keywords = ("name" => :symbol, "verbosity" => :asis),
        emit = emitfitmodel),
    "Lags" => SummarizerSpec("Lags", Lags; columns = 1, positional = ("p" => :asis,),
        keywords = ("name" => :symbol,)),
    "EMA" => SummarizerSpec("EMA", EMA; columns = 1,
        keywords = ("span" => :asis, "halflife" => :code, "name" => :symbol)),
    "FitARMA" => SummarizerSpec("FitARMA", FitARMA; columns = 1,
        keywords = ("order" => :tuple, "seasonal_order" => :tuple,
            "include_mean" => :asis, "name" => :symbol)),
)

# The summarizers named by a `:summarizers` parameter: entries of the form
# `{"summarizer": name, "columns": [...], "options": {...}}`.
function summarizers(env::BuildEnv, entries)
    checkentries(entries)
    return Summarizer[summarizer(env, entry) for entry in entries]
end

# The same list as a vector literal of constructor calls.
function emitsummarizers(entries)
    checkentries(entries)
    return Expr(:vect, Any[emitsummarizer(entry) for entry in entries]...)
end

checkentries(entries) =
    (entries === nothing || isempty(entries)) &&
    throw(ArgumentError("at least one summarizer is required"))

function summarizer(env::BuildEnv, entry::AbstractDict)
    spec, cols, opts = entryparts(entry)
    return makesummarizer(spec, cols, opts, env)
end

function emitsummarizer(entry::AbstractDict)
    spec, cols, opts = entryparts(entry)
    return emitsummarizerspec(spec, cols, opts)
end

function entryparts(entry::AbstractDict)
    e = stringkeys(entry)
    for k in keys(e)
        k in ("summarizer", "columns", "options") ||
            throw(ArgumentError("a summarizer entry has no field $(repr(k))"))
    end
    name = get(e, "summarizer", nothing)
    name isa AbstractString ||
        throw(ArgumentError("a summarizer entry needs a \"summarizer\" name"))
    spec = get(SUMMARIZERS, name, nothing)
    spec === nothing && throw(ArgumentError("unknown summarizer $(repr(name)); \
        known: $(join(sort!(collect(keys(SUMMARIZERS))), ", "))"))
    options = get(e, "options", nothing)
    return spec, paramcolumns(get(e, "columns", nothing)),
    options === nothing ? Dict{String,Any}() : stringkeys(options)
end

# --- sources -----------------------------------------------------------------------

register_nodekind!(
    OpKind("emptyframe"; category = "sources",
        doc = "A source that produces no rows.",
        build = (params, inputs, env) -> (; out = emptyframe()),
        emit = (params, inputs) -> (; out = opcall(:emptyframe))),
)

register_nodekind!(
    OpKind("clock"; category = "sources",
        doc = "One row per interval, at start, start + interval, …",
        params = [
            Param("interval", :code; required = true,
                description = "the spacing, e.g. `Minute(5)` or `10`"),
            Param("batchsize", :integer; default = 1024),
        ],
        build = (params, inputs, env) ->
            (;
                out = clock(requiredcode(env, params, "interval");
                    batchsize = params["batchsize"])
            ),
        emit = (params, inputs) ->
            (;
                out = opcall(:clock, emitrequiredcode(params, "interval");
                    batchsize = unless(params["batchsize"], 1024))
            )),
)

register_nodekind!(
    OpKind("concatenate"; category = "sources",
        doc = "The inputs' outputs end to end, in connection order.",
        inputs = [Port(:in; variadic = true)],
        build = (params, inputs, env) ->
            (; out = concatenate(atleastone(inputs[:in], "concatenate")...)),
        emit = (params, inputs) ->
            (; out = opcall(:concatenate, atleastone(inputs[:in], "concatenate")...))),
)

register_nodekind!(
    OpKind("merge"; category = "sources",
        doc = "The inputs' rows interleaved by time.",
        inputs = [Port(:in; variadic = true)],
        params = [Param("batchsize", :integer; default = 1024)],
        build = (params, inputs, env) ->
            (;
                out = merge(atleastone(inputs[:in], "merge")...;
                    batchsize = params["batchsize"])
            ),
        emit = (params, inputs) ->
            (;
                out = opcall(:merge, atleastone(inputs[:in], "merge")...;
                    batchsize = unless(params["batchsize"], 1024))
            )),
)

register_nodekind!(
    OpKind("table"; category = "sources",
        doc = "A table the session holds, read with readtable.",
        params = [
            Param("table", :table; required = true),
            Param("time", :column; description = "the time column, when not :time"),
            Param("sort", :boolean; default = false),
            Param("checkorder", :boolean; default = true),
            Param("closed", :boolean; description = "keep the rows at stop"),
        ],
        build = (params, inputs, env) -> (; out = tablesource(env, params)),
        emit = (params, inputs) -> (; out = emittablesource(params))),
)

function tablesource(env::BuildEnv, params::AbstractDict)
    table = namedtable(env, params["table"])
    closed = params["closed"] === nothing ? (;) : (; closed = params["closed"])
    if table isa CausalFrame
        # A frame's time is resolved and sorted already; it keeps readtable's frame
        # semantics, refusing a context outside its own.
        params["time"] === nothing && !params["sort"] && params["checkorder"] ||
            throw(ArgumentError("table $(params["table"]) is a loaded frame, whose time \
                column is already resolved and in order, so it takes neither time, \
                sort nor checkorder"))
        return readtable(table; closed...)
    end
    return readtable(table; time = paramsym(params["time"]), sort = params["sort"],
        checkorder = params["checkorder"], closed...)
end

# A frame takes none of `time`, `sort` and `checkorder` (`tablesource` rejects
# them, since `readtable(::CausalFrame)` has no such keywords), and every other
# keyword is dropped at its default, so a frozen frame emits the bare
# `readtable(tables.name)` that reproduces it.
emittablesource(params::AbstractDict) =
    opcall(:readtable, emittable(params["table"]); time = emitsym(params["time"]),
        sort = unless(params["sort"], false),
        checkorder = unless(params["checkorder"], true), closed = params["closed"])

# --- files --------------------------------------------------------------------------

const PATH = Param("path", :string; required = true)
const QUEUE = Param("queue", :integer; default = 1)
const BACKEND = Param("backend", :enum; choices = ["auto", "duckdb", "parquet2"],
    default = "auto")
const SORT = Param("sort", :boolean; default = false,
    description = "sort the rows by time, for a file not stored in time order")
const CLOSED = Param("closed", :boolean; default = false,
    description = "keep the rows at stop")

register_nodekind!(
    OpKind("readcsv"; category = "files",
        doc = "Read a CSV file; every column is a String unless `types` says otherwise.",
        params = [
            PATH,
            Param("types", :code;
                description = "e.g. `Dict(:time => DateTime, :close => Float64)`"),
            Param(
                "time",
                :code;
                description = "a column name like `:ts`, or `row -> time`",
            ),
            Param("rename", :code),
            Param("delim", :string),
            SORT,
            CLOSED,
            Param("chunkbytes", :integer; default = 4 * 1024 * 1024),
        ],
        build = (params, inputs, env) ->
            (;
                out = readcsv(params["path"]; types = paramcode(env, params, "types"),
                    time = paramcode(env, params, "time"),
                    rename = paramcode(env, params, "rename"), delim = params["delim"],
                    sort = params["sort"], closed = params["closed"],
                    chunkbytes = params["chunkbytes"])
            ),
        emit = (params, inputs) ->
            (;
                out = opcall(:readcsv, params["path"]; types = emitcode(params, "types"),
                    time = emitcode(params, "time"), rename = emitcode(params, "rename"),
                    delim = params["delim"], sort = unless(params["sort"], false),
                    closed = unless(params["closed"], false),
                    chunkbytes = unless(params["chunkbytes"], 4 * 1024 * 1024))
            )),
)

register_nodekind!(
    OpKind("writecsv"; category = "files", write = true,
        doc = "Write the stream to a CSV file as it flows by.",
        inputs = ONEINPUT, params = [PATH, QUEUE],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> writecsv(params["path"]; queue = params["queue"])),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:writecsv, params["path"]; queue = unless(params["queue"], 1)))
            )),
)

register_nodekind!(
    OpKind("readparquet"; category = "files",
        doc = "Read a parquet file.",
        params = [PATH, Param("time", :code), Param("rename", :code), SORT, CLOSED,
            BACKEND],
        build = (params, inputs, env) ->
            (;
                out = readparquet(params["path"]; time = paramcode(env, params, "time"),
                    rename = paramcode(env, params, "rename"), sort = params["sort"],
                    closed = params["closed"], backend = Symbol(params["backend"]))
            ),
        emit = (params, inputs) ->
            (;
                out = opcall(:readparquet, params["path"];
                    time = emitcode(params, "time"), rename = emitcode(params, "rename"),
                    sort = unless(params["sort"], false),
                    closed = unless(params["closed"], false),
                    backend = emitsym(unless(params["backend"], "auto")))
            )),
)

register_nodekind!(
    OpKind("writeparquet"; category = "files", write = true,
        doc = "Write the stream to a parquet file as it flows by.",
        inputs = ONEINPUT,
        params = [
            PATH,
            QUEUE,
            Param("rowgroupsize", :integer; default = 1_000_000),
            BACKEND,
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |> writeparquet(params["path"]; queue = params["queue"],
                    rowgroupsize = params["rowgroupsize"],
                    backend = Symbol(params["backend"]))
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:writeparquet, params["path"];
                        queue = unless(params["queue"], 1),
                        rowgroupsize = unless(params["rowgroupsize"], 1_000_000),
                        backend = emitsym(unless(params["backend"], "auto"))))
            )),
)

register_nodekind!(
    OpKind("readjls"; category = "files",
        doc = "Read a file written by writejls.",
        params = [PATH, CLOSED],
        build = (params, inputs, env) ->
            (; out = readjls(params["path"]; closed = params["closed"])),
        emit = (params, inputs) ->
            (;
                out = opcall(:readjls, params["path"];
                    closed = unless(params["closed"], false))
            )),
)

register_nodekind!(
    OpKind("writejls"; category = "files", write = true,
        doc = "Write the stream through Julia's Serialization as it flows by.",
        inputs = ONEINPUT, params = [PATH, QUEUE],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> writejls(params["path"]; queue = params["queue"])),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:writejls, params["path"]; queue = unless(params["queue"], 1)))
            )),
)

# --- rows and columns ---------------------------------------------------------------

register_nodekind!(
    OpKind("filterrows"; category = "rows",
        doc = "Keep the rows where the predicate holds.",
        inputs = ONEINPUT,
        params = [
            Param("predicate", :code; required = true, description = "e.g. `r -> r.x > 0`"),
        ],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> filterrows(requiredcode(env, params, "predicate"))),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:filterrows, emitrequiredcode(params, "predicate")))
            )),
)

register_nodekind!(
    OpKind("addcolumns"; category = "rows",
        doc = "Add columns computed row by row.",
        inputs = ONEINPUT,
        params = [
            Param("function", :code; required = true,
                description = "e.g. `r -> (; mid = (r.bid + r.ask) / 2)`"),
        ],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> addcolumns(requiredcode(env, params, "function"))),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:addcolumns, emitrequiredcode(params, "function")))
            )),
)

for (name, op, doc) in (
    ("selectcolumns", selectcolumns, "Keep the selected columns (and time)."),
    ("dropcolumns", dropcolumns, "Drop the selected columns."),
    ("reordercolumns", reordercolumns, "Move the selected columns to the front."),
)
    register_nodekind!(
        OpKind(name; category = "columns", doc, inputs = ONEINPUT,
            params = SELECTION,
            build = (params, inputs, env) ->
                (; out = inputs[:in] |> op(selectors(env, params)...)),
            emit = (params, inputs) ->
                (;
                    out = emitpipe(inputs[:in],
                        opcall(Symbol(name), emitselectors(params)...))
                )),
    )
end

register_nodekind!(
    OpKind("lag"; category = "rows",
        doc = "Shift every row later in time by an offset.",
        inputs = ONEINPUT, params = [Param("offset", :code; required = true)],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> lag(requiredcode(env, params, "offset"))),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:lag, emitrequiredcode(params, "offset")))
            )),
)

register_nodekind!(
    OpKind("head"; category = "rows",
        doc = "The first n rows.",
        inputs = ONEINPUT, params = [Param("n", :integer; required = true)],
        build = (params, inputs, env) -> (; out = inputs[:in] |> head(params["n"])),
        emit = (params, inputs) ->
            (; out = emitpipe(inputs[:in], opcall(:head, params["n"])))),
)

register_nodekind!(
    OpKind("settime"; category = "rows",
        doc = "Recompute the time column, causally.",
        inputs = ONEINPUT,
        params = [
            Param("spec", :code; required = true,
                description = "a column name like `:ts`, or `row -> time`"),
        ],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> settime(requiredcode(env, params, "spec"))),
        emit = (params, inputs) ->
            (;
                out = emitpipe(
                    inputs[:in],
                    opcall(:settime, emitrequiredcode(params, "spec")),
                )
            )),
)

register_nodekind!(
    OpKind("lastrow"; category = "rows",
        doc = "The last row (per key), at the window's stop.",
        inputs = ONEINPUT, params = [KEY],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> lastrow(; key = paramkey(params["key"]))),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in], opcall(:lastrow; key = emitkey(params["key"])))
            )),
)

register_nodekind!(
    OpKind("sortcycles"; category = "rows",
        doc = "Stably reorder the rows sharing each timestamp.",
        inputs = ONEINPUT,
        params = [
            Param("columns", :columns; description = "sort key column(s)"),
            Param("function", :code;
                description = "a per-row sort key, e.g. `r -> (-r.votes, r.id)`"),
            Param("rev", :boolean; default = false),
        ],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> sortcycles(sortkey(env, params); rev = params["rev"])),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:sortcycles, emitsortkey(params);
                        rev = unless(params["rev"], false)))
            )),
)

# `sortcycles`' `by`: the named columns or a key function, exactly one of them.
function sortkey(env::BuildEnv, params::AbstractDict)
    (params["columns"] === nothing) == (params["function"] === nothing) &&
        throw(ArgumentError("sort by columns or by a function, exactly one of them"))
    params["columns"] === nothing && return paramcode(env, params, "function")
    return paramcolumns(params["columns"])
end

function emitsortkey(params::AbstractDict)
    (params["columns"] === nothing) == (params["function"] === nothing) &&
        throw(ArgumentError("sort by columns or by a function, exactly one of them"))
    params["columns"] === nothing && return emitcode(params, "function")
    return Expr(:vect, emitcolumns(params["columns"])...)
end

register_nodekind!(
    OpKind("forwardfill"; category = "rows",
        doc = "Replace missing values in the selected columns with the last seen value.",
        inputs = ONEINPUT, params = [SELECTION..., KEY, Param("tolerance", :code)],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |> forwardfill(selectors(env, params)...;
                    key = paramkey(params["key"]),
                    tolerance = paramcode(env, params, "tolerance"))
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:forwardfill, emitselectors(params)...;
                        key = emitkey(params["key"]),
                        tolerance = emitcode(params, "tolerance")))
            )),
)

register_nodekind!(
    OpKind("fillmissing"; category = "rows",
        doc = "Replace missing values with per-column constants.",
        inputs = ONEINPUT,
        params = [
            Param("values", :code; required = true, description = "e.g. `(; x = 0.0)`"),
        ],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> fillmissing(requiredcode(env, params, "values"))),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:fillmissing, emitrequiredcode(params, "values")))
            )),
)

# --- summarizing -----------------------------------------------------------------------

const KEYSET = Param("keyset", :code;
    description = "the declared key values, e.g. `[\"a\", \"b\"]` or `[(1, \"a\"), (2, \"b\")]`, \
        making keyed output dense")

for (name, op, doc) in (
    ("summarize", summarize, "One summary row (per key) at the window's stop."),
    ("addsummarycolumns", addsummarycolumns, "Running summaries appended to each row."),
)
    register_nodekind!(
        OpKind(name; category = "summarizing", doc, inputs = ONEINPUT,
            params = [SUMMARIZERLIST, KEY],
            build = (params, inputs, env) ->
                (;
                    out = inputs[:in] |> op(summarizers(env, params["summarizers"]);
                        key = paramkey(params["key"]))
                ),
            emit = (params, inputs) ->
                (;
                    out = emitpipe(inputs[:in],
                        opcall(Symbol(name), emitsummarizers(params["summarizers"]);
                            key = emitkey(params["key"])))
                )),
    )
end

register_nodekind!(
    OpKind("summarizecycles"; category = "summarizing",
        doc = "One summary row per timestamp (and key).",
        inputs = ONEINPUT, params = [SUMMARIZERLIST, KEY, KEYSET],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |>
                      summarizecycles(summarizers(env, params["summarizers"]);
                    key = paramkey(params["key"]),
                    keyset = paramcode(env, params, "keyset"))
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:summarizecycles, emitsummarizers(params["summarizers"]);
                        key = emitkey(params["key"]),
                        keyset = emitcode(params, "keyset")))
            )),
)

register_nodekind!(
    OpKind("addrollingcolumns"; category = "summarizing",
        doc = "Summaries over trailing windows appended to each row.",
        inputs = [Port(:data), Port(:from; optional = true)],
        params = [Param("windows", :code; required = true), SUMMARIZERLIST, KEY],
        build = (params, inputs, env) ->
            (;
                out = inputs[:data] |>
                      addrollingcolumns(requiredcode(env, params, "windows"),
                    summarizers(env, params["summarizers"]); key = paramkey(params["key"]),
                    from = get(inputs, :from, nothing))
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:data],
                    opcall(:addrollingcolumns, emitrequiredcode(params, "windows"),
                        emitsummarizers(params["summarizers"]);
                        key = emitkey(params["key"]),
                        from = get(inputs, :from, nothing)))
            )),
)

register_nodekind!(
    OpKind("intervalize"; category = "summarizing",
        doc = "Summaries over the intervals between clock ticks.",
        inputs = [Port(:data), Port(:clock)],
        params = [
            SUMMARIZERLIST,
            KEY,
            KEYSET,
            Param("closelast", :boolean; default = false),
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:data] |> intervalize(inputs[:clock],
                    summarizers(env, params["summarizers"]); key = paramkey(params["key"]),
                    keyset = paramcode(env, params, "keyset"),
                    closelast = params["closelast"])
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:data],
                    opcall(:intervalize, inputs[:clock],
                        emitsummarizers(params["summarizers"]);
                        key = emitkey(params["key"]),
                        keyset = emitcode(params, "keyset"),
                        closelast = unless(params["closelast"], false)))
            )),
)

register_nodekind!(
    OpKind("summarizewindows"; category = "summarizing",
        doc = "Summaries over a trailing window at each clock tick.",
        inputs = [Port(:data), Port(:clock)],
        params = [Param("lookback", :code; required = true), SUMMARIZERLIST, KEY, KEYSET],
        build = (params, inputs, env) ->
            (;
                out = inputs[:data] |> summarizewindows(inputs[:clock],
                    requiredcode(env, params, "lookback"),
                    summarizers(env, params["summarizers"]);
                    key = paramkey(params["key"]),
                    keyset = paramcode(env, params, "keyset"))
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:data],
                    opcall(:summarizewindows, inputs[:clock],
                        emitrequiredcode(params, "lookback"),
                        emitsummarizers(params["summarizers"]);
                        key = emitkey(params["key"]),
                        keyset = emitcode(params, "keyset")))
            )),
)

# --- joins ---------------------------------------------------------------------------

const JOINPARAMS = [
    KEY,
    Param("tolerance", :code),
    Param("strict", :boolean; default = false),
    Param("leftprefix", :string),
    Param("rightprefix", :string),
    Param("righttime", :column),
]

joinkwargs(env::BuildEnv, params::AbstractDict) = (;
    key = paramkey(params["key"]), tolerance = paramcode(env, params, "tolerance"),
    strict = params["strict"], leftprefix = params["leftprefix"],
    rightprefix = params["rightprefix"], righttime = paramsym(params["righttime"]))

emitjoinkwargs(params::AbstractDict) = (;
    key = emitkey(params["key"]), tolerance = emitcode(params, "tolerance"),
    strict = unless(params["strict"], false), leftprefix = params["leftprefix"],
    rightprefix = params["rightprefix"], righttime = emitsym(params["righttime"]))

register_nodekind!(
    OpKind("asofjoin"; category = "joins",
        doc = "Join each left row to the latest right row not after it.",
        inputs = [Port(:left), Port(:right)], params = JOINPARAMS,
        build = (params, inputs, env) ->
            (; out = inputs[:left] |> asofjoin(inputs[:right]; joinkwargs(env, params)...)),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:left],
                    opcall(:asofjoin, inputs[:right]; emitjoinkwargs(params)...))
            ),
    ),
)

register_nodekind!(
    OpKind("lookupjoin"; category = "joins",
        doc = "Join each row to the row with the same key in a session table without time.",
        inputs = ONEINPUT,
        params = [
            Param("table", :table; required = true),
            Param("key", :columns; required = true, description = "key column(s)"),
            Param("unmatched", :enum; choices = ["missing", "error", "drop"],
                default = "missing"),
            Param("leftprefix", :string),
            Param("rightprefix", :string),
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |> lookupjoin(namedtable(env, params["table"]);
                    key = paramkey(params["key"]),
                    unmatched = Symbol(params["unmatched"]),
                    leftprefix = params["leftprefix"], rightprefix = params["rightprefix"])
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:lookupjoin, emittable(params["table"]);
                        key = emitkey(params["key"]),
                        unmatched = emitsym(unless(params["unmatched"], "missing")),
                        leftprefix = params["leftprefix"],
                        rightprefix = params["rightprefix"]))
            )),
)

# --- models ----------------------------------------------------------------------------

const OPERATION = Param("operation", :enum;
    choices = ["predict", "predict_mean", "predict_mode", "predict_median"],
    default = "predict")

register_nodekind!(
    OpKind("applymodels"; category = "models",
        doc = "Predictions from a stream of fitted MLJ models.",
        inputs = [Port(:data), Port(:models)],
        params = [
            Param("column", :column; default = "model"), KEY, Param("tolerance", :code),
            Param("strict", :boolean; default = false),
            Param("name", :column; default = "prediction"), OPERATION,
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:data] |> applymodels(inputs[:models];
                    column = Symbol(params["column"]), key = paramkey(params["key"]),
                    tolerance = paramcode(env, params, "tolerance"),
                    strict = params["strict"],
                    name = Symbol(params["name"]), operation = Symbol(params["operation"]))
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:data],
                    opcall(:applymodels, inputs[:models];
                        column = emitsym(unless(params["column"], "model")),
                        key = emitkey(params["key"]),
                        tolerance = emitcode(params, "tolerance"),
                        strict = unless(params["strict"], false),
                        name = emitsym(unless(params["name"], "prediction")),
                        operation = emitsym(unless(params["operation"], "predict"))))
            )),
)

register_nodekind!(
    OpKind("addpredictions"; category = "models",
        doc = "Predictions from an MLJ model refit on a rolling window.",
        inputs = [Port(:data), Port(:clock)],
        params = [
            Param("lookback", :code; required = true),
            Param("model", :code; required = true, description = "an MLJ model"),
            Param("predictors", :columns; required = true),
            Param("response", :column; required = true), KEY,
            Param("name", :column; default = "prediction"), OPERATION,
            Param("verbosity", :integer; default = 0),
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:data] |> addpredictions(inputs[:clock],
                    requiredcode(env, params, "lookback"),
                    requiredcode(env, params, "model"),
                    paramcolumns(params["predictors"]), Symbol(params["response"]);
                    key = paramkey(params["key"]), name = Symbol(params["name"]),
                    operation = Symbol(params["operation"]), verbosity = params["verbosity"],
                )
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:data],
                    opcall(:addpredictions, inputs[:clock],
                        emitrequiredcode(params, "lookback"),
                        emitrequiredcode(params, "model"),
                        Expr(:vect, emitcolumns(params["predictors"])...),
                        QuoteNode(Symbol(params["response"]));
                        key = emitkey(params["key"]),
                        name = emitsym(unless(params["name"], "prediction")),
                        operation = emitsym(unless(params["operation"], "predict")),
                        verbosity = unless(params["verbosity"], 0)))
            )),
)

register_nodekind!(
    OpKind("modelreports"; category = "models",
        doc = "Replace a column of fitted MLJ models with their fit reports.",
        inputs = ONEINPUT,
        params = [
            Param("column", :column; default = "model"),
            Param("name", :column; default = "report"),
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |> modelreports(; column = Symbol(params["column"]),
                    name = Symbol(params["name"]))
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:modelreports;
                        column = emitsym(unless(params["column"], "model")),
                        name = emitsym(unless(params["name"], "report"))))
            )),
)

# --- acausal --------------------------------------------------------------------------

register_nodekind!(
    OpKind("lead"; category = "acausal", acausal = [:out],
        doc = "Shift every row earlier in time by an offset: the forward-looking view.",
        inputs = ONEINPUT, params = [Param("offset", :code; required = true)],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |>
                      CausalFrames.Acausal.lead(requiredcode(env, params, "offset"))
            ),
        # `lead` and `futurejoin` are exported from CausalFrames.Acausal, which the
        # script imports by name; `settime` deliberately is not (see below).
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:lead, emitrequiredcode(params, "offset")))
            )),
)

register_nodekind!(
    OpKind("futurejoin"; category = "acausal", acausal = [:out],
        doc = "Join each left row to the earliest right row not before it.",
        inputs = [Port(:left), Port(:right)], params = JOINPARAMS,
        build = (params, inputs, env) ->
            (;
                out = inputs[:left] |>
                      CausalFrames.Acausal.futurejoin(
                    inputs[:right];
                    joinkwargs(env, params)...,
                )
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:left],
                    opcall(:futurejoin, inputs[:right]; emitjoinkwargs(params)...))
            )),
)

# `settime` is the causal kind's name, so the forward-looking one gets its own.
register_nodekind!(
    OpKind("acausal_settime"; category = "acausal", acausal = [:out],
        doc = "Recompute the time column, allowing rows to move earlier.",
        inputs = ONEINPUT, params = [Param("spec", :code; required = true)],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |>
                      CausalFrames.Acausal.settime(requiredcode(env, params, "spec"))
            ),
        # Not exported even from the submodule, so that `using CausalFrames.Acausal`
        # leaves the causal `settime` unambiguous: the script says it in full.
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(qualified(:CausalFrames, :Acausal, :settime),
                        emitrequiredcode(params, "spec")))
            )),
)
