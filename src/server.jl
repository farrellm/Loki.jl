# The web server: the static bundle, a REST API, and a WebSocket, on 127.0.0.1.
#
# These routes execute arbitrary Julia — that is what a source-text parameter is
# — so the containment is not decoration. The socket binds to the loopback in
# every mode and there is no option to bind anything else; every `/api` route and
# the WebSocket need a per-session token or the cookie it is exchanged for; and
# the `Origin` and `Host` of every request are checked, which is what stops a
# page on another origin from driving a session through the browser that holds
# the cookie.

const WEBROOT = normpath(joinpath(@__DIR__, "..", "assets", "web"))

"""
    Loki.Server

A running web server: the [`Loki.Session`](@ref) it serves, the `port` it is
listening on, the session `token`, and the `public_url` it is reachable at
through `tailscale serve`, if any. [`serve`](@ref) starts one and
[`Loki.stop!`](@ref) ends it.
"""
mutable struct Server
    const session::Session
    const token::String
    const public_url::Union{Nothing,String}
    const root::String
    # The live WebSockets. `Base.close(::HTTP.Server)` waits for active
    # connections to finish, and a socket's reader never finishes one, so
    # stopping has to end them itself.
    const sockets::Vector{Any}
    # The subscribers this server opened, so stopping it ends its own watchers
    # and leaves a REPL's or an agent's `Loki.subscribe!` alone.
    const subscribers::Vector{Subscriber}
    # The listener accepts before `origins`, `hosts` and `port` are known — with
    # `port = 0` the port is not known until it is listening — so a request that
    # beats them waits here rather than being refused as a forbidden host.
    const ready::Threads.Event
    const lock::ReentrantLock
    http::Any                     # HTTP.Server, once it is listening
    port::Int
    origins::Set{String}
    hosts::Set{String}
    # The router closes over this struct, so it is set once the struct exists.
    router::Any
    # The `Loki.MCPMode` beside it under `serve_mcp`, or nothing. Untyped, like
    # `Session.server`, because MCP mode is defined after this.
    mcp::Any
end

"""
    Loki.server(s::Session) -> Union{Nothing,Loki.Server}

The server a session is being served by, or `nothing` if it is headless.
"""
server(s::Session) = lock(() -> s.server, s.lock)::Union{Nothing,Server}

"""
    Loki.port(srv::Loki.Server) -> Int

The port the server is listening on — the one it was given, or the free one it
took for `port = 0`.
"""
port(srv::Server) = srv.port

"""
    Loki.token(srv::Loki.Server) -> String

The session token. Every `/api` route and the WebSocket require it, or the
cookie [`serve`](@ref) exchanges it for.
"""
token(srv::Server) = srv.token

"""
    Loki.weburl(srv::Loki.Server; public = false) -> String

The URL to open the app at, carrying the session token in the fragment — which
browsers never send to a server and never put in a `Referer`. With `public`, the
`tailscale serve` address instead of the loopback one.
"""
function weburl(srv::Server; public::Bool = false)
    public || return "http://127.0.0.1:$(srv.port)/#token=$(srv.token)"
    srv.public_url === nothing &&
        throw(ArgumentError("this server has no public_url; pass one to serve"))
    return "$(rstrip(srv.public_url, '/'))/#token=$(srv.token)"
end

weburl(s::Session; kwargs...) = weburl(needserver(s); kwargs...)

function needserver(s::Session)
    srv = server(s)
    srv === nothing && throw(ArgumentError("this session is not being served"))
    return srv
end

# --- the token -----------------------------------------------------------------

newtoken() = bytes2hex(rand(Random.RandomDevice(), UInt8, 32))

# Constant time: a comparison that stops at the first wrong byte tells an
# attacker how much of a guess was right.
function secureequal(a::AbstractString, b::AbstractString)
    x = UInt8(ncodeunits(a) != ncodeunits(b))
    for i in 1:min(ncodeunits(a), ncodeunits(b))
        x |= codeunit(a, i) ⊻ codeunit(b, i)
    end
    return x == 0x00
end

const COOKIENAME = "loki_session"

function cookievalue(req::HTTP.Request, name::AbstractString)
    header = HTTP.header(req, "Cookie", "")
    for part in split(header, ';'; keepempty = false)
        eq = findfirst('=', part)
        eq === nothing && continue
        strip(part[1:(eq-1)]) == name && return String(strip(part[(eq+1):end]))
    end
    return nothing
end

function bearer(req::HTTP.Request)
    header = HTTP.header(req, "Authorization", "")
    startswith(header, "Bearer ") || return nothing
    return String(strip(header[8:end]))
end

# The token, from wherever the client could put it. The cookie is what the app
# uses after its first load; the query parameter and the bearer header are for
# curl, the tests, and an MCP client.
function presentedtoken(req::HTTP.Request)
    c = cookievalue(req, COOKIENAME)
    c === nothing || return c
    b = bearer(req)
    b === nothing || return b
    return get(HTTP.queryparams(HTTP.URI(req.target)), "token", nothing)
end

function authorized(srv::Server, req::HTTP.Request)
    given = presentedtoken(req)
    return given !== nothing && secureequal(given, srv.token)
end

# TLS terminated elsewhere: `tailscale serve` proxies to this loopback socket and
# says so with this header. `Secure` must follow it — set unconditionally it
# silently breaks http://127.0.0.1, never set it risks the cookie in clear.
overtls(srv::Server, req::HTTP.Request) =
    HTTP.header(req, "X-Forwarded-Proto", "") == "https" ||
    (
        srv.public_url !== nothing && startswith(srv.public_url, "https://") &&
        (
            HTTP.header(req, "Origin", "") in urlorigins(srv.public_url) ||
            HTTP.header(req, "Host", "") in urlhosts(srv.public_url)
        )
    )

function authroute(srv::Server, req::HTTP.Request)
    body = readjson(req)
    given = get(body, "token", nothing)
    (given isa AbstractString && secureequal(given, srv.token)) ||
        return jsonerror(401, "unauthorized")
    secure = overtls(srv, req) ? "; Secure" : ""
    # A session cookie would be dropped when iOS evicts the tab; an expiry makes
    # a home-screen bookmark opened a day later still authenticate. The token
    # dies with the process in any case.
    cookie = "$COOKIENAME=$(srv.token); Path=/; HttpOnly; SameSite=Strict; \
        Max-Age=604800$secure"
    return jsonresponse(Dict("ok" => true, "seq" => srv.session.seq);
        headers = ["Set-Cookie" => replace(cookie, r"\s+" => " ")])
end

# --- origin and host -------------------------------------------------------------

# `tailscale serve --https=8443` puts the port in `public_url`, and so in every
# `Host` and `Origin` that arrives through it. A client sends the scheme's
# default port or omits it, so that one is accepted both ways.
function urlport(url::AbstractString)
    uri = HTTP.URI(url)
    default = uri.scheme == "http" ? "80" : "443"
    return uri, (isempty(uri.port) ? default : uri.port), default
end

function urlhosts(url::AbstractString)
    uri, port, default = urlport(url)
    hosts = ["$(uri.host):$port"]
    port == default && push!(hosts, uri.host)
    return hosts
end

urlorigins(url::AbstractString) =
    (uri = first(urlport(url)); ["$(uri.scheme)://$h" for h in urlhosts(url)])

function allowedorigins(port::Integer, public_url)
    out = Set(["http://127.0.0.1:$port", "http://localhost:$port",
        "http://[::1]:$port"])
    public_url === nothing || union!(out, urlorigins(public_url))
    return out
end

function allowedhosts(port::Integer, public_url)
    out = Set(["127.0.0.1:$port", "localhost:$port", "[::1]:$port",
        "127.0.0.1", "localhost"])
    public_url === nothing || union!(out, urlhosts(public_url))
    return out
end

# A missing `Origin` is allowed: curl sends none, and so does a same-origin GET.
# The token is the real gate; this check is what stops a page on another origin
# from driving the session through the browser that holds the cookie.
checkorigin(srv::Server, req::HTTP.Request) =
    (o = HTTP.header(req, "Origin", ""); isempty(o) || o in srv.origins)

# `Origin` alone does not close DNS rebinding: an attacker's name resolving to
# 127.0.0.1 gives `Host: evil.example:8712` on a same-origin GET that carries no
# `Origin` at all.
checkhost(srv::Server, req::HTTP.Request) =
    (h = HTTP.header(req, "Host", ""); isempty(h) || h in srv.hosts)

# --- responses -------------------------------------------------------------------

const JSONTYPE = "application/json; charset=utf-8"

jsonresponse(body; status::Integer = 200, headers = Pair{String,String}[]) =
    HTTP.Response(status, [["Content-Type" => JSONTYPE]; headers], JSON3.write(body))

jsonerror(status::Integer, message::AbstractString; extra...) =
    jsonresponse(
        Dict{String,Any}("error" => String(message),
            (String(k) => v for (k, v) in pairs(extra))...); status)

function readjson(req::HTTP.Request)
    isempty(req.body) && return Dict{String,Any}()
    doc = try
        JSON3.read(String(req.body))
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("the request body is not JSON"))
    end
    doc isa JSON3.Object || throw(ArgumentError("the request body is not a JSON object"))
    return plainjson(doc)
end

query(req::HTTP.Request) = HTTP.queryparams(HTTP.URI(req.target))

# Errors are mapped by type, not by message: a bad parameter is the client's
# fault and says what was wrong, and anything unrecognised is ours and does not
# leak a backtrace to the browser.
function errorresponse(err)
    err isa NodeError &&
        return jsonerror(400, sprint(showerror, err); node = err.id)
    err isa ArgumentError && return jsonerror(400, err.msg)
    err isa NotFound && return jsonerror(404, err.message)
    err isa NotEvaluated &&
        return jsonerror(409, err.message; id = err.id, port = String(err.port))
    @error "Loki server error" exception = (err, catch_backtrace())
    return jsonerror(500, "internal error")
end

struct NotFound <: Exception
    message::String
end

struct NotEvaluated <: Exception
    message::String
    id::String
    port::Symbol
end

Base.showerror(io::IO, e::NotFound) = print(io, e.message)
Base.showerror(io::IO, e::NotEvaluated) = print(io, e.message)

# A node id from the path. Checked before the call, so an unknown one is a 404
# rather than a 400 that looks like a bad parameter.
function needsnode(s::Session, id::AbstractString)
    lock(s.lock) do
        haskey(s.graph.nodes, String(id)) ||
            throw(NotFound("no node $(repr(String(id)))"))
    end
    return String(id)
end

# --- the graph as JSON -----------------------------------------------------------

"""
    Loki.graphjson(s::Session; context = "analysis") -> Dict{String,Any}

The whole session as the browser reads it: every node with its kind, parameters,
position, ports, status, taint, error and — where it has been evaluated — the
shape of its result; every edge; the named contexts, the tables, the prelude,
and the event `seq` this picture was taken at.

This is one request on purpose. A client that reconnects, or that sees a gap in
the event sequence, refetches this rather than trusting what it has, so it has to
carry everything the canvas and the inspector need.
"""
function graphjson(s::Session; context::AbstractString = "analysis")
    return lock(s.lock) do
        g = s.graph
        tainted = taint(g)
        env = buildenv(s)
        ctx = get(s.contexts, String(context), nothing)
        hashes = ctx === nothing ? nothing : nodehashes(g, env)
        nodes = Any[nodejson(s, g.nodes[id], tainted, ctx, hashes) for id in g.order]
        run = s.run
        Dict{String,Any}("nodes" => nodes,
            "edges" => Any[edgeevent(e) for e in g.edges],
            "contexts" => Dict{String,Any}(name => contextevent(c)
                             for (name, c) in s.contexts),
            "tables" => Any[
                merge(tableevent(t), Dict{String,Any}("name" => name))
                for (name, t) in sort!(collect(s.tables); by = first)
            ],
            "prelude" => s.usercode.prelude, "nextid" => g.nextid, "seq" => s.seq,
            "context" => String(context), "file" => s.file,
            "running" =>
                run === nothing ? nothing :
                Dict{String,Any}(
                    "targets" => Any[Any[id, String(p)] for (id, p) in run.targets],
                    "cancelled" => run.cancelled[]))
    end
end

function nodejson(s::Session, node::Node, tainted, ctx, hashes)
    kind = nodekind(node.kind)
    ports = outputs(kind)
    err = get(s.errors, node.id, nothing)
    results = Dict{String,Any}()
    if ctx !== nothing && hashes !== nothing
        for p in ports
            frame = cacheget(s.cache, (node.id, p, hashes[node.id], ctx))
            frame === nothing || (results[String(p)] = frameevent(frame))
        end
    end
    return Dict{String,Any}("id" => node.id, "kind" => node.kind,
        "params" => node.params,
        "position" => Any[node.position[1], node.position[2]],
        "status" => String(get(s.status, node.id, :idle)),
        "acausal" => any(p -> tainted[(node.id, p)], ports),
        "acausalports" => Dict{String,Any}(String(p) => tainted[(node.id, p)]
                         for p in ports),
        "error" =>
            err === nothing ? nothing :
            Dict{String,Any}("node" => err isa NodeError ? err.id : node.id,
                "message" => sprint(showerror, err)),
        "inputs" => Any[
            Dict{String,Any}("name" => String(p.name),
                "variadic" => p.variadic, "optional" => p.optional)
            for p in inputs(kind)
        ],
        "outputs" => Any[String(p) for p in ports],
        "write" => iswrite(kind), "results" => results,
        "calls" => nodecalls(s.graph, node.id))
end

"""
    Loki.nodecalls(g::Graph, id) -> Dict{String,String}

The line of Julia each of a node's output ports exports as, from the kind's
[`Loki.emit`](@ref) — `difference(:close_log)`, `insample(FitARMA(:x; order =
(1, 0, 1)))`. This is what the canvas draws on the node, so that reading the
graph is reading the script it becomes.

Best effort: a kind that cannot be exported, or one whose parameters are not yet
complete enough to emit, returns nothing for that port rather than raising —
a half-built node still has to be drawn.
"""
function nodecalls(g::Graph, id::AbstractString)
    node = getnode(g, id)
    kind = nodekind(node.kind)
    canemit(kind) || return Dict{String,String}()
    ins = Dict{Symbol,Any}()
    for port in inputs(kind)
        fed = Any[callbinding(g, e.from) for e in inedges(g, id) if e.to[2] === port.name]
        ins[port.name] =
            port.variadic ? fed :
            isempty(fed) ? (port.optional ? nothing : :_) : only(fed)
    end
    emitted = try
        emit(kind, node.params, ins)
    catch err
        err isa InterruptException && rethrow()
        return Dict{String,String}()
    end
    out = Dict{String,String}()
    for port in outputs(kind)
        out[String(port)] = stripbinding(exprstring(emitted[port]))
    end
    return out
end

callbinding(g::Graph, from::Tuple{String,Symbol}) =
    Symbol(
        length(outputs(nodekind(g.nodes[from[1]].kind))) == 1 ?
        string("p_", from[1]) : string("p_", from[1], "_", from[2]),
    )

# `p_n2 |> difference(:close_log)` reads as `difference(:close_log)` on a node
# whose input is already an edge on the canvas.
function stripbinding(text::AbstractString)
    m = match(r"^[A-Za-z_][A-Za-z0-9_]* \|> "s, text)
    return m === nothing ? String(text) : String(text[(m.offset+length(m.match)):end])
end

# --- routes ------------------------------------------------------------------------

function buildrouter(srv::Server)
    s = srv.session
    r = HTTP.Router()

    HTTP.register!(r, "GET", "/api/nodekinds", _ -> jsonresponse(nodekindsjson()))

    HTTP.register!(r, "GET", "/api/graph",
        req -> jsonresponse(graphjson(s; context = contextname(req))))

    HTTP.register!(
        r,
        "POST",
        "/api/nodes",
        function (req)
            body = readjson(req)
            haskey(body, "kind") || throw(ArgumentError("a node needs a kind"))
            id = addnode!(s, String(body["kind"]),
                Dict{String,Any}(get(body, "params", Dict{String,Any}()));
                id = get(body, "id", nothing),
                position = Tuple(Float64.(get(body, "position", [0.0, 0.0]))))
            jsonresponse(Dict("id" => id, "node" => nodeevent(getnode(s.graph, id)));
                status = 201)
        end,
    )

    HTTP.register!(
        r,
        "PATCH",
        "/api/nodes/{id}",
        function (req)
            id = needsnode(s, HTTP.getparams(req)["id"])
            body = readjson(req)
            # Position and parameters are separate edits: dragging a node must not
            # invalidate it, and neither must be silently skipped.
            # PATCH means what it says: the parameters given are merged into the
            # node's, and a `null` removes one. Sending the whole object instead
            # would make two quick edits race — the second would be built from a
            # copy taken before the first landed, and would silently undo it.
            haskey(body, "params") && updatenode!(s, id,
                mergeparams(lock(() -> getnode(s.graph, id).params, s.lock),
                    Dict{String,Any}(body["params"])))
            haskey(body, "position") &&
                setposition!(s, id, Tuple(Float64.(body["position"])))
            (haskey(body, "params") || haskey(body, "position")) ||
                throw(ArgumentError("give params, position, or both"))
            jsonresponse(Dict("node" => nodeevent(getnode(s.graph, id))))
        end,
    )

    HTTP.register!(
        r,
        "DELETE",
        "/api/nodes/{id}",
        function (req)
            removenode!(s, needsnode(s, HTTP.getparams(req)["id"]))
            jsonresponse(Dict("ok" => true))
        end,
    )

    HTTP.register!(
        r,
        "POST",
        "/api/nodes/{id}/freeze",
        function (req)
            id = needsnode(s, HTTP.getparams(req)["id"])
            body = readjson(req)
            name = freeze!(s, id; port = get(body, "port", nothing),
                name = get(body, "name", "frozen_" * id),
                context = String(get(body, "context", "analysis")))
            jsonresponse(
                Dict("table" => name,
                    "rows" => nrow(lock(() -> s.tables[name], s.lock))),
            )
        end,
    )

    HTTP.register!(
        r,
        "POST",
        "/api/edges",
        function (req)
            body = readjson(req)
            (haskey(body, "from") && haskey(body, "to")) ||
                throw(ArgumentError("an edge needs from and to"))
            from, to = body["from"], body["to"]
            eid = connect!(s, (String(from[1]), Symbol(from[2])),
                (String(to[1]), Symbol(to[2])); id = get(body, "id", nothing))
            jsonresponse(Dict("id" => eid); status = 201)
        end,
    )

    HTTP.register!(
        r,
        "DELETE",
        "/api/edges/{id}",
        function (req)
            id = HTTP.getparams(req)["id"]
            lock(s.lock) do
                any(e -> e.id == id, s.graph.edges) ||
                    throw(NotFound("no edge $(repr(String(id)))"))
            end
            disconnect!(s, id)
            jsonresponse(Dict("ok" => true))
        end,
    )

    HTTP.register!(r, "GET", "/api/contexts",
        _ -> jsonresponse(
            lock(
                () -> Dict{String,Any}(name => contextevent(c)
                    for (name, c) in s.contexts),
                s.lock),
        ))

    HTTP.register!(
        r,
        "PUT",
        "/api/contexts/{name}",
        function (req)
            name = contextparam(req)
            setcontext!(s, name, readcontext(JSON3.read(String(req.body))))
            jsonresponse(
                Dict("name" => String(name),
                    "context" => contextevent(s.contexts[name])),
            )
        end,
    )

    HTTP.register!(
        r,
        "DELETE",
        "/api/contexts/{name}",
        function (req)
            name = contextparam(req)
            lock(s.lock) do
                name == "analysis" || haskey(s.contexts, name) ||
                    throw(NotFound("no context $(repr(name))"))
            end
            removecontext!(s, name)
            jsonresponse(Dict("ok" => true))
        end,
    )

    HTTP.register!(r, "GET", "/api/tables",
        _ -> jsonresponse(
            lock(
                () -> Any[
                    merge(tableevent(t),
                        Dict{String,Any}("name" => name))
                    for (name, t) in
                    sort!(collect(s.tables); by = first)
                ], s.lock),
        ))

    HTTP.register!(
        r,
        "POST",
        "/api/tables/{name}",
        function (req)
            name = String(HTTP.getparams(req)["name"])
            format = get(query(req), "format", "csv")
            addtable!(s, name, readuploadedtable(req.body, format))
            jsonresponse(
                Dict("name" => name,
                    "table" => tableevent(lock(() -> s.tables[name], s.lock))); status = 201)
        end,
    )

    HTTP.register!(
        r,
        "POST",
        "/api/run",
        function (req)
            body = readjson(req)
            targets = get(body, "targets", nothing)
            targets === nothing && throw(ArgumentError("a run needs targets"))
            wanted = [
                t isa AbstractVector ? (String(t[1]), Symbol(t[2])) : String(t)
                for t in targets
            ]
            context = String(get(body, "context", "analysis"))
            run = run!(s, wanted; context)
            jsonresponse(
                Dict("targets" => Any[Any[id, String(p)] for (id, p) in run.targets],
                    "context" => context),
            )
        end,
    )

    HTTP.register!(r, "POST", "/api/cancel", function (_)
        cancel!(s)
        jsonresponse(Dict("ok" => true))
    end)

    HTTP.register!(
        r,
        "POST",
        "/api/write/{id}",
        function (req)
            id = needsnode(s, HTTP.getparams(req)["id"])
            write!(s, id; context = String(get(query(req), "context", "analysis")))
            jsonresponse(Dict("ok" => true, "id" => id))
        end,
    )

    HTTP.register!(
        r,
        "GET",
        "/api/results/{id}/{port}",
        function (req)
            frame, _ = needsresult(s, req)
            jsonresponse(
                preview(frame; offset = queryint(query(req), "offset", 0),
                    limit = min(queryint(query(req), "limit", 100), 1000),
                    columns = querycolumns(query(req)), key = querykey(query(req))),
            )
        end,
    )

    HTTP.register!(
        r,
        "GET",
        "/api/diagnostics/{id}/{port}/{kind}",
        function (req)
            frame, node = needsresult(s, req)
            kind = String(HTTP.getparams(req)["kind"])
            jsonresponse(
                diagnostic(frame, kind;
                    params = diagnosticparams(s, node, kind, contextname(req), query(req))),
            )
        end,
    )

    HTTP.register!(
        r,
        "GET",
        "/api/export",
        function (req)
            q = query(req)
            mode = Symbol(get(q, "tables", "argument"))
            text = exportjulia(s; tables = mode, context = get(q, "context", "analysis"))
            HTTP.Response(200,
                ["Content-Type" => "text/x-julia; charset=utf-8",
                    "Content-Disposition" => "attachment; filename=\"analysis.jl\""], text)
        end,
    )

    HTTP.register!(
        r,
        "GET",
        "/api/session",
        _ -> jsonresponse(Dict("path" => lock(() -> s.file, s.lock))),
    )

    HTTP.register!(
        r,
        "PUT",
        "/api/session",
        function (req)
            body = readjson(req)
            haskey(body, "path") || throw(ArgumentError("saving needs a path"))
            jsonresponse(Dict("path" => savesession(String(body["path"]), s)))
        end,
    )

    HTTP.register!(
        r,
        "POST",
        "/api/session",
        function (req)
            body = readjson(req)
            haskey(body, "path") || throw(ArgumentError("opening needs a path"))
            path = String(body["path"])
            # Checked here rather than left to `read`, whose `SystemError` would
            # reach the browser as an opaque 500.
            isfile(path) || throw(NotFound("no session file $(repr(path))"))
            opensession!(s, path)
            jsonresponse(Dict("path" => path, "seq" => s.seq))
        end,
    )

    HTTP.register!(r, "GET", "/api/files", req -> jsonresponse(listfiles(query(req))))

    HTTP.register!(r, "GET", "/api/**", _ -> jsonerror(404, "no such route"))
    return r
end

contextname(req::HTTP.Request) = String(get(query(req), "context", "analysis"))

# A context's name from the path, where a name outside ASCII arrives escaped.
contextparam(req::HTTP.Request) = HTTP.URIs.unescapeuri(String(HTTP.getparams(req)["name"]))

# One directory on the machine Loki is running on, for the browser's file
# picker. Not rooted anywhere: an analysis reads from one directory and saves to
# another, and a session that evaluates source text can already reach the whole
# filesystem (see DESIGN.md, "User code"). The token, cookie, `Origin` and
# `Host` checks are what stand in front of it, as they do in front of everything
# else under `/api`.
#
# A home directory full of downloads would otherwise be a megabyte of JSON on a
# phone's connection, so a long listing is cut short and says so.
const MAXENTRIES = 2000

function listfiles(q::AbstractDict)
    dir = normpath(abspath(expanduser(String(get(q, "path", pwd())))))
    isdir(dir) || throw(NotFound("no folder $(repr(dir))"))
    hidden = get(q, "hidden", "false") == "true"
    names = try
        readdir(dir; sort = false)
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("Loki cannot read $(repr(dir)): $(sprint(showerror, err))"))
    end
    hidden || filter!(name -> !startswith(name, "."), names)
    entries = Dict{String,Any}[]
    for name in names
        entry = fileentry(joinpath(dir, name), name)
        entry === nothing || push!(entries, entry)
    end
    # Directories first, then by name as a reader scans them — case-insensitively,
    # so `README` does not sort away from `readme`.
    sort!(entries; by = e -> (!e["dir"], lowercase(e["name"]), e["name"]))
    truncated = length(entries) > MAXENTRIES
    truncated && resize!(entries, MAXENTRIES)
    up = dirname(dir)
    return Dict{String,Any}("path" => dir, "parent" => up == dir ? nothing : up,
        "home" => homedir(), "working" => pwd(), "truncated" => truncated,
        "entries" => entries)
end

# `nothing` for an entry that cannot be stat'ed — a broken symlink, a mount that
# is not there any more. One of those is a reason to leave a row out, never to
# fail the whole listing.
function fileentry(path::AbstractString, name::AbstractString)
    return try
        isdir(path) ? Dict{String,Any}("name" => name, "dir" => true) :
        Dict{String,Any}("name" => name, "dir" => false,
            # A `DateTime` already prints as ISO 8601, which is what the
            # browser parses; the seconds are floored so it stays that short.
            "modified" => string(Dates.unix2datetime(floor(mtime(path)))))
    catch err
        err isa InterruptException && rethrow()
        nothing
    end
end

function mergeparams(current::AbstractDict, given::AbstractDict)
    merged = Dict{String,Any}(current)
    for (name, value) in given
        value === nothing ? delete!(merged, name) : (merged[name] = value)
    end
    return merged
end

# The cached frame a results or diagnostics request is about, and the node it
# came from. A node that exists but has not been evaluated is a `NotEvaluated`
# rather than a `NotFound` — a 409 over HTTP — because the client should run it
# rather than go looking for a different id. The HTTP method only reads the
# request; the work is in the other one, so the MCP tools inherit the same
# discipline instead of writing a second one that drifts.
needsresult(s::Session, req::HTTP.Request) =
    needsresult(s, HTTP.getparams(req)["id"], HTTP.getparams(req)["port"],
        contextname(req))

function needsresult(s::Session, id::AbstractString, port, context::AbstractString)
    nid = needsnode(s, id)
    portname = Symbol(port)
    node = lock(() -> getnode(s.graph, nid), s.lock)
    portname in outputs(nodekind(node.kind)) ||
        throw(NotFound("node $nid ($(node.kind)) has no output port $portname"))
    frame = result(s, nid; port = portname, context)
    frame === nothing && throw(NotEvaluated("node $nid has not been evaluated over \
        $(repr(context)); run it first", nid, portname))
    return frame, node
end

# What a diagnostic needs beyond its query string. This is the one place that
# knows both the frame and the node that produced it, which is the only way the
# Ljung-Box test can learn the degrees of freedom to give up: `applyarma` drops
# the model column, so an in-sample residual stream carries no model, and the
# orders live in the fit node's parameters.
function diagnosticparams(s::Session, node::Node, kind::AbstractString,
    context::AbstractString, q)
    params = Dict{String,Any}(String(k) => v for (k, v) in q)
    # A forecast fan needs the series and the model, which are two ports of the
    # same node: the series is the port being asked about, and the models come
    # from the `model` port beside it.
    if kind == "forecast" && !haskey(params, "models")
        models = modelsframe(s, node, context)
        models === nothing || (params["models"] = models)
    end
    kind in ("residuals", "ljungbox") || return params
    lock(s.lock) do
        haskey(params, "dof") || begin
            d = armaparamdof(node)
            d === nothing || (params["dof"] = d)
        end
        haskey(params, "fitstop") || begin
            name = get(node.params, "fitcontext", nothing)
            name isa AbstractString && haskey(s.contexts, name) &&
                (params["fitstop"] = s.contexts[name].stop)
        end
    end
    return params
end

# The cached frame of a node's `model` port, if it has one and it has been run.
function modelsframe(s::Session, node::Node, context::AbstractString)
    :model in outputs(nodekind(node.kind)) || return nothing
    return result(s, node.id; port = :model, context)
end

# `p + q + P + Q` from a fit node's own parameters.
function armaparamdof(node::Node)
    node.kind in ("fit", "fitarma") || return nothing
    node.kind == "fit" && get(node.params, "family", nothing) != "arma" && return nothing
    order = get(node.params, "order", nothing)
    order isa AbstractVector && length(order) >= 3 || return nothing
    seasonal = get(node.params, "seasonal_order", nothing)
    extra =
        seasonal isa AbstractVector && length(seasonal) >= 4 ?
        Int(seasonal[1]) + Int(seasonal[3]) : 0
    return Int(order[1]) + Int(order[3]) + extra
end

nodekindsjson() = Any[nodekindjson(name) for name in nodekinds()]

function nodekindjson(name::AbstractString)
    k = nodekind(name)
    return Dict{String,Any}("name" => String(name), "category" => categoryof(k),
        "doc" => docof(k),
        "inputs" => Any[
            Dict{String,Any}("name" => String(p.name),
                "variadic" => p.variadic, "optional" => p.optional) for p in inputs(k)
        ],
        "outputs" => Any[String(p) for p in outputs(k)],
        "acausal" => Any[String(p) for p in outputs(k)
                          if isacausal(k, Dict{String,Any}(), p)],
        "write" => iswrite(k), "canemit" => canemit(k),
        "paramschema" => paramschema(k),
        # A JSON object has no order, and a form in declaration order reads very
        # differently from one in hash order: `family` and `column` first, the
        # options after them.
        "paramorder" => paramorder(k))
end

paramorder(k::OpKind) = Any[p.name for p in k.params]
paramorder(k::NodeKind) = Any[String(n)
    for n in keys(get(paramschema(k), "properties", Dict()))]

categoryof(k::OpKind) = k.category
categoryof(::NodeKind) = "other"
docof(k::OpKind) = k.doc
docof(::NodeKind) = ""

# An uploaded CSV or parquet, read into memory through DuckDB — already a
# dependency, since Loki takes CausalFrames' optional ones as its own. It infers
# types, reads timestamps as `DateTime`, and does not insist on a `:time` column,
# which a `lookupjoin`'s table must not have.
function readuploadedtable(body::AbstractVector{UInt8}, format::AbstractString)
    isempty(body) && throw(ArgumentError("the uploaded table is empty"))
    format in ("csv", "parquet") ||
        throw(ArgumentError("upload a csv or a parquet, not $(repr(format))"))
    dir = mktempdir()
    path = joinpath(dir, "upload." * format)
    write(path, body)
    reader = format == "csv" ? "read_csv_auto" : "read_parquet"
    db = DuckDB.DB()
    try
        return DataFrame(
            DuckDB.DBInterface.execute(db,
                "SELECT * FROM $reader('$(replace(path, "\'" => "\'\'"))')"),
        )
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("could not read the uploaded $format: \
            $(sprint(showerror, err))"))
    finally
        DuckDB.DBInterface.close!(db)
        rm(dir; recursive = true, force = true)
    end
end

# --- the static bundle ---------------------------------------------------------

const CONTENTTYPES = Dict(".html" => "text/html; charset=utf-8",
    ".js" => "text/javascript; charset=utf-8",
    ".mjs" => "text/javascript; charset=utf-8",
    ".css" => "text/css; charset=utf-8", ".json" => "application/json; charset=utf-8",
    ".map" => "application/json; charset=utf-8", ".svg" => "image/svg+xml",
    ".png" => "image/png", ".jpg" => "image/jpeg", ".webp" => "image/webp",
    ".ico" => "image/x-icon", ".woff2" => "font/woff2",
    ".txt" => "text/plain; charset=utf-8")

contenttype(path) = get(CONTENTTYPES, lowercase(last(splitext(path))),
    "application/octet-stream")

const UNBUILT = """
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Loki</title><style>
:root { color-scheme: light dark; }
body { margin: 0; display: grid; place-items: center; min-height: 100dvh;
  font: 16px/1.6 system-ui, sans-serif; background: #EDF0EE; color: #17201F; }
@media (prefers-color-scheme: dark) { body { background: #161A19; color: #DCE3DF; } }
main { max-width: 34rem; padding: 2rem 1rem; }
code { background: color-mix(in srgb, currentColor 10%, transparent);
  padding: 0.15em 0.4em; border-radius: 3px; }
pre { overflow-x: auto; }
</style></head><body><main>
<h1>The app has not been built</h1>
<p>The API and the WebSocket are running; only the browser bundle is missing.
Build it once and reload:</p>
<pre><code>cd web
npm ci
npm run build</code></pre>
<p>The build writes into <code>assets/web</code>, which is not kept in version
control.</p>
</main></body></html>
"""

# A path under the bundle, or `nothing` if it escapes — a router parameter can
# carry `%2e%2e%2f`, and a path that resolves outside the root is not served.
function bundlepath(root::AbstractString, path::AbstractString)
    isempty(root) && return nothing
    rel = lstrip(HTTP.URIs.unescapeuri(path), '/')
    isempty(rel) && (rel = "index.html")
    full = normpath(joinpath(root, rel))
    startswith(full, root * (endswith(root, "/") ? "" : "/")) || full == root ||
        return nothing
    return full
end

function staticresponse(srv::Server, path::AbstractString)
    isdir(srv.root) || return HTTP.Response(200,
        ["Content-Type" => "text/html; charset=utf-8"], UNBUILT)
    full = bundlepath(srv.root, path)
    full === nothing && return jsonerror(403, "forbidden path")
    if !isfile(full)
        # Vite hashes the names under /assets, so a miss there is a real miss;
        # anywhere else it is a client-side route and the app resolves it.
        startswith(path, "/assets/") && return jsonerror(404, "not found")
        full = joinpath(srv.root, "index.html")
        isfile(full) || return jsonerror(404, "not found")
    end
    # Vite hashes the names under /assets, so those never change and are cached
    # forever. `index.html` points at this build's hashes and must not be: with
    # no validator to revalidate against, `no-cache` still lets a browser reuse
    # it, and a stale index means a stale app against a fresh server.
    cache =
        startswith(path, "/assets/") ? "public, max-age=31536000, immutable" :
        "no-store"
    return HTTP.Response(200,
        ["Content-Type" => contenttype(full), "Cache-Control" => cache], read(full))
end

# --- the request pipeline --------------------------------------------------------

# Every route is inside the one `catch`, `/api/auth` and the static bundle
# included: a malformed body to the auth route is the client's fault and has to
# come back as a 400, not as whatever HTTP.jl makes of an escaping exception.
function handlerequest(srv::Server, req::HTTP.Request)
    checkorigin(srv, req) || return jsonerror(403, "forbidden origin")
    checkhost(srv, req) || return jsonerror(403, "forbidden host")
    return try
        path = HTTP.URI(req.target).path
        # The token arrives in the fragment, which is never sent to a server, so
        # the bundle itself cannot be authenticated and does not need to be: it is
        # the same files for everyone and does nothing until the app exchanges the
        # token.
        if !startswith(path, "/api/")
            staticresponse(srv, path)
        elseif path == "/api/auth"
            authroute(srv, req)
        elseif !authorized(srv, req)
            jsonerror(401, "unauthorized")
        else
            withorigin(:ui) do
                srv.router(req)
            end
        end
    catch err
        err isa InterruptException && rethrow()
        errorresponse(err)
    end
end

function writeresponse(stream::HTTP.Stream, resp::HTTP.Response)
    HTTP.setstatus(stream, resp.status)
    for (k, v) in resp.headers
        HTTP.setheader(stream, k => v)
    end
    HTTP.startwrite(stream)
    HTTP.method(stream.message) == "HEAD" || write(stream, resp.body)
    return nothing
end

function servestream(srv::Server, stream::HTTP.Stream)
    wait(srv.ready)
    req = stream.message
    if HTTP.WebSockets.isupgrade(req)
        # Checked before the upgrade: a socket refused at the handshake never
        # becomes a subscriber.
        checkorigin(srv, req) || return writeresponse(stream,
            jsonerror(403, "forbidden origin"))
        checkhost(srv, req) || return writeresponse(stream,
            jsonerror(403, "forbidden host"))
        authorized(srv, req) || return writeresponse(stream,
            jsonerror(401, "unauthorized"))
        return HTTP.WebSockets.upgrade(ws -> serveesocket(srv, ws), stream)
    end
    req.body = read(stream)
    HTTP.closeread(stream)
    return writeresponse(stream, handlerequest(srv, req))
end

# --- the WebSocket ----------------------------------------------------------------
#
# Two tasks per socket, because `receive` blocks and Julia has no `select`: this
# one reads, and a writer drains the subscriber. Exactly one of them ever sends,
# so the heartbeat and the reply to a ping are offered into the subscriber's own
# queue rather than written from a second task.

const HEARTBEATSECONDS = 30

function serveesocket(srv::Server, ws)
    s = srv.session
    sub = subscribe!(s)
    # The client learns where the sequence stands, so a reconnect knows whether
    # what it has is current.
    offer!(
        sub,
        Event(:hello, :ui, lock(() -> s.seq, s.lock), time(),
            Dict{String,Any}("seq" => lock(() -> s.seq, s.lock))),
    )
    # Through the subscriber, not a second sender: iOS and proxies drop an idle
    # socket, and nothing else here is periodic.
    beat = Timer(HEARTBEATSECONDS; interval = HEARTBEATSECONDS) do _
        offer!(sub, Event(:heartbeat, :ui, 0, time(), Dict{String,Any}()))
    end
    writer = Threads.@spawn socketwriter(ws, sub)
    lock(srv.lock) do
        push!(srv.sockets, ws)
        push!(srv.subscribers, sub)
    end
    try
        for msg in ws
            handlesocketmessage(sub, msg)
        end
    catch err
        err isa InterruptException && rethrow()
        # A socket that goes away without closing is the normal case on a phone.
        @debug "Loki websocket ended" exception = err
    finally
        close(beat)
        lock(srv.lock) do
            filter!(x -> x !== ws, srv.sockets)
            filter!(x -> x !== sub, srv.subscribers)
        end
        unsubscribe!(s, sub)
        try
            wait(writer)
        catch
        end
    end
    return nothing
end

function socketwriter(ws, sub::Subscriber)
    try
        for e in sub
            if sub.dropped > 0
                # The queue overflowed, so `seq` has a gap. Say so explicitly
                # rather than leave the client to infer it: it refetches
                # `/api/graph` and carries on.
                dropped = sub.dropped
                sub.dropped = 0
                HTTP.WebSockets.send(ws,
                    JSON3.write(
                        Dict{String,Any}("event" => "desync",
                            "payload" => Dict{String,Any}("dropped" => dropped)),
                    ))
            end
            HTTP.WebSockets.send(ws, JSON3.write(eventjson(e)))
        end
    catch err
        err isa InterruptException && rethrow()
        @debug "Loki websocket writer ended" exception = err
    end
    return nothing
end

# The client sends almost nothing: it edits over the REST API, so that every
# change is checked in one place. A ping is the exception, so a proxy sees
# traffic in both directions.
function handlesocketmessage(sub::Subscriber, msg)
    text = msg isa AbstractString ? String(msg) : String(copy(msg))
    doc = try
        JSON3.read(text)
    catch err
        err isa InterruptException && rethrow()
        return nothing
    end
    doc isa JSON3.Object && get(doc, :type, nothing) == "ping" &&
        offer!(sub, Event(:pong, :ui, 0, time(), Dict{String,Any}()))
    return nothing
end

# --- starting and stopping ---------------------------------------------------------

"""
    serve(; port = 8712, public_url = get(ENV, "LOKI_PUBLIC_URL", nothing),
          tables = (;), contexts = (;), prelude = "", cachebytes = 2^30,
          token = Loki.newtoken(), open_browser = true) -> Session
    serve(s::Session; port, public_url, token, open_browser = true) -> Session

Serve a session over HTTP on `127.0.0.1` and return it. The URL printed to
stderr carries a per-session token in the fragment; open it once and the app
exchanges the token for a cookie.

`port = 0` takes a free port, which [`Loki.port`](@ref) then reports — how the
tests get one. Stop the server with [`Loki.stop!`](@ref).

**This serves arbitrary code execution**, because a source-text parameter is
Julia the session evaluates. So the socket binds to the loopback in every mode
and there is no option to bind anything else; every `/api` route and the
WebSocket require the token, or the `HttpOnly; SameSite=Strict` cookie it is
exchanged for; and each request's `Origin` and `Host` are checked, which closes
DNS rebinding and stops a page on another origin from driving the session
through the browser that holds the cookie.

**Reaching it from a phone** goes through `tailscale serve`, and only through
it: the listening socket does not change.

```sh
tailscale serve --bg 8712
```

```julia
Loki.serve(; port = 8712, public_url = "https://workstation.example-tailnet.ts.net")
```

`public_url` is accepted as an origin and host, is used to print the second URL,
and tells the cookie to be `Secure`. Nothing else about it changes. When
`tailscale serve` listens on a port other than 443 (`--https=8443`), that port
belongs in `public_url` too: `"https://workstation.example-tailnet.ts.net:8443"`.
"""
function serve(s::Session; port::Integer = 8712,
    public_url = get(ENV, "LOKI_PUBLIC_URL", nothing),
    token::AbstractString = newtoken(), open_browser::Bool = true,
    assets::AbstractString = WEBROOT)
    # `needserver(s).port`, not `port(...)`: the keyword shadows the accessor.
    server(s) === nothing ||
        throw(ArgumentError("this session is already being served on port \
            $(needserver(s).port); stop it first"))
    srv = Server(s, String(token),
        public_url === nothing ? nothing : String(public_url),
        normpath(String(assets)), Any[], Subscriber[], Threads.Event(),
        ReentrantLock(), nothing, Int(port), Set{String}(), Set{String}(), nothing,
        nothing)
    srv.router = buildrouter(srv)
    http = HTTP.serve!("127.0.0.1", Int(port); stream = true, listenany = port == 0,
        verbose = -1) do stream
        servestream(srv, stream)
    end
    srv.http = http
    srv.port = Int(HTTP.port(http))
    srv.origins = allowedorigins(srv.port, srv.public_url)
    srv.hosts = allowedhosts(srv.port, srv.public_url)
    notify(srv.ready)
    lock(() -> (s.server = srv), s.lock)
    announce(srv)
    open_browser && openbrowser(weburl(srv))
    return s
end

serve(; tables = (;), contexts = (;), prelude::AbstractString = "",
    cachebytes::Integer = 2^30, kwargs...) =
    serve(Session(; tables, contexts, prelude, cachebytes); kwargs...)

"""
    Loki.stop!(s::Session) -> Session
    Loki.stop!(srv::Loki.Server) -> Loki.Server

Stop serving: close the listener and every open WebSocket, end the MCP read loop
if [`serve_mcp`](@ref) started one, and leave no task behind. A session that is
not being served is left alone.
"""
function stop!(srv::Server)
    # Order matters. Closing the subscribers ends every writer task; closing the
    # sockets ends every reader, and so releases the HTTP connections each one
    # was holding active. Only then can the server be closed — `Base.close` waits
    # for active connections, and `forceclose` shuts the rest down without
    # waiting for a peer that may never answer.
    subs, sockets = lock(srv.lock) do
        out = (copy(srv.subscribers), copy(srv.sockets))
        empty!(srv.subscribers)
        empty!(srv.sockets)
        out
    end
    for sub in subs
        unsubscribe!(srv.session, sub)
    end
    for ws in sockets
        try
            close(ws)
        catch err
            err isa InterruptException && rethrow()
        end
    end
    try
        HTTP.forceclose(srv.http)
    catch err
        err isa InterruptException && rethrow()
    end
    stopmcp!(srv)
    lock(() -> (srv.session.server = nothing), srv.session.lock)
    return srv
end

function stop!(s::Session)
    srv = server(s)
    srv === nothing || stop!(srv)
    return s
end

# The startup message goes to stderr: stdout belongs to MCP's JSON-RPC stream.
function announce(srv::Server)
    lines = ["Loki is serving on $(weburl(srv))"]
    srv.public_url === nothing ||
        push!(lines, "and, through tailscale serve, on $(weburl(srv; public = true))")
    isdir(srv.root) ||
        push!(
            lines,
            "The browser bundle has not been built; the API is up. \
            Build it with: cd web && npm ci && npm run build",
        )
    @info join(lines, "\n")
    return nothing
end

function openbrowser(url::AbstractString)
    try
        if Sys.isapple()
            run(`open $url`; wait = false)
        elseif Sys.iswindows()
            run(`cmd /c start "" $url`; wait = false)
        elseif haskey(ENV, "DISPLAY") || haskey(ENV, "WAYLAND_DISPLAY")
            run(`xdg-open $url`; wait = false)
        end
    catch err
        err isa InterruptException && rethrow()
        @debug "could not open a browser" exception = err
    end
    return nothing
end
