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

function mcpsession()
    df = DataFrame(time = 1:80, x = Float64.(1:80), k = repeat(["a", "b"], 40))
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
            @test names == ["get_graph", "get_web_url", "list_node_kinds"]
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
