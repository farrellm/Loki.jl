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

mcptools(s::Session) = readonlytools(s)

# --- the resources ---------------------------------------------------------------

mcpresources(s::Session) = MCP.MCPResource[
    MCP.MCPResource(; uri = "loki://graph", name = "graph",
    description = "The session's graph, as `get_graph` returns it.",
    mime_type = "application/json", data_provider = () -> graphjson(s)),
]

mcptemplates(::Session) = MCP.ResourceTemplate[]

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
