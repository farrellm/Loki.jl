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

const KEY = Param("key", :columns; description = "key column(s): state is kept per key")
const SELECTION = [
    Param("columns", :columns; description = "column names"),
    Param("match", :code; description = "a Regex or a predicate on the column name"),
]
const SUMMARIZERLIST = Param("summarizers", :summarizers; required = true)
const ONEINPUT = [Port(:in)]

# --- summarizer entries --------------------------------------------------------------

# Option converters: (value, env) -> argument.
asis(v, ::BuildEnv) = v
assymbol(v, ::BuildEnv) = Symbol(v)
astuple(v, ::BuildEnv) = Tuple(v)
ascode(v, env::BuildEnv) = evalcode(env.usercode, v; what = "summarizer option")

# A summarizer constructor from an entry's columns and options: `columns` is the
# number of column arguments (-1: one vector of at least one), `positional` the
# required options passed after them, `keywords` the optional ones.
function summarymaker(f, what::String; columns::Int, positional = (), keywords = ())
    known = (first.(positional)..., first.(keywords)...)
    return function (cols::Vector{Symbol}, opts::Dict{String,Any}, env::BuildEnv)
        if columns < 0
            isempty(cols) && throw(ArgumentError("$what needs at least one column"))
        elseif length(cols) != columns
            throw(ArgumentError("$what takes $columns column(s), got $(length(cols))"))
        end
        for k in keys(opts)
            k in known || throw(ArgumentError("$what has no option $(repr(k))"))
        end
        pos = map(positional) do (k, convert)
            haskey(opts, k) || throw(ArgumentError("$what needs the option $(repr(k))"))
            convert(opts[k], env)
        end
        kws = (;
            (
                Symbol(k) => convert(opts[k], env) for (k, convert) in keywords
                if haskey(opts, k)
            )...
        )
        colargs = columns < 0 ? (cols,) : Tuple(cols)
        return f(colargs..., pos...; kws...)
    end
end

const SUMMARIZERS = Dict{String,Any}(
    "Count" => summarymaker(Count, "Count"; columns = 0),
    "CountDistinct" => summarymaker(CountDistinct, "CountDistinct"; columns = 1),
    "Sum" => summarymaker(Sum, "Sum"; columns = 1),
    "Product" => summarymaker(Product, "Product"; columns = 1),
    "Mean" => summarymaker(Mean, "Mean"; columns = 1),
    "Min" => summarymaker(Min, "Min"; columns = 1),
    "Max" => summarymaker(Max, "Max"; columns = 1),
    "First" => summarymaker(First, "First"; columns = 1),
    "Last" => summarymaker(Last, "Last"; columns = 1),
    "SumPower" =>
        summarymaker(SumPower, "SumPower"; columns = 1, positional = ("n" => asis,)),
    "Moment" =>
        summarymaker(Moment, "Moment"; columns = 1, positional = ("n" => asis,)),
    "Variance" => summarymaker(Variance, "Variance"; columns = 1,
        keywords = ("corrected" => asis,)),
    "Std" => summarymaker(Std, "Std"; columns = 1, keywords = ("corrected" => asis,)),
    "DotProduct" => summarymaker(DotProduct, "DotProduct"; columns = 2),
    "Correlation" => summarymaker(Correlation, "Correlation"; columns = 2),
    "Covariance" => summarymaker(Covariance, "Covariance"; columns = 2,
        keywords = ("corrected" => asis,)),
    "LinearRegression" => summarymaker(LinearRegression, "LinearRegression";
        columns = -1, positional = ("response" => assymbol,),
        keywords = ("intercept" => asis, "name" => assymbol)),
    "FitModel" => summarymaker(
        (cols, response; model, kws...) -> FitModel(model, cols, response; kws...),
        "FitModel"; columns = -1, positional = ("response" => assymbol,),
        keywords = ("model" => ascode, "name" => assymbol, "verbosity" => asis)),
    "Lags" => summarymaker(Lags, "Lags"; columns = 1, positional = ("p" => asis,),
        keywords = ("name" => assymbol,)),
    "EMA" => summarymaker(EMA, "EMA"; columns = 1,
        keywords = ("span" => asis, "halflife" => ascode, "name" => assymbol)),
    "FitARMA" => summarymaker(FitARMA, "FitARMA"; columns = 1,
        keywords = ("order" => astuple, "seasonal_order" => astuple,
            "include_mean" => asis, "name" => assymbol)),
)

# The summarizers named by a `:summarizers` parameter: entries of the form
# `{"summarizer": name, "columns": [...], "options": {...}}`.
function summarizers(env::BuildEnv, entries)
    (entries === nothing || isempty(entries)) &&
        throw(ArgumentError("at least one summarizer is required"))
    return Summarizer[summarizer(env, entry) for entry in entries]
end

function summarizer(env::BuildEnv, entry::AbstractDict)
    e = stringkeys(entry)
    for k in keys(e)
        k in ("summarizer", "columns", "options") ||
            throw(ArgumentError("a summarizer entry has no field $(repr(k))"))
    end
    name = get(e, "summarizer", nothing)
    name isa AbstractString ||
        throw(ArgumentError("a summarizer entry needs a \"summarizer\" name"))
    maker = get(SUMMARIZERS, name, nothing)
    maker === nothing && throw(ArgumentError("unknown summarizer $(repr(name)); \
        known: $(join(sort!(collect(keys(SUMMARIZERS))), ", "))"))
    options = get(e, "options", nothing)
    return maker(paramcolumns(get(e, "columns", nothing)),
        options === nothing ? Dict{String,Any}() : stringkeys(options), env)
end

# --- sources -----------------------------------------------------------------------

register_nodekind!(
    OpKind("emptyframe"; category = "sources",
        doc = "A source that produces no rows.",
        build = (params, inputs, env) -> (; out = emptyframe())),
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
            )),
)

register_nodekind!(
    OpKind("concatenate"; category = "sources",
        doc = "The inputs' outputs end to end, in connection order.",
        inputs = [Port(:in; variadic = true)],
        build = (params, inputs, env) ->
            (; out = concatenate(atleastone(inputs[:in], "concatenate")...))),
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
        build = (params, inputs, env) -> (; out = tablesource(env, params))),
)

function tablesource(env::BuildEnv, params::AbstractDict)
    table = namedtable(env, params["table"])
    closed = params["closed"] === nothing ? (;) : (; closed = params["closed"])
    if table isa CausalFrame
        # A frame's time is resolved and sorted already; it keeps readtable's frame
        # semantics, refusing a context outside its own.
        params["time"] === nothing && !params["sort"] ||
            throw(ArgumentError("table $(params["table"]) is a loaded frame, whose time \
                column is already resolved"))
        return readtable(table; closed...)
    end
    return readtable(table; time = paramsym(params["time"]), sort = params["sort"],
        checkorder = params["checkorder"], closed...)
end

# --- files --------------------------------------------------------------------------

const PATH = Param("path", :string; required = true)
const QUEUE = Param("queue", :integer; default = 1)
const BACKEND = Param("backend", :enum; choices = ["auto", "duckdb", "parquet2"],
    default = "auto")
const SORT = Param("sort", :boolean; default = false,
    description = "sort the rows by time, for a file not stored in time order")

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
            Param("chunkbytes", :integer; default = 4 * 1024 * 1024),
        ],
        build = (params, inputs, env) ->
            (;
                out = readcsv(params["path"]; types = paramcode(env, params, "types"),
                    time = paramcode(env, params, "time"),
                    rename = paramcode(env, params, "rename"), delim = params["delim"],
                    sort = params["sort"], chunkbytes = params["chunkbytes"])
            )),
)

register_nodekind!(
    OpKind("writecsv"; category = "files", write = true,
        doc = "Write the stream to a CSV file as it flows by.",
        inputs = ONEINPUT, params = [PATH, QUEUE],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> writecsv(params["path"]; queue = params["queue"]))),
)

register_nodekind!(
    OpKind("readparquet"; category = "files",
        doc = "Read a parquet file.",
        params = [PATH, Param("time", :code), Param("rename", :code), SORT, BACKEND],
        build = (params, inputs, env) ->
            (;
                out = readparquet(params["path"]; time = paramcode(env, params, "time"),
                    rename = paramcode(env, params, "rename"), sort = params["sort"],
                    backend = Symbol(params["backend"]))
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
            )),
)

register_nodekind!(
    OpKind("readjls"; category = "files",
        doc = "Read a file written by writejls.",
        params = [PATH],
        build = (params, inputs, env) -> (; out = readjls(params["path"]))),
)

register_nodekind!(
    OpKind("writejls"; category = "files", write = true,
        doc = "Write the stream through Julia's Serialization as it flows by.",
        inputs = ONEINPUT, params = [PATH, QUEUE],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> writejls(params["path"]; queue = params["queue"]))),
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
            (; out = inputs[:in] |> filterrows(requiredcode(env, params, "predicate")))),
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
            (; out = inputs[:in] |> addcolumns(requiredcode(env, params, "function")))),
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
                (; out = inputs[:in] |> op(selectors(env, params)...))),
    )
end

register_nodekind!(
    OpKind("lag"; category = "rows",
        doc = "Shift every row later in time by an offset.",
        inputs = ONEINPUT, params = [Param("offset", :code; required = true)],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> lag(requiredcode(env, params, "offset")))),
)

register_nodekind!(
    OpKind("head"; category = "rows",
        doc = "The first n rows.",
        inputs = ONEINPUT, params = [Param("n", :integer; required = true)],
        build = (params, inputs, env) -> (; out = inputs[:in] |> head(params["n"]))),
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
            (; out = inputs[:in] |> settime(requiredcode(env, params, "spec")))),
)

register_nodekind!(
    OpKind("lastrow"; category = "rows",
        doc = "The last row (per key), at the window's stop.",
        inputs = ONEINPUT, params = [KEY],
        build = (params, inputs, env) ->
            (; out = inputs[:in] |> lastrow(; key = paramkey(params["key"])))),
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
            (; out = inputs[:in] |> sortcycles(sortkey(env, params); rev = params["rev"]))),
)

# `sortcycles`' `by`: the named columns or a key function, exactly one of them.
function sortkey(env::BuildEnv, params::AbstractDict)
    (params["columns"] === nothing) == (params["function"] === nothing) &&
        throw(ArgumentError("sort by columns or by a function, exactly one of them"))
    params["columns"] === nothing && return paramcode(env, params, "function")
    return paramcolumns(params["columns"])
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
            (; out = inputs[:in] |> fillmissing(requiredcode(env, params, "values")))),
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

register_nodekind!(
    OpKind("asofjoin"; category = "joins",
        doc = "Join each left row to the latest right row not after it.",
        inputs = [Port(:left), Port(:right)], params = JOINPARAMS,
        build = (params, inputs, env) ->
            (; out = inputs[:left] |> asofjoin(inputs[:right]; joinkwargs(env, params)...)),
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
            )),
)
