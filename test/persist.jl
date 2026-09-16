# Persistence: a session saved to `.loki.json` and opened again is the same
# analysis — the same graph, contexts, prelude and tables, running to the same
# frames.

using JSON3

function persistsession()
    df = DataFrame(time = 1:40, k = repeat([1, 2], 20),
        close = 100.0 .+ cumsum(simulate(Xoshiro(12), 40)))
    dim = DataFrame(k = [1, 2], label = ["a", "b"])
    s = Loki.Session(; tables = (prices = df, dim = dim),
        contexts = (analysis = Context(0, 41), train = Context(0, 21)))
    Loki.setcontext!(s, "fractional", Context(0.0, 41.0))
    Loki.setcontext!(s, "daily", Context(Date(2020, 1, 1), Date(2021, 1, 1)))
    Loki.setcontext!(s, "stamped",
        Context(DateTime(2020, 1, 1), DateTime(2020, 1, 2, 6, 30)))
    Loki.setprelude!(s, "positive(x) = x > 0")
    src = Loki.addnode!(s, "table", Dict("table" => "prices"); position = (10, 20))
    kept = Loki.addnode!(s, "filterrows", Dict("predicate" => "r -> positive(r.close)"))
    logc = Loki.addnode!(s, "logtransform", Dict("column" => "close"))
    dlog = Loki.addnode!(s, "difference", Dict("column" => "close_log", "order" => 2))
    look = Loki.addnode!(s, "lookupjoin", Dict("table" => "dim", "key" => "k"))
    fit = Loki.addnode!(s, "fit",
        Dict("family" => "ar", "column" => "close_log_diff_2_1", "p" => 2,
            "fitcontext" => "train"))
    for (from, to) in ((src, kept), (kept, logc), (logc, dlog), (dlog, look), (look, fit))
        Loki.connect!(s, (from, :out), (to, :in))
    end
    # A variadic port, whose edge order the file has to keep: `merge` interleaves
    # by time, and rows sharing a timestamp keep the order their inputs were
    # connected in.
    left = Loki.addnode!(s, "head", Dict("n" => 3))
    right = Loki.addnode!(s, "head", Dict("n" => 4))
    both = Loki.addnode!(s, "merge")
    Loki.connect!(s, (look, :out), (left, :in))
    Loki.connect!(s, (look, :out), (right, :in))
    Loki.connect!(s, (right, :out), (both, :in))
    Loki.connect!(s, (left, :out), (both, :in))
    return s, (; src, kept, logc, dlog, look, fit, left, right, both)
end

@testset "persistence" begin
    @testset "round trip" begin
        dir = mktempdir()
        path = joinpath(dir, "analysis.loki.json")
        s, ids = persistsession()
        # A frozen frame is session state too, and travels as a frame.
        wait(Loki.run!(s, [ids.dlog]))
        Loki.freeze!(s, ids.dlog; name = "frozenlog")
        targets = [(ids.fit, :insample), (ids.fit, :model), (ids.both, :out)]
        wait(Loki.run!(s, targets))

        @test Loki.savesession(path, s) == path
        @test isfile(path)
        @test isdir(joinpath(dir, "analysis.tables"))

        doc = JSON3.read(read(path, String))
        @test doc.format == "loki"
        @test doc.version == 1
        @test doc.prelude == "positive(x) = x > 0"
        @test doc.contexts.analysis.timetype == "Int64"
        @test doc.contexts.daily.start == "2020-01-01"
        @test doc.contexts.stamped.stop == "2020-01-02T06:30:00"
        @test doc.contexts.fractional.stop == 41.0
        @test Set(e.name for e in doc.tables) == Set(["prices", "dim", "frozenlog"])
        @test all(e -> !startswith(e.path, "/"), doc.tables)

        opened = Loki.opensession(path)
        @test opened.contexts == s.contexts
        @test opened.usercode.prelude == s.usercode.prelude
        @test Set(keys(opened.tables)) == Set(keys(s.tables))
        @test isequal(DataFrame(opened.tables["prices"]), DataFrame(s.tables["prices"]))
        # The frozen table comes back a frame, with its context and its semantics.
        frozen = opened.tables["frozenlog"]
        @test frozen isa CausalFrame
        @test context(frozen) == context(s.tables["frozenlog"])

        @test opened.graph.order == s.graph.order
        for id in s.graph.order
            @test opened.graph.nodes[id].kind == s.graph.nodes[id].kind
            @test opened.graph.nodes[id].params == s.graph.nodes[id].params
            @test opened.graph.nodes[id].position == s.graph.nodes[id].position
        end
        @test [(e.id, e.from, e.to) for e in opened.graph.edges] ==
              [(e.id, e.from, e.to) for e in s.graph.edges]
        # Connection order is what orders a variadic port, so it has to survive.
        @test [e.from[1] for e in Loki.inedges(opened.graph, ids.both)] ==
              [ids.right, ids.left]

        # The reopened session is the same analysis: it runs to the same frames.
        wait(Loki.run!(opened, targets))
        for (id, port) in targets
            @test Loki.status(s, id) === :ok
            @test Loki.status(opened, id) === :ok
            before = Loki.result(s, id; port)
            after = Loki.result(opened, id; port)
            @test before !== nothing && after !== nothing
            @test isequal(comparable(after), comparable(before))
        end

        # Ids are never reused, across a save and an open as well.
        removed = Loki.addnode!(opened, "emptyframe")
        Loki.removenode!(opened, removed)
        reopened = Loki.opensession(Loki.savesession(path, opened))
        @test Loki.addnode!(reopened, "emptyframe") != removed
    end

    @testset "what a session file is not" begin
        dir = mktempdir()
        foreign = joinpath(dir, "foreign.json")
        write(foreign, "{\"format\": \"something else\", \"version\": 1}")
        @test_throws ArgumentError Loki.opensession(foreign)

        notjson = joinpath(dir, "notjson.loki.json")
        write(notjson, "this is not JSON at all")
        err = try
            Loki.opensession(notjson)
        catch e
            e
        end
        @test err isa ArgumentError && occursin("not a Loki session file", err.msg)

        future = joinpath(dir, "future.loki.json")
        write(future, "{\"format\": \"loki\", \"version\": 99}")
        err = try
            Loki.opensession(future)
        catch e
            e
        end
        @test err isa ArgumentError && occursin("newer Loki", err.msg)

        # A header alone is not a session: a file missing a section it must have,
        # or holding one of the wrong shape, is reported as such rather than as a
        # KeyError from the JSON.
        truncated = joinpath(dir, "truncated.loki.json")
        write(truncated, """{"format": "loki", "version": 1, "contexts": {}}""")
        err = try
            Loki.opensession(truncated)
        catch e
            e
        end
        @test err isa ArgumentError && occursin("it has no nodes", err.msg)

        misshapen = joinpath(dir, "misshapen.loki.json")
        write(
            misshapen,
            """{"format": "loki", "version": 1, "contexts": {}, "nodes": 3,
 "edges": []}""",
        )
        err = try
            Loki.opensession(misshapen)
        catch e
            e
        end
        @test err isa ArgumentError && occursin("it has no nodes", err.msg)

        # A node the kinds cannot rebuild fails on that node.
        unknown = joinpath(dir, "unknown.loki.json")
        write(
            unknown,
            """
{"format": "loki", "version": 1, "contexts": {}, "prelude": "", "nextid": 1,
 "nodes": [{"id": "n1", "kind": "nosuchkind", "params": {}, "position": [0, 0]}],
 "edges": [], "tables": []}
""",
        )
        err = try
            Loki.opensession(unknown)
        catch e
            e
        end
        @test err isa Loki.NodeError && err.id == "n1"

        badparam = joinpath(dir, "badparam.loki.json")
        write(
            badparam,
            """
{"format": "loki", "version": 1, "contexts": {}, "prelude": "", "nextid": 1,
 "nodes": [{"id": "n1", "kind": "head", "params": {"n": "three"},
            "position": [0, 0]}],
 "edges": [], "tables": []}
""",
        )
        @test_throws Loki.NodeError Loki.opensession(badparam)

        # A context Loki cannot write is refused at the save, not silently dropped.
        s = Loki.Session(; contexts = (analysis = Context(0, 10),))
        Loki.setcontext!(s, "clocktime", Context(Time(0), Time(1)))
        @test_throws ArgumentError Loki.savesession(joinpath(dir, "times.loki.json"), s)

        # Including a time type that writes as JSON but that `opensession` has no
        # way to name: saving it would leave a file nothing can open.
        narrow = Loki.Session(; contexts = (analysis = Context(0, 10),))
        Loki.setcontext!(narrow, "small", Context(Int32(0), Int32(10)))
        @test_throws ArgumentError Loki.savesession(joinpath(dir, "narrow.loki.json"),
            narrow)
    end

    @testset "stale snapshots" begin
        dir = mktempdir()
        path = joinpath(dir, "analysis.loki.json")
        tables = joinpath(dir, "analysis.tables")
        s, _ = persistsession()
        Loki.savesession(path, s)
        @test Set(readdir(tables)) == Set(["prices.parquet", "dim.parquet"])

        # A table dropped since the last save takes its snapshot with it, and a
        # file Loki did not write is left alone.
        keepme = joinpath(tables, "notes.txt")
        write(keepme, "mine")
        delete!(s.tables, "dim")
        Loki.savesession(path, s)
        @test Set(readdir(tables)) == Set(["prices.parquet", "notes.txt"])
        @test isfile(keepme)
        @test Set(keys(Loki.opensession(path).tables)) == Set(["prices"])

        # Including when nothing is left to snapshot.
        delete!(s.tables, "prices")
        Loki.savesession(path, s)
        @test Set(readdir(tables)) == Set(["notes.txt"])
    end

    @testset "an empty session" begin
        dir = mktempdir()
        path = joinpath(dir, "empty.loki.json")
        Loki.savesession(path, Loki.Session())
        opened = Loki.opensession(path)
        @test isempty(opened.graph.nodes)
        @test isempty(opened.tables)
        @test !isdir(joinpath(dir, "empty.tables"))
    end
end
