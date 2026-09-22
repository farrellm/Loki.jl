# Session events: every mutation broadcast, under the lock, without ever blocking
# on a subscriber that has stopped reading.

# Collect what a subscriber sees while `body` runs, then close it.
function recorded(s::Loki.Session, body; buffer = 256, settle = 0.4)
    sub = Loki.subscribe!(s; buffer)
    seen = Loki.Event[]
    reader = Threads.@spawn for e in sub
        push!(seen, e)
    end
    try
        body()
    finally
        # Events are offered under the lock but read on another task, so give the
        # reader a moment before closing its queue out from under it.
        sleep(settle)
        Loki.unsubscribe!(s, sub)
        wait(reader)
    end
    return seen, sub
end

changes(seen) = [e.payload["change"] for e in seen if e.kind === :graph_changed]
ofkind(seen, kind) = [e for e in seen if e.kind === kind]

function eventsession()
    df = DataFrame(time = 1:60, x = Float64.(1:60))
    return Loki.Session(; tables = (df = df,), contexts = (analysis = Context(0, 61),))
end

@testset "events" begin
    @testset "every mutation is broadcast" begin
        s = eventsession()
        local src, sm
        seen, _ = recorded(
            s,
            () -> begin
                src = Loki.addnode!(s, "table", Dict("table" => "df"))
                sm = Loki.addnode!(s, "ema", Dict("column" => "x", "span" => 5))
                edge = Loki.connect!(s, (src, :out), (sm, :in))
                Loki.setposition!(s, sm, (40, 90))
                Loki.updatenode!(s, sm, Dict("column" => "x", "span" => 7))
                Loki.setcontext!(s, "preview", Context(0, 11))
                Loki.removecontext!(s, "preview")
                Loki.setprelude!(s, "helper(x) = x + 1")
                Loki.addtable!(s, "other", DataFrame(time = 1:3, y = [1.0, 2.0, 3.0]))
                Loki.disconnect!(s, edge)
                Loki.removenode!(s, sm)
            end,
        )
        @test changes(seen) == ["addnode", "addnode", "connect", "position",
            "updatenode", "setcontext", "removecontext", "setprelude", "addtable",
            "disconnect",
            "removenode"]
        # Every event is numbered, in order, with no repeats.
        @test [e.seq for e in seen] == collect(1:length(seen))
        @test all(e -> e.origin === :repl, seen)

        added = first(ofkind(seen, :graph_changed))
        @test added.payload["node"]["kind"] == "table"
        @test added.payload["node"]["params"]["table"] == "df"
        connected = seen[findfirst(==("connect"), changes(seen))]
        @test connected.payload["edge"]["from"] == Any[src, "out"]
        # An edit invalidates downstream, and says which nodes in one event rather
        # than one status event each.
        @test seen[findfirst(==("updatenode"), changes(seen))].payload["invalidated"] ==
              [sm]
        # Moving a node invalidates nothing: positions play no part in evaluation.
        @test !haskey(seen[findfirst(==("position"), changes(seen))].payload,
            "invalidated")
        @test seen[findfirst(==("addtable"), changes(seen))].payload["table"]["rows"] == 3
        @test seen[findfirst(==("setcontext"), changes(seen))].payload["context"]["stop"] ==
              11
    end

    @testset "a run reports its progress and results" begin
        s = eventsession()
        local sm
        seen, _ = recorded(
            s,
            () -> begin
                src = Loki.addnode!(s, "table", Dict("table" => "df"))
                sm = Loki.addnode!(s, "ema", Dict("column" => "x", "span" => 5))
                Loki.connect!(s, (src, :out), (sm, :in))
                wait(Loki.run!(s, [sm]))
            end,
        )
        states = [e.payload["state"] for e in ofkind(seen, :run_progress)]
        @test first(states) == "started" && last(states) == "done"
        statuses = [e.payload["status"] for e in ofkind(seen, :node_status)]
        @test statuses == ["running", "ok"]
        ready = only(ofkind(seen, :result_ready))
        @test ready.payload["id"] == sm && ready.payload["port"] == "out"
        @test ready.payload["rows"] == 60
        @test "x_ema_5" in ready.payload["columns"]
        @test ready.payload["context"]["timetype"] == "Int64"
    end

    @testset "a failing node is reported where it failed" begin
        s = eventsession()
        seen, _ = recorded(
            s,
            () -> begin
                src = Loki.addnode!(s, "table", Dict("table" => "df"))
                bad = Loki.addnode!(
                    s,
                    "addcolumns",
                    Dict("function" => "r -> error(\"boom\")"),
                )
                down = Loki.addnode!(s, "head", Dict("n" => 3))
                Loki.connect!(s, (src, :out), (bad, :in))
                Loki.connect!(s, (bad, :out), (down, :in))
                wait(Loki.run!(s, [down]))
            end,
        )
        statuses = Dict(e.payload["id"] => e.payload["status"]
             for e in ofkind(seen, :node_status))
        @test count(==("error"), values(statuses)) == 1
        @test count(==("blocked"), values(statuses)) >= 1
        failed = only(e for e in ofkind(seen, :node_status)
                   if e.payload["status"] == "error")
        @test occursin("boom", failed.payload["error"]["message"])
    end

    @testset "origin travels, including into the run's worker" begin
        s = eventsession()
        seen, _ = recorded(
            s,
            () -> begin
                src = Loki.withorigin(:mcp) do
                    Loki.addnode!(s, "table", Dict("table" => "df"))
                end
                Loki.withorigin(:ui) do
                    sm = Loki.addnode!(s, "ema", Dict("column" => "x", "span" => 3))
                    Loki.connect!(s, (src, :out), (sm, :in))
                    wait(Loki.run!(s, [sm]))
                end
            end,
        )
        @test first(seen).origin === :mcp
        # The worker outlives the request that started it; the run carries the
        # origin so its results are still attributed to whoever asked.
        @test all(e -> e.origin === :ui, seen[2:end])
        @test only(ofkind(seen, :result_ready)).origin === :ui
        @test Loki.currentorigin() === :repl
        @test Loki.withorigin(() -> Loki.currentorigin(), :mcp) === :mcp
    end

    @testset "freeze and write are reported too" begin
        s = eventsession()
        path = joinpath(mktempdir(), "out.csv")
        seen, _ = recorded(s, () -> begin
            src = Loki.addnode!(s, "table", Dict("table" => "df"))
            w = Loki.addnode!(s, "writecsv", Dict("path" => path))
            Loki.connect!(s, (src, :out), (w, :in))
            Loki.freeze!(s, src; name = "pinned")
            Loki.write!(s, w)
        end)
        @test "freeze" in changes(seen)
        frozen = seen[findfirst(==("freeze"), changes(seen))]
        @test frozen.payload["name"] == "pinned"
        @test frozen.payload["table"]["frame"] == true
        logged = only(ofkind(seen, :log))
        @test logged.payload["level"] == "info"
        @test occursin("writecsv", logged.payload["message"])
    end

    @testset "a subscriber that stops reading is dropped, not waited on" begin
        s = eventsession()
        # Never read this one: offering must not block the session lock.
        sub = Loki.subscribe!(s; buffer = 4)
        src = Loki.addnode!(s, "table", Dict("table" => "df"))
        elapsed = @elapsed for i in 1:200
            Loki.setposition!(s, src, (i, i))
        end
        @test elapsed < 10          # it would never finish if a full queue blocked
        @test sub.dropped > 0
        @test sub.queued[] == 4

        # The events that did land are numbered, and the gaps are visible — which
        # is how a client knows to refetch rather than trust what it has.
        got = Loki.Event[]
        for _ in 1:4
            push!(got, Loki.nextevent(sub))
        end
        @test [e.seq for e in got] == [1, 2, 3, 4]
        @test s.seq == 201 > last(got).seq

        Loki.unsubscribe!(s, sub)
        @test !isopen(sub)
        @test Loki.nextevent(sub) === nothing
        @test isempty(s.subscribers)
    end

    @testset "two subscribers both see everything" begin
        s = eventsession()
        a = Loki.subscribe!(s)
        b = Loki.subscribe!(s)
        Loki.addnode!(s, "table", Dict("table" => "df"))
        Loki.unsubscribe!(s, a)
        Loki.unsubscribe!(s, b)
        @test Loki.nextevent(a).payload["change"] == "addnode"
        @test Loki.nextevent(b).payload["change"] == "addnode"
        @test Loki.nextevent(a) === nothing
    end

    @testset "events serialize" begin
        s = eventsession()
        seen, _ = recorded(
            s,
            () -> begin
                src = Loki.addnode!(s, "table", Dict("table" => "df"))
                sm = Loki.addnode!(s, "ema", Dict("column" => "x", "span" => 5))
                Loki.connect!(s, (src, :out), (sm, :in))
                wait(Loki.run!(s, [sm]))
            end,
        )
        for e in seen
            doc = JSON3.read(JSON3.write(Loki.eventjson(e)))
            @test doc.event == String(e.kind)
            @test doc.origin == String(e.origin)
            @test doc.seq == e.seq
        end
    end
end
