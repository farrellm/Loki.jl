# The web server: the REST API, and the access control around it. These routes
# execute arbitrary Julia, so the containment is tested one bullet at a time.

using HTTP: HTTP
using Random: Xoshiro, randn

# Start a server on a free port, run `body(ctx)`, and always stop it — a leaked
# listener would fail Aqua's persistent-tasks check and every test after this one.
function withserver(body; public_url = "https://ws.example-tailnet.ts.net",
    assets = nothing, session = nothing)
    s = session === nothing ? serversession() : session
    Loki.serve(s; port = 0, open_browser = false, public_url,
        (assets === nothing ? (;) : (; assets))...)
    srv = Loki.server(s)
    ctx = (; s, srv, port = Loki.port(srv), token = Loki.token(srv),
        base = "http://127.0.0.1:$(Loki.port(srv))")
    try
        body(ctx)
    finally
        Loki.stop!(s)
    end
end

function serversession()
    df = DataFrame(time = 1:80, x = Float64.(1:80), k = repeat(["a", "b"], 40))
    return Loki.Session(; tables = (df = df,),
        contexts = (analysis = Context(0, 81), train = Context(0, 41)))
end

# One request, never retried and never raising on a status: the status is the
# thing under test.
function ask(ctx, method, path; token = ctx.token, headers = Pair{String,String}[],
    body = nothing)
    hs = Pair{String,String}[headers...]
    token === nothing || push!(hs, "Authorization" => "Bearer $token")
    body === nothing || push!(hs, "Content-Type" => "application/json")
    return HTTP.request(method, ctx.base * path, hs,
        body === nothing ? UInt8[] : JSON3.write(body);
        status_exception = false, retry = false, redirect = false)
end

asjson(r) = JSON3.read(String(r.body))

# Build the table -> ema chain the other tests run against.
function buildchain(ctx)
    n1 = asjson(ask(ctx, "POST", "/api/nodes";
        body = Dict("kind" => "table", "params" => Dict("table" => "df")))).id
    n2 = asjson(ask(ctx, "POST", "/api/nodes";
        body = Dict("kind" => "ema",
            "params" => Dict("column" => "x", "span" => 5),
            "position" => [40, 90]))).id
    e = asjson(ask(ctx, "POST", "/api/edges";
        body = Dict("from" => [n1, "out"], "to" => [n2, "in"]))).id
    return String(n1), String(n2), String(e)
end

function runtoready(ctx, targets; timeout = 30)
    ask(ctx, "POST", "/api/run"; body = Dict("targets" => targets))
    deadline = time() + timeout
    while time() < deadline
        g = asjson(ask(ctx, "GET", "/api/graph"))
        statuses = Dict(String(n.id) => String(n.status) for n in g.nodes)
        all(t -> get(statuses, t, "idle") in ("ok", "error", "blocked"), targets) &&
            return g
        sleep(0.05)
    end
    error("the run did not settle within $timeout seconds")
end

@testset "server" begin
    @testset "access control" begin
        withserver() do ctx
            # No credential, and a wrong one, are both refused.
            @test ask(ctx, "GET", "/api/graph"; token = nothing).status == 401
            @test ask(ctx, "GET", "/api/graph"; token = "0"^64).status == 401
            @test ask(ctx, "GET", "/api/graph"; token = ctx.token[1:end-1]).status == 401

            # A bearer header and a query parameter both work: curl, the tests and
            # an MCP client cannot use a cookie.
            @test ask(ctx, "GET", "/api/graph").status == 200
            @test ask(ctx, "GET", "/api/graph?token=$(ctx.token)";
                token = nothing).status == 200

            # The bundle is unauthenticated, because the token lives in the URL
            # fragment and a browser never sends that to a server.
            @test ask(ctx, "GET", "/"; token = nothing).status == 200

            # A foreign origin is refused even with a valid token: that is the
            # whole point of the check.
            @test ask(ctx, "GET", "/api/graph";
                headers = ["Origin" => "http://evil.example"]).status == 403
            for good in ("http://127.0.0.1:$(ctx.port)", "http://localhost:$(ctx.port)",
                "https://ws.example-tailnet.ts.net")
                @test ask(ctx, "GET", "/api/graph"; headers = ["Origin" => good]).status ==
                      200
            end

            # `Origin` alone does not close DNS rebinding: a same-origin GET from
            # a name that resolves to 127.0.0.1 carries no Origin at all.
            @test ask(ctx, "GET", "/api/graph";
                headers = ["Host" => "evil.example:$(ctx.port)"]).status == 403
            @test ask(ctx, "GET", "/api/graph";
                headers = ["Host" => "localhost:$(ctx.port)"]).status == 200
        end
    end

    @testset "the token is exchanged for a cookie" begin
        withserver() do ctx
            bad = ask(ctx, "POST", "/api/auth"; token = nothing,
                body = Dict("token" => "0"^64))
            @test bad.status == 401

            ok = ask(ctx, "POST", "/api/auth"; token = nothing,
                body = Dict("token" => ctx.token))
            @test ok.status == 200
            setcookie = HTTP.header(ok, "Set-Cookie")
            @test occursin("HttpOnly", setcookie)
            @test occursin("SameSite=Strict", setcookie)
            @test occursin("Max-Age=", setcookie)      # survives an evicted iOS tab
            # Over http, `Secure` would make the cookie undeliverable.
            @test !occursin("Secure", setcookie)

            cookie = String(first(split(setcookie, ';')))
            @test ask(ctx, "GET", "/api/graph"; token = nothing,
                headers = ["Cookie" => cookie]).status == 200
            # The token is per session, not single-use: one printed URL
            # authenticates a desktop and a phone.
            second = ask(ctx, "POST", "/api/auth"; token = nothing,
                body = Dict("token" => ctx.token))
            @test second.status == 200
            @test ask(ctx, "GET", "/api/graph"; token = nothing,
                headers = ["Cookie" => cookie]).status == 200

            # Behind `tailscale serve` the connection is HTTPS, and says so.
            proxied = ask(ctx, "POST", "/api/auth"; token = nothing,
                body = Dict("token" => ctx.token),
                headers = ["X-Forwarded-Proto" => "https"])
            @test occursin("Secure", HTTP.header(proxied, "Set-Cookie"))
        end
    end

    @testset "the bundle, built and unbuilt" begin
        withserver() do ctx
            # Nothing built: the page says how, and the API still works.
            page = ask(ctx, "GET", "/"; token = nothing)
            @test page.status == 200
            @test occursin("npm run build", String(page.body))
            @test ask(ctx, "GET", "/api/graph").status == 200
        end

        dir = mktempdir()
        write(joinpath(dir, "index.html"), "<!doctype html><title>Loki</title>")
        mkpath(joinpath(dir, "assets"))
        write(joinpath(dir, "assets", "main-abc123.js"), "export const x = 1;")
        withserver(; assets = dir) do ctx
            index = ask(ctx, "GET", "/"; token = nothing)
            @test occursin("<title>Loki</title>", String(index.body))
            @test HTTP.header(index, "Cache-Control") == "no-store"

            js = ask(ctx, "GET", "/assets/main-abc123.js"; token = nothing)
            @test js.status == 200
            @test startswith(HTTP.header(js, "Content-Type"), "text/javascript")
            @test occursin("immutable", HTTP.header(js, "Cache-Control"))

            # A client-side route falls back to the app; a hashed asset that is
            # not there is a real miss.
            @test occursin("<title>Loki</title>",
                String(ask(ctx, "GET", "/node/n3"; token = nothing).body))
            @test ask(ctx, "GET", "/assets/gone.js"; token = nothing).status == 404
            # A path that climbs out of the bundle is refused.
            @test ask(ctx, "GET", "/%2e%2e%2f%2e%2e%2fProject.toml";
                token = nothing).status in (403, 404)
        end
    end

    @testset "editing the graph" begin
        withserver() do ctx
            kinds = asjson(ask(ctx, "GET", "/api/nodekinds"))
            @test length(kinds) == length(Loki.nodekinds())
            fit = only(k for k in kinds if k.name == "fit")
            @test collect(fit.outputs) == ["model", "insample"]
            @test collect(fit.acausal) == ["insample"]
            @test haskey(fit.paramschema, :properties)

            n1, n2, e = buildchain(ctx)
            g = asjson(ask(ctx, "GET", "/api/graph"))
            @test length(g.nodes) == 2 && length(g.edges) == 1
            node = only(n for n in g.nodes if n.id == n2)
            @test node.kind == "ema"
            @test node.position == [40, 90]
            @test node.status == "idle"
            @test node.acausal == false
            # The canvas draws the line of Julia the node exports.
            @test node.calls.out == "ema(:x; span = 5)"
            @test collect(node.inputs[1].name) |> join == "in"
            @test g.contexts.analysis.stop == 81
            @test only(g.tables).name == "df"

            # Parameters and position are separate edits.
            @test ask(ctx, "PATCH", "/api/nodes/$n2";
                body = Dict("params" => Dict("column" => "x", "span" => 9))).status == 200
            @test ask(ctx, "PATCH", "/api/nodes/$n2";
                body = Dict("position" => [7, 8])).status == 200
            @test ask(ctx, "PATCH", "/api/nodes/$n2"; body = Dict()).status == 400
            moved = only(n for n in asjson(ask(ctx, "GET", "/api/graph")).nodes
                         if n.id == n2)
            @test moved.position == [7, 8]
            @test moved.params.span == 9

            # An unknown id is a 404, not a 400 that reads like a bad parameter.
            @test ask(ctx, "DELETE", "/api/nodes/nope").status == 404
            @test ask(ctx, "DELETE", "/api/edges/nope").status == 404
            # A bad parameter is the client's fault, and says what was wrong.
            bad = ask(ctx, "POST", "/api/nodes";
                body = Dict("kind" => "ema", "params" => Dict("span" => "wide")))
            @test bad.status == 400
            @test occursin("span", asjson(bad).error)
            @test ask(ctx, "POST", "/api/nodes"; body = Dict("kind" => "nosuch")).status ==
                  400
            @test ask(ctx, "POST", "/api/nodes"; body = Dict()).status == 400

            @test ask(ctx, "DELETE", "/api/edges/$e").status == 200
            @test ask(ctx, "DELETE", "/api/nodes/$n1").status == 200
            @test length(asjson(ask(ctx, "GET", "/api/graph")).nodes) == 1
        end
    end

    @testset "running, freezing and writing" begin
        withserver() do ctx
            n1, n2, _ = buildchain(ctx)
            g = runtoready(ctx, [n2])
            node = only(n for n in g.nodes if n.id == n2)
            @test node.status == "ok"
            @test node.results.out.rows == 80
            @test "x_ema_5" in node.results.out.columns

            # Moving a node does not throw its result away.
            ask(ctx, "PATCH", "/api/nodes/$n2"; body = Dict("position" => [1, 1]))
            still = only(n for n in asjson(ask(ctx, "GET", "/api/graph")).nodes
                         if n.id == n2)
            @test still.status == "ok"
            @test still.results.out.rows == 80

            # Editing it does.
            ask(ctx, "PATCH", "/api/nodes/$n2";
                body = Dict("params" => Dict("column" => "x", "span" => 3)))
            stale = only(n for n in asjson(ask(ctx, "GET", "/api/graph")).nodes
                         if n.id == n2)
            @test stale.status == "idle"
            @test isempty(stale.results)

            @test ask(ctx, "POST", "/api/cancel").status == 200
            @test ask(ctx, "POST", "/api/run"; body = Dict()).status == 400

            frozen = ask(ctx, "POST", "/api/nodes/$n1/freeze"; body = Dict("name" => "pin"))
            @test frozen.status == 200
            @test asjson(frozen).table == "pin"
            @test "pin" in [String(t.name) for t in asjson(ask(ctx, "GET", "/api/tables"))]

            path = joinpath(mktempdir(), "out.csv")
            w = asjson(ask(ctx, "POST", "/api/nodes";
                body = Dict("kind" => "writecsv", "params" => Dict("path" => path)))).id
            ask(ctx, "POST", "/api/edges"; body = Dict("from" => [n1, "out"],
                "to" => [String(w), "in"]))
            # Watching a write node must not write; only an explicit write does.
            runtoready(ctx, [String(w)])
            @test !isfile(path)
            @test ask(ctx, "POST", "/api/write/$w").status == 200
            @test isfile(path)
            @test ask(ctx, "POST", "/api/write/$n1").status == 400
        end
    end

    @testset "a failing node is reported where it failed" begin
        withserver() do ctx
            n1, _, _ = buildchain(ctx)
            bad = asjson(ask(ctx, "POST", "/api/nodes";
                body = Dict("kind" => "addcolumns",
                    "params" => Dict("function" => "r -> error(\"boom\")")))).id
            ask(ctx, "POST", "/api/edges";
                body = Dict("from" => [n1, "out"], "to" => [String(bad), "in"]))
            g = runtoready(ctx, [String(bad)])
            node = only(n for n in g.nodes if n.id == bad)
            @test node.status == "error"
            @test occursin("boom", node.error.message)
            @test node.error.node == bad
        end
    end

    @testset "contexts, tables and uploads" begin
        withserver() do ctx
            contexts = asjson(ask(ctx, "GET", "/api/contexts"))
            @test sort(collect(String.(keys(contexts)))) == ["analysis", "train"]
            @test ask(ctx, "PUT", "/api/contexts/preview";
                body = Dict("timetype" => "Int64", "start" => 0, "stop" => 11)).status ==
                  200
            @test ctx.s.contexts["preview"] == Context(0, 11)

            csv = "time,y\n1,1.5\n2,2.5\n3,3.5\n"
            up = HTTP.request("POST", ctx.base * "/api/tables/uploaded?format=csv",
                ["Authorization" => "Bearer $(ctx.token)"], Vector{UInt8}(csv);
                status_exception = false, retry = false)
            @test up.status == 201
            @test asjson(up).table.rows == 3
            @test nrow(ctx.s.tables["uploaded"]) == 3

            # A lookup table has no `:time` column, and must upload anyway.
            timeless = "sym,score\nAAPL,1.5\nMSFT,2.5\n"
            up2 = HTTP.request("POST", ctx.base * "/api/tables/scores?format=csv",
                ["Authorization" => "Bearer $(ctx.token)"], Vector{UInt8}(timeless);
                status_exception = false, retry = false)
            @test up2.status == 201
            @test names(ctx.s.tables["scores"]) == ["sym", "score"]

            empty = HTTP.request("POST", ctx.base * "/api/tables/nothing?format=csv",
                ["Authorization" => "Bearer $(ctx.token)"], UInt8[];
                status_exception = false, retry = false)
            @test empty.status == 400
        end
    end

    @testset "results and diagnostics" begin
        withserver() do ctx
            n1, n2, _ = buildchain(ctx)

            # A node that exists but has not been run is a 409, not a 404: run
            # it, do not go looking for another id.
            notyet = ask(ctx, "GET", "/api/results/$n2/out")
            @test notyet.status == 409
            @test asjson(notyet).id == n2

            runtoready(ctx, [n2])
            page = asjson(ask(ctx, "GET", "/api/results/$n2/out?offset=2&limit=3"))
            @test page.data.columns == ["time", "x", "k", "x_ema_5"]
            @test length(page.data.rows) == 3
            @test page.data.total == 80
            @test page.data.rows[1][1] == 3
            # The page size is capped, so one request cannot ask for a million rows.
            @test length(asjson(ask(ctx, "GET",
                "/api/results/$n2/out?limit=99999")).data.rows) <= 1000
            keyed = asjson(ask(ctx, "GET", "/api/results/$n2/out?key=k%3Da&limit=500"))
            @test keyed.data.total == 40
            narrow = asjson(ask(ctx, "GET", "/api/results/$n2/out?columns=time,x_ema_5"))
            @test narrow.data.columns == ["time", "x_ema_5"]

            acf = asjson(ask(ctx, "GET",
                "/api/diagnostics/$n2/out/acf?column=x&lags=10"))
            @test acf.kind == "acf"
            @test acf.summary.lags == 10
            @test length(acf.data.values) == 11
            series = asjson(ask(ctx, "GET",
                "/api/diagnostics/$n2/out/series?columns=x,x_ema_5&maxpoints=20"))
            @test length(series.data.series) == 2
            @test series.data.series[1].downsampled == true

            @test ask(ctx, "GET", "/api/diagnostics/$n2/out/nosuch?column=x").status == 400
            @test ask(ctx, "GET", "/api/diagnostics/$n2/out/acf").status == 400
            @test ask(ctx, "GET", "/api/results/$n2/nosuchport").status == 404
            @test ask(ctx, "GET", "/api/results/nosuch/out").status == 404
            @test ask(ctx, "GET", "/api/results/$n2/out?offset=-1").status == 400
        end
    end

    # The Ljung-Box test has to give up the model's parameters as degrees of
    # freedom, and `applyarma` drops the model column — so an in-sample stream
    # carries no model. The route is the one place that knows both the frame and
    # the node, and fills it in from the fit node's own parameters.
    @testset "the residual panel gets its dof and fit window from the node" begin
        rng = Xoshiro(17)
        y = zeros(240)
        for t in 2:240
            y[t] = 0.7 * y[t-1] + randn(rng)
        end
        s = Loki.Session(; tables = (df = DataFrame(time = 1:240, y = y),),
            contexts = (analysis = Context(0, 241), train = Context(0, 121)))
        withserver(; session = s) do ctx
            n1 = asjson(ask(ctx, "POST", "/api/nodes";
                body = Dict("kind" => "table", "params" => Dict("table" => "df")))).id
            fit = asjson(ask(ctx, "POST", "/api/nodes";
                body = Dict("kind" => "fit",
                    "params" => Dict("family" => "arma", "column" => "y",
                        "order" => [2, 0, 1], "fitcontext" => "train")))).id
            ask(ctx, "POST", "/api/edges";
                body = Dict("from" => [n1, "out"], "to" => [fit, "in"]))
            g = runtoready(ctx, [String(fit)])
            node = only(n for n in g.nodes if n.id == fit)
            # The fit's in-sample port looks ahead, and says so.
            @test node.acausal == true
            @test node.acausalports.insample == true
            @test node.acausalports.model == false

            panel = asjson(ask(ctx, "GET",
                "/api/diagnostics/$fit/insample/residuals?column=y"))
            @test panel.summary.dof == 3          # p + q, from the node's order
            @test panel.summary.fitstop == 121    # from the node's fitcontext
            @test panel.summary.insample.n == 120
            @test panel.summary.outofsample.n == 120
            @test sort(collect(String.(keys(panel.panels)))) ==
                  ["acf", "fitted", "histogram", "ljungbox", "pacf", "qqplot", "series"]
            # An explicit dof still wins.
            @test asjson(ask(ctx, "GET",
                "/api/diagnostics/$fit/insample/residuals?column=y&dof=5")).summary.dof ==
                  5

            report = asjson(ask(ctx, "GET", "/api/diagnostics/$fit/model/fit"))
            @test report.summary.status == "ok"
            @test report.summary.order == [2, 0, 1]

            # The fan is asked for on the port that has the series; the route
            # supplies the models from the `model` port beside it, because
            # `applyarma` dropped that column on the way through.
            fan = asjson(ask(ctx, "GET",
                "/api/diagnostics/$fit/insample/forecast?column=y&h=4"))
            @test fan.summary.h == 4
            @test length(fan.data.mean) == 4
            @test isempty(fan.warnings)
            @test fan.summary.model.status == "ok"
        end
    end

    @testset "export, save and open" begin
        dir = mktempdir()
        withserver() do ctx
            _, n2, _ = buildchain(ctx)
            runtoready(ctx, [n2])

            script = ask(ctx, "GET", "/api/export")
            @test script.status == 200
            @test startswith(HTTP.header(script, "Content-Type"), "text/x-julia")
            text = String(script.body)
            @test occursin("ema(:x; span = 5)", text)
            @test occursin("readtable(tables.df)", text)
            @test ask(ctx, "GET", "/api/export?tables=nonsense").status == 400

            path = joinpath(dir, "saved.loki.json")
            @test asjson(ask(ctx, "GET", "/api/session?path=$path")).path == path
            @test isfile(path)
            @test ask(ctx, "GET", "/api/session").status == 400

            # Opening replaces what the server is serving, in place: the session
            # object the REPL holds is the one that changes.
            before = objectid(ctx.s)
            ask(ctx, "DELETE", "/api/nodes/$n2")
            @test length(asjson(ask(ctx, "GET", "/api/graph")).nodes) == 1
            @test ask(ctx, "POST", "/api/session"; body = Dict("path" => path)).status ==
                  200
            @test objectid(ctx.s) == before
            @test length(asjson(ask(ctx, "GET", "/api/graph")).nodes) == 2
            @test ask(ctx, "POST", "/api/session";
                body = Dict("path" => joinpath(dir, "gone.loki.json"))).status == 500
        end
    end

    # Collect what a socket receives while `body()` runs. The socket task is
    # always joined, so a test never leaves one behind for Aqua to find.
    function withsocket(body, ctx; token = ctx.token, headers = Pair{String,String}[],
        settle = 0.6)
        got = String[]
        opened = Threads.Event()
        url = "ws://127.0.0.1:$(ctx.port)/ws" * (token === nothing ? "" : "?token=$token")
        sock = Threads.@spawn try
            HTTP.WebSockets.open(url; headers) do ws
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
        try
            body(got)
        finally
            sleep(settle)
            Loki.stop!(ctx.s)
            try
                wait(sock)
            catch
            end
        end
        return got
    end

    events(got) = [JSON3.read(g) for g in got]
    kinds(got) = [String(e.event) for e in events(got)]

    @testset "the websocket carries every change" begin
        withserver() do ctx
            got = withsocket(ctx) do _
                n1, n2, _ = buildchain(ctx)
                runtoready(ctx, [n2])
            end
            es = events(got)
            @test first(kinds(got)) == "hello"
            @test first(es).payload.seq isa Integer
            # The sequence is monotonic, so a client can tell it missed nothing.
            numbered = [e.seq for e in es if String(e.event) != "heartbeat"]
            @test issorted(numbered)
            @test "graph_changed" in kinds(got)
            @test "node_status" in kinds(got)
            @test "result_ready" in kinds(got)
            @test "run_progress" in kinds(got)
            ready = only(e for e in es if String(e.event) == "result_ready")
            @test ready.payload.rows == 80
            # An edit made over HTTP is attributed to the browser.
            @test all(e -> String(e.origin) == "ui",
                [e for e in es if String(e.event) == "graph_changed"])
        end
    end

    @testset "an edit from the REPL reaches a browser, with its origin" begin
        withserver() do ctx
            got = withsocket(ctx) do _
                Loki.withorigin(:mcp) do
                    Loki.addnode!(ctx.s, "emptyframe", Dict())
                end
                sleep(0.3)
            end
            added = only(e for e in events(got)
                         if String(e.event) == "graph_changed" &&
                            String(e.payload.change) == "addnode")
            @test String(added.origin) == "mcp"
        end
    end

    @testset "a ping is answered" begin
        withserver() do ctx
            got = String[]
            opened = Threads.Event()
            sock = Threads.@spawn HTTP.WebSockets.open(
                "ws://127.0.0.1:$(ctx.port)/ws?token=$(ctx.token)") do ws
                notify(opened)
                HTTP.WebSockets.send(ws, JSON3.write(Dict("type" => "ping")))
                for msg in ws
                    push!(got, String(msg))
                    any(g -> occursin("pong", g), got) && break
                end
            end
            wait(opened)
            sleep(0.8)
            Loki.stop!(ctx.s)
            try
                wait(sock)
            catch
            end
            @test any(g -> JSON3.read(g).event == "pong", got)
        end
    end

    @testset "the upgrade is refused without a token or from a foreign origin" begin
        withserver() do ctx
            for (label, token, headers) in
                (("no token", nothing, Pair{String,String}[]),
                ("wrong token", "0"^64, Pair{String,String}[]),
                ("foreign origin", ctx.token, ["Origin" => "http://evil.example"]),
                ("foreign host", ctx.token, ["Host" => "evil.example"]))

                refused = try
                    HTTP.WebSockets.open(_ -> nothing,
                        "ws://127.0.0.1:$(ctx.port)/ws" *
                        (token === nothing ? "" : "?token=$token"); headers)
                    false
                catch
                    true
                end
                @test refused || label == ""
            end
            # ... and still accepted with one.
            ok = try
                HTTP.WebSockets.open(ws -> nothing,
                    "ws://127.0.0.1:$(ctx.port)/ws?token=$(ctx.token)")
                true
            catch
                false
            end
            @test ok
        end
    end

    @testset "serving twice, and stopping" begin
        s = serversession()
        Loki.serve(s; port = 0, open_browser = false)
        try
            @test Loki.server(s) !== nothing
            @test_throws ArgumentError Loki.serve(s; port = 0, open_browser = false)
            @test occursin("#token=", Loki.weburl(s))
            @test_throws ArgumentError Loki.weburl(Loki.server(s); public = true)
        finally
            Loki.stop!(s)
        end
        @test Loki.server(s) === nothing
        @test Loki.stop!(s) === s              # stopping twice is not an error
        @test_throws ArgumentError Loki.weburl(s)
    end
end
