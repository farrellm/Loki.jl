# MCP mode: the same session the browser drives, over JSON-RPC on stdin and
# stdout. There is one graph, one cache and one lock, so an agent's edit shows up
# in the browser as it happens and the user's edit is what the agent reads next.
#
# Three things about the transport shape this file. Stdout belongs to the
# JSON-RPC stream, so nothing here prints — `announce` already logs to stderr for
# exactly this reason. `MCP.start!` blocks in its read loop until stdin closes,
# so it runs on a task of its own and `serve_mcp` waits for that task. And
# `MCP.start!` installs its own global logger and never takes it back, so Loki
# remembers the one it displaced and returns it when the server stops.
#
# Every tool answers with one JSON object, and every result an agent receives is
# a summary — a schema, a statistic per column, a test's p-values. The rows
# themselves stay in the browser, where the user can see them.

"""
    Loki.MCPMode

The MCP server running beside a [`Loki.Server`](@ref): the
ModelContextProtocol.jl server, the transport it reads and writes, the task its
read loop runs on, and the global logger it displaced. [`serve_mcp`](@ref)
starts one and [`Loki.stop!`](@ref) ends it.
"""
mutable struct MCPMode
    const server::Any
    const transport::Any
    const logger::Any
    task::Union{Nothing,Task}
end

const MCPINSTRUCTIONS = """
Loki is an interactive time-series workbench built on CausalFrames. A session is
a graph whose nodes are operators and whose edges carry pipelines. You edit that
graph with these tools while the user watches the same graph in a browser and
edits it too.

The loop is: `list_node_kinds` to see what a node can be and what parameters it
takes, `add_node` and `connect` to build, `run` to evaluate, then
`get_result_summary` and `get_diagnostic` to read the outcome. `fit_insample`
does a whole fit-and-check step in one call, and `export_julia` renders the
graph as a plain Julia script — the ground truth of what it means.

Two things to keep in mind. Every result you get back is a summary; the data
itself stays in the browser, so ask for a diagnostic rather than for rows. And
the graph is shared, so read it back with `get_graph` rather than assuming it is
still what you left.
"""

# --- answering ------------------------------------------------------------------

jsoncontent(x) = MCP.TextContent(; text = JSON3.write(x))

# Mapped by type, exactly as `errorresponse` maps them to status codes: a bad
# parameter is the caller's and says what was wrong, and anything unrecognised is
# ours and does not travel as a backtrace.
function toolerror(err)
    payload = if err isa NodeError
        Dict{String,Any}("error" => sprint(showerror, err), "node" => err.id)
    elseif err isa ArgumentError
        Dict{String,Any}("error" => err.msg)
    elseif err isa NotFound
        Dict{String,Any}("error" => err.message)
    elseif err isa NotEvaluated
        Dict{String,Any}("error" => err.message, "id" => err.id,
            "port" => String(err.port))
    else
        @error "Loki MCP tool error" exception = (err, catch_backtrace())
        Dict{String,Any}("error" => "internal error")
    end
    return MCP.CallToolResult(; content = [jsoncontent(payload)], is_error = true)
end

# Every handler runs inside the same two wrappers the HTTP layer uses: the
# session's origin, so a browser can show what the agent just did, and the error
# map, so a tool reports a failure rather than crashing the JSON-RPC session.
function handling(f)
    return function (args::AbstractDict)
        try
            return withorigin(:mcp) do
                jsoncontent(f(args))
            end
        catch err
            err isa InterruptException && rethrow()
            return toolerror(err)
        end
    end
end

# The same, for the handlers that want the request context — the one that
# reports progress.
function handlingctx(f)
    return function (args::AbstractDict, ctx)
        try
            return withorigin(:mcp) do
                jsoncontent(f(args, ctx))
            end
        catch err
            err isa InterruptException && rethrow()
            return toolerror(err)
        end
    end
end

# --- arguments ------------------------------------------------------------------

argvalue(args::AbstractDict, name::AbstractString) = get(args, String(name), nothing)

function needsarg(args::AbstractDict, name::AbstractString)
    v = argvalue(args, name)
    v === nothing && throw(ArgumentError("$name is required"))
    return v
end

# A wrong type is the caller's mistake and says so; `String(3)` would be a
# `MethodError`, which this layer reports as an internal error.
asstring(x::AbstractString) = String(x)
asstring(x::Symbol) = String(x)
asstring(x) = throw(ArgumentError("expected a string, got $(repr(x))"))

argstring(args::AbstractDict, name::AbstractString, default = nothing) =
    (v = argvalue(args, name); v === nothing ? default : asstring(v))

needsstring(args::AbstractDict, name::AbstractString) = asstring(needsarg(args, name))

argcontext(args::AbstractDict) = argstring(args, "context", "analysis")

function argdict(args::AbstractDict, name::AbstractString)
    v = argvalue(args, name)
    v === nothing && return Dict{String,Any}()
    v isa AbstractDict || throw(ArgumentError("$name must be an object"))
    return Dict{String,Any}(String(k) => plainjson(x) for (k, x) in pairs(v))
end

# A port reference travels as `["node_id", "port"]`, the shape `POST /api/edges`
# takes, so the two layers read alike.
function argport(args::AbstractDict, name::AbstractString)
    v = needsarg(args, name)
    (v isa AbstractVector && length(v) == 2) ||
        throw(ArgumentError("$name must be [node_id, port]"))
    return asstring(v[1]), Symbol(asstring(v[2]))
end

# --- the tools ------------------------------------------------------------------

function mcptool(name::AbstractString, description::AbstractString, properties,
    required, handler; readonly::Bool = false, destructive::Bool = false)
    schema = Dict{String,Any}("type" => "object",
        "properties" => Dict{String,Any}(properties),
        "required" => Any[String(r) for r in required],
        "additionalProperties" => false)
    return MCP.MCPTool(; name = String(name), description = String(description),
        input_schema = schema, handler,
        annotations = Dict{String,Any}("readOnlyHint" => readonly,
            "destructiveHint" => destructive))
end

prop(type::AbstractString, description::AbstractString) =
    Dict{String,Any}("type" => type, "description" => description)

portprop(description::AbstractString) = Dict{String,Any}("type" => "array",
    "description" => description, "minItems" => 2, "maxItems" => 2,
    "items" => Dict{String,Any}("type" => "string"))

contextprop() = prop("string",
    "the named context to evaluate over; defaults to \"analysis\"")

# Every kind with every parameter schema is thousands of tokens, and an agent
# wants one kind's schema at a time. So the unfiltered listing is a catalog —
# names, categories, ports — and a filtered one carries the schemas.
function listnodekinds(args::AbstractDict)
    name = argstring(args, "kind")
    name === nothing || return Dict{String,Any}("kinds" => Any[nodekindjson(name)])
    category = argstring(args, "category")
    category === nothing ||
        return Dict{String,Any}("kinds" => Any[nodekindjson(n) for n in kindsin(category)])
    return Dict{String,Any}("kinds" => Any[kindcatalog(n) for n in nodekinds()],
        "note" => "pass `kind` or `category` for the parameter schemas")
end

function kindsin(category::AbstractString)
    names = [n for n in nodekinds() if categoryof(nodekind(n)) == category]
    isempty(names) && throw(ArgumentError("no node kind is in category \
        $(repr(String(category))); there is $(join(categories(), ", "))"))
    return names
end

categories() = sort!(unique!([categoryof(nodekind(n)) for n in nodekinds()]))

# A kind without its parameter schema: what it is and what it connects to.
function kindcatalog(name::AbstractString)
    full = nodekindjson(name)
    return Dict{String,Any}(
        k => full[k] for k in
        ("name", "category", "doc", "inputs", "outputs", "acausal", "write")
    )
end

readonlytools(s::Session) = MCP.MCPTool[
    mcptool("list_node_kinds",
        "The node kinds a graph can hold. With no argument, the catalog: every \
        kind's name, category, ports and one-line doc. With `kind` or \
        `category`, those kinds in full, each with the JSON Schema of its \
        parameters — which is what `add_node` and `update_node` take as \
        `params` — and the order a form would show them in.",
        Dict("kind" => prop("string", "one kind by name"),
            "category" => prop("string",
                "every kind in one palette category: sources, files, rows, \
                columns, summarizing, joins, time series, models or acausal"),
        ),
        (), handling(listnodekinds); readonly = true),
    mcptool("get_graph",
        "The whole session: every node with its kind, parameters, status, error \
        and acausal taint; every edge; the named contexts; the in-memory \
        tables; the prelude; and the run in flight, if there is one.",
        Dict("context" => contextprop()), (),
        handling(args -> graphjson(s; context = argcontext(args))); readonly = true),
    mcptool("get_web_url",
        "The URLs the user opens this session at, each carrying the session \
        token: the loopback one, and the `tailscale serve` one when the server \
        was given a `public_url`. Hand these to the user rather than opening \
        them yourself.",
        Dict{String,Any}(), (), handling(_ -> weburls(s)); readonly = true),
]

function weburls(s::Session)
    srv = needserver(s)
    return Dict{String,Any}("url" => weburl(srv),
        "public" => srv.public_url === nothing ? nothing : weburl(srv; public = true))
end

# --- editing the graph ------------------------------------------------------------
#
# Each of these returns what its REST twin returns, so the two layers read alike
# and a browser refetching after an agent's edit sees the same thing the agent
# was told. The per-kind parameter schema is not on these tools — one `add_node`
# cannot carry forty-nine of them — so `params` is an open object here and
# `list_node_kinds` is where its schema comes from.

function argposition(args::AbstractDict)
    v = argvalue(args, "position")
    v === nothing && return (0.0, 0.0)
    (v isa AbstractVector && length(v) == 2 && all(x -> x isa Real, v)) ||
        throw(ArgumentError("position must be [x, y], two numbers"))
    return (Float64(v[1]), Float64(v[2]))
end

nodepayload(s::Session, id::AbstractString) =
    Dict{String,Any}("node" => nodeevent(lock(() -> getnode(s.graph, id), s.lock)))

function addnodetool(s::Session, args::AbstractDict)
    id = addnode!(s, needsstring(args, "kind"), argdict(args, "params");
        id = argstring(args, "id"), position = argposition(args))
    return merge(Dict{String,Any}("id" => id), nodepayload(s, id))
end

function updatenodetool(s::Session, args::AbstractDict)
    id = needsnode(s, needsstring(args, "id"))
    params = argvalue(args, "params")
    position = argvalue(args, "position")
    (params === nothing && position === nothing) &&
        throw(ArgumentError("give params, position, or both"))
    # Merged, not replaced, and a `null` removes one — `PATCH /api/nodes/:id`'s
    # rule, for its reason: two quick edits built from the same copy would
    # silently undo one another.
    params === nothing || updatenode!(s, id,
        mergeparams(lock(() -> getnode(s.graph, id).params, s.lock),
            argdict(args, "params")))
    position === nothing || setposition!(s, id, argposition(args))
    return nodepayload(s, id)
end

function removenodetool(s::Session, args::AbstractDict)
    removenode!(s, needsnode(s, needsstring(args, "id")))
    return Dict{String,Any}("ok" => true)
end

connecttool(s::Session, args::AbstractDict) =
    Dict{String,Any}(
        "id" => connect!(s, argport(args, "from"), argport(args, "to");
            id = argstring(args, "id")),
    )

function disconnecttool(s::Session, args::AbstractDict)
    id = needsstring(args, "id")
    lock(s.lock) do
        any(e -> e.id == id, s.graph.edges) ||
            throw(NotFound("no edge $(repr(id))"))
    end
    disconnect!(s, id)
    return Dict{String,Any}("ok" => true)
end

function setcontexttool(s::Session, args::AbstractDict)
    name = needsstring(args, "name")
    ctx = readcontext((; timetype = needsstring(args, "timetype"),
        start = needsarg(args, "start"), stop = needsarg(args, "stop")))
    setcontext!(s, name, ctx)
    return Dict{String,Any}("name" => name, "context" => contextevent(ctx))
end

# A CSV or parquet on the machine Loki runs on, read into memory through the
# same DuckDB reader an upload from the browser goes through.
function loadtabletool(s::Session, args::AbstractDict)
    name = needsstring(args, "name")
    path = abspath(expanduser(needsstring(args, "path")))
    isfile(path) || throw(NotFound("no file $(repr(path))"))
    format = argstring(args, "format")
    table = readuploadedtable(read(path), format === nothing ? tableformat(path) : format)
    addtable!(s, name, table)
    return Dict{String,Any}("name" => name, "path" => path,
        "table" => tableevent(lock(() -> s.tables[name], s.lock)))
end

function tableformat(path::AbstractString)
    ext = lowercase(last(splitext(path)))
    ext == ".csv" && return "csv"
    ext in (".parquet", ".pq") && return "parquet"
    return throw(ArgumentError("cannot tell the format of $(repr(path)) from its \
        extension; pass format as \"csv\" or \"parquet\""))
end

edittools(s::Session) = MCP.MCPTool[
    mcptool("add_node",
        "Add a node. `params` is the kind's own parameter object, whose JSON \
        Schema `list_node_kinds` publishes for that kind — a parameter may be \
        left out while the node is still being built up. Returns the new \
        node's id, which is what `connect` takes.",
        Dict("kind" => prop("string", "the node kind, from `list_node_kinds`"),
            "params" => Dict{String,Any}("type" => "object",
                "description" => "the kind's parameters"),
            "id" => prop("string", "an id to give it, rather than the next one"),
            "position" => Dict{String,Any}("type" => "array",
                "description" => "where it sits on the canvas, as [x, y]",
                "minItems" => 2, "maxItems" => 2,
                "items" => Dict{String,Any}("type" => "number"))),
        ("kind",), handling(args -> addnodetool(s, args))),
    mcptool("update_node",
        "Change a node's parameters or move it. The parameters given are \
        merged into the node's, and a null removes one, so changing a single \
        parameter takes a single key. Editing parameters invalidates the node \
        and everything downstream; moving it does not.",
        Dict("id" => prop("string", "the node"),
            "params" => Dict{String,Any}("type" => "object",
                "description" => "parameters to merge in; a null removes one"),
            "position" => Dict{String,Any}("type" => "array",
                "description" => "where it sits on the canvas, as [x, y]",
                "minItems" => 2, "maxItems" => 2,
                "items" => Dict{String,Any}("type" => "number"))),
        ("id",), handling(args -> updatenodetool(s, args))),
    mcptool("remove_node",
        "Remove a node and every edge touching it.",
        Dict("id" => prop("string", "the node")), ("id",),
        handling(args -> removenodetool(s, args)); destructive = true),
    mcptool("connect",
        "Connect an output port to an input port. A single-input port takes \
        one edge; a variadic one takes them in order. A connection that would \
        make a cycle is refused.",
        Dict("from" => portprop("the source, as [node_id, output_port]"),
            "to" => portprop("the destination, as [node_id, input_port]"),
            "id" => prop("string", "an id to give the edge")),
        ("from", "to"), handling(args -> connecttool(s, args))),
    mcptool("disconnect", "Remove one edge, by its id.",
        Dict("id" => prop("string", "the edge")), ("id",),
        handling(args -> disconnecttool(s, args)); destructive = true),
    mcptool("set_context",
        "Define or redefine a named evaluation window. A session always has \
        `analysis`, the window nodes are run over; more — `train`, `test`, a \
        short `preview` — are named by node parameters and by `run`. The time \
        type must match the sources'.",
        Dict("name" => prop("string", "the context's name"),
            "timetype" => Dict{String,Any}("type" => "string",
                "description" => "the time column's type",
                "enum" => ["Int64", "Float64", "Date", "DateTime"]),
            "start" => Dict{String,Any}("description" => "the window's start, \
                a number or an ISO 8601 date or timestamp"),
            "stop" => Dict{String,Any}("description" => "the window's stop")),
        ("name", "timetype", "start", "stop"),
        handling(args -> setcontexttool(s, args))),
    mcptool("load_table",
        "Read a CSV or parquet file on the machine Loki runs on into memory \
        under a name, which a `table` or `lookupjoin` node then refers to.",
        Dict("name" => prop("string", "the name to hold it under"),
            "path" => prop("string", "the file, on the server's filesystem"),
            "format" => Dict{String,Any}("type" => "string",
                "description" => "the file's format; taken from the extension \
                    when it is not given",
                "enum" => ["csv", "parquet"])),
        ("name", "path"), handling(args -> loadtabletool(s, args))),
]

# --- evaluating and reading back ---------------------------------------------------

# A target is a node id, for all of its output ports, or one `[id, port]` — the
# shapes `POST /api/run` and `Loki.run!` already take.
function argtargets(args::AbstractDict)
    v = needsarg(args, "targets")
    (v isa AbstractVector && !isempty(v)) ||
        throw(ArgumentError("targets must be a non-empty list of node ids or \
            [node_id, port] pairs"))
    return Any[
        t isa AbstractVector ? (asstring(t[1]), Symbol(asstring(t[2]))) :
        asstring(t) for t in v
    ]
end

# The engine calls this once per chunk per target, which is far more often than
# a client wants to hear; throttled to the interval the event stream uses. The
# reported number is cumulative because MCP progress must not go backwards.
function progressreporter(ctx)
    last = Ref(0.0)
    seen = Threads.Atomic{Int}(0)
    return function (id::AbstractString, port::Symbol, rows::Integer)
        total = Threads.atomic_add!(seen, Int(rows)) + Int(rows)
        now = time()
        now - last[] < PROGRESSINTERVAL && return nothing
        last[] = now
        quietly(
            () -> MCP.send_progress(ctx, Float64(total);
                message = "$id.$port: $total rows"),
        )
        return nothing
    end
end

function runtool(s::Session, args::AbstractDict, ctx)
    context = argcontext(args)
    run = run!(s, argtargets(args); context, progress = progressreporter(ctx))
    Base.wait(run)
    return runreport(s, run, context)
end

function runreport(s::Session, run::Run, context::AbstractString)
    targets = Any[targetreport(s, id, port, context) for (id, port) in run.targets]
    # Which node actually failed is rarely the target: a target is `blocked` and
    # the error is upstream, so the whole error map goes back with the report.
    failed = lock(s.lock) do
        Dict{String,Any}(id => sprint(showerror, e) for (id, e) in s.errors)
    end
    return Dict{String,Any}("context" => context, "targets" => targets,
        "cancelled" => run.cancelled[], "errors" => failed)
end

function targetreport(s::Session, id::AbstractString, port::Symbol,
    context::AbstractString)
    out = Dict{String,Any}("id" => String(id), "port" => String(port),
        "status" => String(status(s, id)), "acausal" => isacausal(s, id; port))
    frame = result(s, id; port, context)
    frame === nothing || merge!(out, frameevent(frame))
    err = nodeerror(s, id)
    err === nothing || (out["error"] = sprint(showerror, err))
    return out
end

# A node's output port, defaulting to its first — the HTTP routes take it from
# the path and so always have one.
function argresult(s::Session, args::AbstractDict)
    id = needsnode(s, needsstring(args, "id"))
    port = argvalue(args, "port")
    portname = lock(() -> outputport(s, id, port), s.lock)
    return needsresult(s, id, portname, argcontext(args))
end

resultsummarytool(s::Session, args::AbstractDict) =
    resultsummary(first(argresult(s, args)); columns = querycolumns(args),
        key = querykey(args), head = queryint(args, "head", 5),
        tail = queryint(args, "tail", 5))

# A diagnostic without its plot-ready arrays. `acf` and `pacf` already carry
# their values and their significant lags in the summary, and a test carries its
# statistic and p-values, so dropping `data` costs an agent nothing it asked
# for — except for the forecast fan, which is why `include_data` exists.
function diagnosticsummary(r::DiagnosticResult; data::Bool = false)
    out = Dict{String,Any}("kind" => String(r.kind), "summary" => r.summary,
        "warnings" => r.warnings)
    isempty(r.panels) || (
        out["panels"] = Dict{String,Any}(
            k => diagnosticsummary(v; data) for (k, v) in r.panels)
    )
    data && (out["data"] = r.data)
    return out
end

function diagnostictool(s::Session, args::AbstractDict)
    frame, node = argresult(s, args)
    kind = needsstring(args, "kind")
    params = diagnosticparams(s, node, kind, argcontext(args), argdict(args, "params"))
    return diagnosticsummary(diagnostic(frame, kind; params);
        data = querybool(args, "include_data", false))
end

# One step of the identification loop: fit a model on a port, run the in-sample
# residuals, and report what they say about it. The node stays in the graph — it
# is the thing being proposed — but a fit that cannot even be wired is taken
# back out, so a rejected proposal leaves nothing behind.
function fitinsampletool(s::Session, args::AbstractDict)
    from = argport(args, "from")
    params = argdict(args, "params")
    haskey(params, "column") ||
        throw(ArgumentError("a fit needs the column it is fitted to"))
    id = addnode!(s, "fit", params; position = argposition(args))
    try
        connect!(s, from, (id, :in))
    catch
        removenode!(s, id)
        rethrow()
    end
    context = argcontext(args)
    run = run!(s, [(id, :insample)]; context)
    Base.wait(run)
    out = merge(Dict{String,Any}("id" => id), runreport(s, run, context))
    frame = result(s, id; port = :insample, context)
    frame === nothing && return out
    node = lock(() -> getnode(s.graph, id), s.lock)
    residualparams = diagnosticparams(s, node, "residuals", context,
        Dict{String,Any}("column" => params["column"]))
    out["residuals"] =
        diagnosticsummary(diagnostic(frame, "residuals"; params = residualparams))
    return out
end

evaltools(s::Session) = MCP.MCPTool[
    mcptool("run",
        "Evaluate nodes and wait for them. A target is a node id, for all of \
        its output ports, or a [node_id, port] pair. Reports each target's \
        status, row count and columns, and every node that errored — which is \
        rarely the target, because a target downstream of a failure is \
        `blocked` and the error is upstream.",
        Dict(
            "targets" => Dict{String,Any}("type" => "array",
                "description" => "node ids, or [node_id, port] pairs",
                "items" => Dict{String,Any}(
                    "anyOf" => Any[
                        Dict{String,Any}("type" => "string"),
                        Dict{String,Any}("type" => "array",
                            "items" => Dict{String,Any}("type" => "string"),
                        )],
                )),
            "context" => contextprop()),
        ("targets",), handlingctx((args, ctx) -> runtool(s, args, ctx))),
    mcptool("get_result_summary",
        "What a node produced, sized for reading: the schema, the row count, a \
        statistic per column, and the first and last few rows. Run the node \
        first — an unevaluated node says so rather than pretending to be empty.",
        Dict("id" => prop("string", "the node"),
            "port" => prop("string", "its output port; the first by default"),
            "context" => contextprop(),
            "columns" => prop("string", "only these columns, comma-separated"),
            "key" => prop("string", "only the rows matching, as \"col=value\""),
            "head" => prop("integer", "rows from the start; 5 by default"),
            "tail" => prop("integer", "rows from the end; 5 by default")),
        ("id",), handling(args -> resultsummarytool(s, args)); readonly = true),
    mcptool("get_diagnostic",
        "Run a diagnostic over a node's output and return its numeric summary: \
        ACF and PACF values with the lags outside the significance band, a \
        test's statistic and p-values, a fit's information criteria. The \
        plot-ready arrays are left out unless `include_data` asks for them — \
        the user has the plot in the browser.",
        Dict("id" => prop("string", "the node"),
            "port" => prop("string", "its output port; the first by default"),
            "kind" => Dict{String,Any}("type" => "string",
                "description" => "the diagnostic to run", "enum" => diagnostics()),
            "params" => Dict{String,Any}("type" => "object",
                "description" => "the diagnostic's arguments: `column`, `lags`, \
                    `key`, `level`, and whatever else it takes"),
            "include_data" => prop("boolean",
                "also return the plot-ready arrays; false by default"),
            "context" => contextprop()),
        ("id", "kind"), handling(args -> diagnostictool(s, args)); readonly = true),
    mcptool("fit_insample",
        "Propose a fit and check it in one step: add a `fit` node on an output \
        port, run its acausal in-sample residuals, and report what they say — \
        Ljung–Box p-values at several lag counts, the residual lags outside \
        the band, and the fit's information criteria. The node stays in the \
        graph under the id this returns, so a promising fit is already wired.",
        Dict("from" => portprop("the series to fit, as [node_id, output_port]"),
            "params" => Dict{String,Any}("type" => "object",
                "description" => "the `fit` kind's parameters — `family`, \
                    `column`, `order` and the rest; `list_node_kinds` with \
                    kind \"fit\" has the schema"),
            "position" => Dict{String,Any}("type" => "array",
                "description" => "where the new node sits, as [x, y]",
                "minItems" => 2, "maxItems" => 2,
                "items" => Dict{String,Any}("type" => "number")),
            "context" => contextprop()),
        ("from", "params"), handling(args -> fitinsampletool(s, args))),
]

mcptools(s::Session) = vcat(readonlytools(s), edittools(s), evaltools(s))

# --- the resources ---------------------------------------------------------------

mcpresources(s::Session) = MCP.MCPResource[
    MCP.MCPResource(; uri = "loki://graph", name = "graph",
    description = "The session's graph, as `get_graph` returns it.",
    mime_type = "application/json", data_provider = () -> graphjson(s)),
]

mcptemplates(s::Session) = MCP.ResourceTemplate[
    MCP.ResourceTemplate(; name = "node result",
    uri_template = "loki://node/{id}/result", mime_type = "application/json",
    description = "A node's output over the analysis context, as \
            `get_result_summary` returns it for its first port.",
    data_provider = (_, vars) -> noderesult(s, vars)),
]

function noderesult(s::Session, vars)
    id = needsnode(s, String(vars["id"]))
    frame, _ = needsresult(s, id, lock(() -> outputport(s, id, nothing), s.lock),
        "analysis")
    return resultsummary(frame)
end

# --- starting and stopping ---------------------------------------------------------

function mcpserver(s::Session)
    return MCP.mcp_server(; name = "loki", version = string(pkgversion(Loki)),
        title = "Loki", description = "Interactive time-series analysis on CausalFrames.",
        instructions = MCPINSTRUCTIONS, tools = mcptools(s),
        resources = mcpresources(s), resource_templates = mcptemplates(s))
end

"""
    serve_mcp(; port = 8712, public_url = get(ENV, "LOKI_PUBLIC_URL", nothing),
              tables = (;), contexts = (;), prelude = "", cachebytes = 2^30,
              token = Loki.newtoken(), open_browser = false) -> Session
    serve_mcp(s::Session; wait = true, transport = nothing, kwargs...) -> Session

Everything [`serve`](@ref) does, and an MCP server over **stdio** in the same
process against the same session: the agent's edits appear live in the browser
and the user's edits are what the agent reads next, because there is one graph,
one cache and one lock.

A Claude Code configuration is one line:

```json
{ "mcpServers": { "loki": { "command": "julia", "args": ["-e", "using Loki; Loki.serve_mcp()"] } } }
```

So this **blocks** until the client closes stdin, and stops the web server on
its way out. `wait = false` returns the session with the MCP read loop on a task
of its own — for a REPL, and for tests that drive `transport` over a pipe.

Stdout belongs to the JSON-RPC stream: the URLs to open the browser at go to
stderr at startup, and to the `get_web_url` tool.
"""
function serve_mcp(s::Session; wait::Bool = true, transport = nothing,
    open_browser::Bool = false, kwargs...)
    serve(s; open_browser, kwargs...)
    try
        srv = needserver(s)
        mode = MCPMode(mcpserver(s),
            transport === nothing ? MCP.StdioTransport() : transport,
            Logging.global_logger(), nothing)
        srv.mcp = mode
        mode.task = Threads.@spawn MCP.start!(mode.server; transport = mode.transport)
        # `wait` the keyword shadows the function, as `port` does in `serve`.
        wait || return s
        Base.wait(mode.task)
    catch
        # A server that could not be built, or a read loop that died, must not
        # leave the web server listening behind it. `stop!` on a stopped session
        # is a no-op, so the `finally` below can run too.
        quietly(() -> stop!(s))
        rethrow()
    finally
        wait && stop!(s)
    end
    return s
end

serve_mcp(; tables = (;), contexts = (;), prelude::AbstractString = "",
    cachebytes::Integer = 2^30, kwargs...) =
    serve_mcp(Session(; tables, contexts, prelude, cachebytes); kwargs...)

# The read loop blocks in `readline`, and `MCP.stop!` only takes effect on the
# next message, so ending it means giving it the EOF it is waiting for: closing
# the transport itself just flips a flag, so the input stream is closed too. The
# logger goes back the way it was, because `MCP.start!` takes the global one and
# never returns it, and a session served and stopped inside a larger process —
# the test suite — must not keep it.
function stopmcp!(srv::Server)
    mode = srv.mcp
    mode === nothing && return nothing
    srv.mcp = nothing
    quietly(() -> mode.server.active && MCP.stop!(mode.server))
    quietly(() -> close(mode.transport))
    quietly(() -> hasproperty(mode.transport, :input) && close(mode.transport.input))
    if mode.task !== nothing
        # Bounded: a transport whose input will not close must not wedge `stop!`.
        timedwait(() -> istaskdone(mode.task), 10.0)
        istaskdone(mode.task) ? quietly(() -> Base.wait(mode.task)) :
        @warn "the Loki MCP read loop did not stop"
    end
    Logging.global_logger(mode.logger)
    return nothing
end

function quietly(f)
    try
        f()
    catch err
        err isa InterruptException && rethrow()
        @debug "error while stopping the Loki MCP server" exception = err
    end
    return nothing
end
