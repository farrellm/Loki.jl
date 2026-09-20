# MCP mode driven over a pipe. The transport takes any `IO`, so the server runs
# in this process against a pair of `BufferStream`s and the tests speak JSON-RPC
# to it directly: no second Julia to load, and the live session is still
# reachable over HTTP and the WebSocket, which is how an agent's edit gets
# checked for its origin.
#
# Everything here must leave no task behind — closing the client's end of the
# pipe is what gives the read loop its EOF — or Aqua's persistent-tasks check
# fails and every test after this one goes with it.

using HTTP: HTTP
using JSON3: JSON3
using Logging: global_logger
using Random: Xoshiro, randn

function mcpsession()
    df = DataFrame(time = 1:80, x = Float64.(1:80), k = repeat(["a", "b"], 40),
        y = cumsum(randn(Xoshiro(11), 80)))
    return Loki.Session(; tables = (df = df,),
        contexts = (analysis = Context(0, 81), train = Context(0, 41)))
end

mutable struct MCPClient
    const session::Loki.Session
    const input::Base.BufferStream
    const output::Base.BufferStream
    id::Int
end

function withmcp(body; session = nothing,
    public_url = "https://ws.example-tailnet.ts.net")
    s = session === nothing ? mcpsession() : session
    cin, cout = Base.BufferStream(), Base.BufferStream()
    Loki.serve_mcp(s; port = 0, wait = false, public_url,
        transport = Loki.MCP.StdioTransport(; input = cin, output = cout))
    client = MCPClient(s, cin, cout, 0)
    try
        initialize!(client)
        body(client)
    finally
        close(cin)
        Loki.stop!(s)
        close(cout)
    end
end

function send!(c::MCPClient, method::AbstractString, params)
    c.id += 1
    write(c.input,
        JSON3.write(
            Dict("jsonrpc" => "2.0", "id" => c.id, "method" => method,
                "params" => params),
        ) * "\n")
    flush(c.input)
    return c.id
end

function notify!(c::MCPClient, method::AbstractString, params)
    write(c.input,
        JSON3.write(Dict("jsonrpc" => "2.0", "method" => method,
            "params" => params)) * "\n")
    flush(c.input)
    return nothing
end

# Replies and notifications share one stream — the server's own `@info` travels
# as `notifications/message` once the session is up — so a reply is the message
# carrying the id we asked with.
function reply(c::MCPClient, id::Integer)
    while true
        line = readline(c.output)
        if isempty(line)
            eof(c.output) && error("the MCP server closed the stream before \
                answering request $id")
            continue
        end
        msg = JSON3.read(line)
        get(msg, :id, nothing) == id && return msg
    end
end

function initialize!(c::MCPClient)
    id = send!(c, "initialize",
        Dict("protocolVersion" => Loki.MCP.LATEST_PROTOCOL_VERSION,
            "capabilities" => Dict{String,Any}(),
            "clientInfo" => Dict("name" => "loki-tests", "version" => "1")))
    r = reply(c, id)
    notify!(c, "notifications/initialized", Dict{String,Any}())
    return r
end

request(c::MCPClient, method::AbstractString, params = Dict{String,Any}()) =
    reply(c, send!(c, method, params))

# One tool call: the JSON its one text content carries, and whether the tool
# reported a failure. A JSON-RPC-level error is a bug in the layer, not a tool
# result, so it raises here.
function call(c::MCPClient, name::AbstractString, args = Dict{String,Any}())
    r = request(c, "tools/call", Dict("name" => name, "arguments" => args))
    haskey(r, :error) && error("tools/call $name: $(r.error.message)")
    res = r.result
    return JSON3.read(res.content[1].text), get(res, :isError, false)
end

# The payload of a call that must have succeeded.
function called(c::MCPClient, name::AbstractString, args = Dict{String,Any}())
    payload, failed = call(c, name, args)
    failed && error("tools/call $name failed: $(get(payload, :error, payload))")
    return payload
end

@testset "mcp" begin
    @testset "the handshake" begin
        logger = global_logger()
        s = mcpsession()
        withmcp(; session = s) do c
            r = request(c, "tools/list")
            names = sort([String(t.name) for t in r.result.tools])
            @test names == sort(["list_node_kinds", "get_graph", "get_web_url", "add_node",
                "update_node", "remove_node", "connect", "disconnect",
                "set_context", "load_table", "run", "get_result_summary",
                "get_diagnostic", "fit_insample"])
            for t in r.result.tools
                @test !isempty(String(t.description))
                @test t.inputSchema.type == "object"
            end
        end
        # `MCP.start!` takes the global logger; stopping gives it back, so a
        # session served inside a larger process leaves logging as it found it.
        @test global_logger() === logger
        @test Loki.server(s) === nothing
    end

    @testset "the catalog" begin
        withmcp() do c
            catalog = called(c, "list_node_kinds")
            @test length(catalog.kinds) == length(Loki.nodekinds())
            # The bare listing is a catalog: no schemas, so it stays readable.
            @test !haskey(catalog.kinds[1], :paramschema)
            @test occursin("category", String(catalog.note))

            one = called(c, "list_node_kinds", Dict("kind" => "ema"))
            kind = only(one.kinds)
            @test kind.name == "ema"
            @test kind.paramschema.type == "object"
            @test haskey(kind.paramschema.properties, :span)
            @test "column" in String.(kind.paramorder)

            ts = called(c, "list_node_kinds", Dict("category" => "time series"))
            @test "ema" in [String(k.name) for k in ts.kinds]
            @test all(k -> haskey(k, :paramschema), ts.kinds)

            payload, failed = call(c, "list_node_kinds", Dict("kind" => "nope"))
            @test failed && occursin("nope", String(payload.error))
            payload, failed = call(c, "list_node_kinds", Dict("category" => "nope"))
            @test failed && occursin("time series", String(payload.error))
        end
    end

    # The `table` -> `ema` chain the later testsets run against, built with the
    # tools an agent would use.
    function buildchain(c::MCPClient)
        n1 = String(
            called(c, "add_node",
                Dict("kind" => "table", "params" => Dict("table" => "df"))).id,
        )
        n2 = String(
            called(c, "add_node",
                Dict("kind" => "ema", "params" => Dict("column" => "x", "span" => 5),
                    "position" => [40, 90])).id,
        )
        e = String(called(c, "connect",
            Dict("from" => [n1, "out"], "to" => [n2, "in"])).id)
        return n1, n2, e
    end

    @testset "building a graph" begin
        withmcp() do c
            n1, n2, e = buildchain(c)
            g = called(c, "get_graph")
            @test sort([String(n.id) for n in g.nodes]) == sort([n1, n2])
            edge = only(g.edges)
            @test String(edge.id) == e
            @test [String(x) for x in edge.from] == [n1, "out"]
            @test [String(x) for x in edge.to] == [n2, "in"]
            ema = only(n for n in g.nodes if String(n.id) == n2)
            @test ema.params.span == 5
            @test collect(ema.position) == [40.0, 90.0]

            # Merged, not replaced: `span` stays, `name` arrives, and a null
            # takes `name` away again.
            called(c, "update_node", Dict("id" => n2, "params" => Dict("name" => "s")))
            params = only(n.params for n in called(c, "get_graph").nodes
                              if String(n.id) == n2)
            @test params.span == 5 && String(params.name) == "s"
            called(c, "update_node", Dict("id" => n2, "params" => Dict("name" => nothing)))
            params = only(n.params for n in called(c, "get_graph").nodes
                              if String(n.id) == n2)
            @test !haskey(params, :name) && params.span == 5

            # Moving a node is not editing it, so it does not invalidate.
            called(c, "update_node", Dict("id" => n2, "position" => [7, 8]))
            moved = only(n for n in called(c, "get_graph").nodes if String(n.id) == n2)
            @test collect(moved.position) == [7.0, 8.0]

            @test called(c, "disconnect", Dict("id" => e)).ok
            @test isempty(called(c, "get_graph").edges)
            @test called(c, "remove_node", Dict("id" => n2)).ok
            @test only(called(c, "get_graph").nodes).id == n1
        end
    end

    @testset "contexts and tables" begin
        withmcp() do c
            called(c, "set_context",
                Dict("name" => "preview", "timetype" => "Int64",
                    "start" => 0, "stop" => 11))
            ctxs = called(c, "get_graph").contexts
            @test ctxs.preview.start == 0 && ctxs.preview.stop == 11
            @test String(ctxs.preview.timetype) == "Int64"

            dir = mktempdir()
            path = joinpath(dir, "prices.csv")
            write(path, "time,close\n1,10.5\n2,11.0\n3,9.75\n")
            loaded = called(c, "load_table", Dict("name" => "prices", "path" => path))
            @test String(loaded.name) == "prices"
            @test loaded.table.rows == 3
            @test "close" in String.(loaded.table.columns)
            @test "prices" in [String(t.name) for t in called(c, "get_graph").tables]

            payload, failed = call(c, "load_table",
                Dict("name" => "gone", "path" => joinpath(dir, "nope.csv")))
            @test failed && occursin("nope.csv", String(payload.error))
            payload, failed = call(c, "load_table",
                Dict("name" => "odd", "path" => path, "format" => "arrow"))
            @test failed
            write(joinpath(dir, "prices.txt"), "time,close\n1,2\n")
            payload, failed = call(c, "load_table",
                Dict("name" => "odd", "path" => joinpath(dir, "prices.txt")))
            @test failed && occursin("extension", String(payload.error))
        end
    end

    @testset "a bad edit is an answer, not a crash" begin
        withmcp() do c
            n1, n2, _ = buildchain(c)
            payload, failed = call(c, "add_node", Dict("kind" => "nope"))
            @test failed && occursin("nope", String(payload.error))
            payload, failed = call(c, "update_node",
                Dict("id" => "no_such", "params" => Dict("span" => 3)))
            @test failed && occursin("no_such", String(payload.error))
            payload, failed = call(c, "update_node", Dict("id" => n2))
            @test failed && occursin("params", String(payload.error))
            payload, failed = call(c, "disconnect", Dict("id" => "e99"))
            @test failed && occursin("e99", String(payload.error))
            # A cycle is refused, and the graph is left as it was.
            payload, failed = call(c, "connect",
                Dict("from" => [n2, "out"], "to" => [n1, "in"]))
            @test failed
            payload, failed = call(c, "connect", Dict("from" => [n1, "out"]))
            @test failed && occursin("to", String(payload.error))
            @test length(called(c, "get_graph").edges) == 1
            # The session is still answering after all of that.
            @test called(c, "get_graph").nextid isa Integer
        end
    end

    @testset "running and reading back" begin
        withmcp() do c
            n1, n2, _ = buildchain(c)
            report = called(c, "run", Dict("targets" => [n2]))
            t = only(report.targets)
            @test String(t.id) == n2 && String(t.port) == "out"
            @test String(t.status) == "ok" && t.rows == 80
            @test "x_ema_5" in String.(t.columns)
            @test t.acausal == false
            @test isempty(report.errors) && report.cancelled == false

            smry = called(c, "get_result_summary", Dict("id" => n2))
            @test smry.summary.rows == 80
            cols = Dict(String(col.name) => col for col in smry.summary.columns)
            @test cols["x_ema_5"].n == 80
            @test length(smry.data.head) == 5 && length(smry.data.tail) == 5
            narrow = called(c, "get_result_summary",
                Dict("id" => n2, "columns" => "time,x", "head" => 2, "tail" => 0))
            @test String.(narrow.data.columns) == ["time", "x"]
            @test length(narrow.data.head) == 2 && isempty(narrow.data.tail)

            a = called(
                c,
                "get_diagnostic",
                Dict("id" => n2, "kind" => "acf",
                    "params" => Dict("column" => "x_ema_5", "lags" => 10)),
            )
            @test String(a.kind) == "acf" && a.summary.lags == 10
            # The values and the significant lags are in the summary already, so
            # the plot-ready arrays are not sent unless they are asked for.
            @test length(a.summary.values) == 11
            @test !haskey(a, :data)
            full = called(
                c,
                "get_diagnostic",
                Dict("id" => n2, "kind" => "acf",
                    "params" => Dict("column" => "x_ema_5", "lags" => 10),
                    "include_data" => true),
            )
            @test length(full.data.values) == 11

            # A node that has not been evaluated says to run it, rather than
            # looking like a node that is not there.
            payload, failed = call(c, "get_result_summary", Dict("id" => n1))
            @test failed && occursin("run it first", String(payload.error))
            payload, failed = call(c, "get_result_summary",
                Dict("id" => n2, "port" => "nope"))
            @test failed && occursin("nope", String(payload.error))
            payload, failed = call(c, "get_diagnostic",
                Dict("id" => n2, "kind" => "acf", "params" => Dict("column" => "no")))
            @test failed && occursin("no", String(payload.error))

            # And the same frame, for a client that would rather read a resource.
            r = request(c, "resources/read",
                Dict("uri" => "loki://node/$n2/result"))
            @test JSON3.read(r.result.contents[1].text).summary.rows == 80
        end
    end

    @testset "a failing run says which node failed" begin
        withmcp() do c
            n1 = String(
                called(c, "add_node",
                    Dict("kind" => "table", "params" => Dict("table" => "df"))).id,
            )
            # A column that is not there: the error lands on the node that asked
            # for it, and the target it blocked names it too.
            n2 = String(
                called(c, "add_node",
                    Dict("kind" => "ema",
                        "params" => Dict("column" => "nope", "span" => 5))).id,
            )
            called(c, "connect", Dict("from" => [n1, "out"], "to" => [n2, "in"]))
            report = called(c, "run", Dict("targets" => [n2]))
            @test String(only(report.targets).status) == "error"
            @test haskey(report.errors, Symbol(n2))
            @test occursin("nope", String(report.errors[Symbol(n2)]))
        end
    end

    @testset "fit_insample proposes and checks in one step" begin
        withmcp() do c
            n1 = String(
                called(c, "add_node",
                    Dict("kind" => "table", "params" => Dict("table" => "df"))).id,
            )
            r = called(c, "fit_insample",
                Dict("from" => [n1, "out"],
                    "params" => Dict("family" => "arma", "column" => "y",
                        "order" => [1, 0, 1])))
            @test String(only(r.targets).status) == "ok"
            @test String(only(r.targets).port) == "insample"
            @test String(r.residuals.kind) == "residuals"
            # `applyarma` drops the model column, so the degrees of freedom can
            # only come from the fit node's own order — which this tool knows.
            @test r.residuals.summary.dof == 2
            @test !isempty(r.residuals.summary.ljungbox)
            @test haskey(r.residuals.panels, :acf)
            @test !haskey(r.residuals.panels.acf, :data)

            # The node is in the graph and already wired, under the id reported.
            g = called(c, "get_graph")
            @test String(r.id) in [String(n.id) for n in g.nodes]
            @test any(e -> [String(x) for x in e.to] == [String(r.id), "in"], g.edges)

            # A fit that cannot even be built leaves nothing behind.
            before = length(called(c, "get_graph").nodes)
            payload, failed = call(c, "fit_insample",
                Dict("from" => [n1, "out"], "params" => Dict("family" => "arma")))
            @test failed
            payload, failed = call(c, "fit_insample",
                Dict("from" => [n1, "in"],
                    "params" => Dict("family" => "arma", "column" => "y",
                        "order" => [1, 0, 1])))
            @test failed
            @test length(called(c, "get_graph").nodes) == before
        end
    end

    # The point of MCP mode: one session, and the browser can tell who moved.
    @testset "an agent's edit reaches the browser as an agent's" begin
        s = mcpsession()
        got = String[]
        opened = Threads.Event()
        sock = nothing
        withmcp(; session = s) do c
            srv = Loki.server(s)
            url = "ws://127.0.0.1:$(Loki.port(srv))/ws?token=$(Loki.token(srv))"
            sock = Threads.@spawn try
                HTTP.WebSockets.open(url) do ws
                    notify(opened)
                    for msg in ws
                        push!(got, msg isa AbstractString ? String(msg) : String(copy(msg)))
                    end
                end
            catch
                notify(opened)
            end
            wait(opened)
            sleep(0.2)
            called(c, "add_node", Dict("kind" => "emptyframe"))
            sleep(0.5)
        end
        try
            wait(sock)
        catch
        end
        es = [JSON3.read(g) for g in got]
        added = only(e for e in es if String(e.event) == "graph_changed")
        @test String(added.payload.change) == "addnode"
        @test String(added.origin) == "mcp"
    end

    @testset "the graph and the URLs" begin
        withmcp() do c
            g = called(c, "get_graph")
            @test isempty(g.nodes) && isempty(g.edges)
            @test sort(String.(keys(g.contexts))) == ["analysis", "train"]
            @test only(g.tables).name == "df"
            @test g.context == "analysis"

            urls = called(c, "get_web_url")
            token = Loki.token(Loki.server(c.session))
            @test occursin("127.0.0.1", String(urls.url))
            @test occursin(token, String(urls.url))
            @test occursin("ws.example-tailnet.ts.net", String(urls.public))

            # The same state, for a client that would rather read than call.
            r = request(c, "resources/read", Dict("uri" => "loki://graph"))
            @test JSON3.read(r.result.contents[1].text).nextid == g.nextid
        end
    end
end
