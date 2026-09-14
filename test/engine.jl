const ENGINEROWS = 200

function enginesession()
    n = ENGINEROWS
    rng = Xoshiro(9)
    df = DataFrame(time = 1:n, k = repeat([1, 2], n ÷ 2), x = cumsum(randn(rng, n)) .+ 50)
    quotes = DataFrame(time = 0:10:n, q = Float64.(0:10:n))
    s = Loki.Session(; tables = (df = df, quotes = quotes),
        contexts = (analysis = Context(0, n + 1), short = Context(50, 150),
            wider = Context(-10, n + 50)))
    return s, df
end

# A two-node chain on a fresh session's table source: `up` fed by the table, `down`
# fed by `up` through the named input port. Returns (up, down).
function chain!(s, upkind, upparams, downkind, downparams; port = :in, extra = nothing)
    src = Loki.addnode!(s, "table", Dict("table" => "df"))
    up = Loki.addnode!(s, upkind, upparams)
    down = Loki.addnode!(s, downkind, downparams)
    Loki.connect!(s, (src, :out), (up, :in))
    Loki.connect!(s, (up, :out), (down, port))
    extra === nothing || extra(s, down)
    return up, down
end

@testset "cachedsource and tagged" begin
    frame = load(Context(0, 10), readtable((time = [1, 2], x = [1.0, 2.0])))
    boom = CausalPipeline(ctx -> error("fallback ran"))
    p = Loki.cachedsource(frame, boom)
    @test isequal(DataFrame(load(Context(0, 10), p)), DataFrame(frame))
    @test_throws ErrorException load(Context(0, 11), p)
    @test_throws ErrorException load(Context(1, 10), p)

    failing = readtable((time = [1, 2], x = [1.0, 2.0])) |> addcolumns(r -> error("row"))
    inner = Loki.tagged(failing, "inner")
    outer = Loki.tagged(inner |> filterrows(r -> true), "outer")
    err = try
        load(Context(0, 10), outer)
    catch e
        e
    end
    @test err isa Loki.NodeError
    @test err.id == "inner"
    @test err.exception isa ErrorException
    @test occursin("node inner", sprint(showerror, err))
    @test_throws Loki.NodeError load(
        Context(0, 10),
        Loki.tagged(CausalPipeline(ctx -> error("run")), "r"),
    )
end

@testset "session and engine" begin
    @testset "end to end" begin
        s, df = enginesession()
        src = Loki.addnode!(s, "table", Dict("table" => "df"))
        logx = Loki.addnode!(s, "logtransform", Dict("column" => "x"))
        dx = Loki.addnode!(s, "difference", Dict("column" => "x_log"))
        fit = Loki.addnode!(s, "fit",
            Dict("family" => "arma", "column" => "x_log_diff", "order" => [1, 0, 0]))
        Loki.connect!(s, (src, :out), (logx, :in))
        Loki.connect!(s, (logx, :out), (dx, :in))
        Loki.connect!(s, (dx, :out), (fit, :in))
        @test Loki.status(s, fit) === :idle

        rows = Ref(0)
        run = Loki.run!(s, [(fit, :insample)]; progress = (id, port, n) -> (rows[] = n))
        wait(run)
        @test istaskdone(run.task)
        @test Loki.status(s, fit) === :ok
        out = Loki.result(s, fit; port = :insample)
        reference =
            readtable(df) |> logtransform(:x) |> difference(:x_log) |>
            Loki.Acausal.insample(FitARMA(:x_log_diff; order = (1, 0, 0)))
        @test isequal(
            DataFrame(out),
            DataFrame(load(Context(0, ENGINEROWS + 1), reference)),
        )
        @test rows[] == nrow(out)
        @test Loki.result(s, fit; port = :model) === nothing
        @test_throws ArgumentError Loki.result(s, fit; port = :nope)

        @test Loki.isacausal(s, fit)
        @test Loki.isacausal(s, fit; port = :insample)
        @test !Loki.isacausal(s, fit; port = :model)
        @test !Loki.isacausal(s, dx)

        # Watching a node by id runs every output.
        wait(Loki.run!(s, fit))
        @test Loki.result(s, fit; port = :model) !== nothing
    end

    @testset "cached equals uncached" begin
        ema5 = Dict("column" => "x", "span" => 5)
        families = [
            ("lag, widening", ("ema", ema5, "lag", Dict("offset" => "3"))),
            ("head, stateful", ("ema", ema5, "head", Dict("n" => 7))),
            (
                "summarize, stateful",
                ("ema", ema5, "summarize",
                    Dict(
                        "summarizers" =>
                            [Dict("summarizer" => "Mean", "columns" => ["x_ema_5"])],
                        "key" => "k")),
            ),
            (
                "rolling, widening",
                ("ema", ema5, "addrollingcolumns",
                    Dict("windows" => "(w = 10,)",
                        "summarizers" =>
                            [Dict("summarizer" => "Sum", "columns" => ["x_ema_5"])])),
            ),
            (
                "asofjoin tolerance, widening",
                ("ema", ema5, "asofjoin",
                    Dict("tolerance" => "5")),
            ),
            (
                "fit",
                ("logtransform", Dict("column" => "x"), "fit",
                    Dict("family" => "ar", "column" => "x_log", "p" => 2)),
            ),
        ]
        joinquotes(s, down) = Loki.connect!(s,
            (Loki.addnode!(s, "table", Dict("table" => "quotes")), :out), (down, :right))
        for (name, (upkind, upparams, downkind, downparams)) in families
            @testset "$name" begin
                port =
                    downkind in ("asofjoin",) ? :left :
                    downkind == "addrollingcolumns" ? :data : :in
                extra = downkind == "asofjoin" ? joinquotes : nothing
                outport = downkind == "fit" ? :insample : :out
                s, _ = enginesession()
                up, down = chain!(s, upkind, upparams, downkind, downparams; port, extra)
                # The ancestor is cached over analysis; downstream compiles over its
                # cached source, over the same context and over a narrower one.
                wait(Loki.run!(s, [up]))
                @test Loki.result(s, up) !== nothing
                for context in ("analysis", "short")
                    wait(Loki.run!(s, [(down, outport)]; context))
                    @test Loki.status(s, down) === :ok
                    s2, _ = enginesession()
                    _, down2 =
                        chain!(s2, upkind, upparams, downkind, downparams; port, extra)
                    wait(Loki.run!(s2, [(down2, outport)]; context))
                    @test isequal(DataFrame(Loki.result(s, down; port = outport, context)),
                        DataFrame(Loki.result(s2, down2; port = outport, context)))
                end
            end
        end

        # The substitution is real: a cached ancestor is served even after its
        # table's values change in place, which a re-run would see.
        s, df = enginesession()
        up, down = chain!(s, "ema", ema5, "head", Dict("n" => 5))
        wait(Loki.run!(s, [up]))
        df.x .= 0.0
        wait(Loki.run!(s, [down]))
        @test all(!iszero, DataFrame(Loki.result(s, down)).x_ema_5)
    end

    @testset "errors are attributed" begin
        s, df = enginesession()
        src = Loki.addnode!(s, "table", Dict("table" => "df"))
        bad = Loki.addnode!(s, "addcolumns",
            Dict("function" => "r -> r.time > 150 ? error(\"boom\") : (; y = r.x)"))
        after = Loki.addnode!(s, "ema", Dict("column" => "y", "span" => 3))
        Loki.connect!(s, (src, :out), (bad, :in))
        Loki.connect!(s, (bad, :out), (after, :in))
        wait(Loki.run!(s, [after]))
        @test Loki.status(s, bad) === :error
        @test Loki.status(s, after) === :blocked
        @test Loki.status(s, src) === :idle
        @test Loki.nodeerror(s, after).id == bad
        @test Loki.nodeerror(s, bad).exception isa ErrorException

        # A build error: raised by run! compiling, before any data moves.
        Loki.updatenode!(s, bad, Dict("function" => "r -> (r.x"))
        @test Loki.status(s, after) === :idle
        wait(Loki.run!(s, [after]))
        @test Loki.status(s, bad) === :error
        @test Loki.status(s, after) === :blocked
        @test Loki.nodeerror(s, bad).exception isa ArgumentError

        lonely = Loki.addnode!(s, "ema", Dict("column" => "x", "span" => 3))
        wait(Loki.run!(s, [lonely]))
        @test Loki.status(s, lonely) === :error
        @test Loki.nodeerror(s, lonely).exception isa ArgumentError

        # A frozen frame refuses a context outside its own.
        Loki.updatenode!(s, bad, Dict("function" => "r -> (; y = r.x)"))
        wait(Loki.run!(s, [after]))
        @test Loki.status(s, after) === :ok
        name = Loki.freeze!(s, after)
        @test name == "frozen_$after"
        frozen = Loki.addnode!(s, "table", Dict("table" => name))
        wait(Loki.run!(s, [frozen]))
        @test isequal(DataFrame(Loki.result(s, frozen)), DataFrame(Loki.result(s, after)))
        wait(Loki.run!(s, [frozen]; context = "wider"))
        @test Loki.status(s, frozen) === :error
    end

    @testset "cancellation" begin
        s = Loki.Session(;
            contexts = (analysis = Context(0, 1_000_000), small = Context(0, 100)))
        clk = Loki.addnode!(s, "clock", Dict("interval" => "1", "batchsize" => 10))
        rows = Loki.addnode!(s, "addcolumns", Dict("function" => "r -> (; y = r.time)"))
        Loki.connect!(s, (clk, :out), (rows, :in))
        chunks = Ref(0)
        run = Loki.run!(s, [rows];
            progress = (id, port, n) ->
                (chunks[] += 1; chunks[] == 3 && Loki.cancel!(s)))
        wait(run)
        @test istaskdone(run.task)
        @test run.cancelled[]
        @test chunks[] == 3
        @test Loki.status(s, rows) === :idle
        @test Loki.result(s, rows) === nothing

        # A new run cancels the one in flight.
        first = Loki.run!(s, [rows])
        second = Loki.run!(s, [clk]; context = "small")
        wait(first)
        wait(second)
        @test first.cancelled[]
        @test istaskdone(first.task) && istaskdone(second.task)
        @test Loki.status(s, clk) === :ok
        @test nrow(Loki.result(s, clk; context = "small")) == 100
    end

    @testset "edits invalidate downstream" begin
        s, _ = enginesession()
        src = Loki.addnode!(s, "table", Dict("table" => "df"))
        a = Loki.addnode!(s, "ema", Dict("column" => "x", "span" => 5))
        b = Loki.addnode!(s, "head", Dict("n" => 3))
        Loki.connect!(s, (src, :out), (a, :in))
        Loki.connect!(s, (a, :out), (b, :in))
        wait(Loki.run!(s, [src, a, b]))
        @test all(id -> Loki.status(s, id) === :ok, (src, a, b))
        Loki.updatenode!(s, a, Dict("column" => "x", "span" => 7))
        @test Loki.result(s, src) !== nothing
        @test Loki.result(s, a) === nothing
        @test Loki.result(s, b) === nothing
        @test Loki.status(s, src) === :ok
        @test Loki.status(s, b) === :idle

        wait(Loki.run!(s, [b]))
        edge = only(Loki.inedges(s.graph, b)).id
        Loki.disconnect!(s, edge)
        @test Loki.status(s, b) === :idle
        Loki.removenode!(s, b)
        @test !haskey(s.graph.nodes, b)
        @test_throws ArgumentError Loki.result(s, b)
    end

    @testset "user code and writes" begin
        s, df = enginesession()
        src = Loki.addnode!(s, "table", Dict("table" => "df"))
        kept = Loki.addnode!(s, "filterrows", Dict("predicate" => "r -> keep(r.x)"))
        Loki.connect!(s, (src, :out), (kept, :in))
        # Defined after the session was created, and after the node.
        Loki.setprelude!(s, "keep(x) = x > median(df_x)\nconst df_x = $(repr(df.x))")
        wait(Loki.run!(s, [kept]))
        @test Loki.status(s, kept) === :ok
        @test nrow(Loki.result(s, kept)) == ENGINEROWS ÷ 2

        path = joinpath(mktempdir(), "out.csv")
        writer = Loki.addnode!(s, "writecsv", Dict("path" => path))
        after = Loki.addnode!(s, "head", Dict("n" => 5))
        Loki.connect!(s, (kept, :out), (writer, :in))
        Loki.connect!(s, (writer, :out), (after, :in))
        wait(Loki.run!(s, [after]))
        @test Loki.status(s, after) === :ok
        @test !isfile(path)
        Loki.write!(s, writer)
        @test isfile(path)
        @test_throws ArgumentError Loki.write!(s, after)
    end
end
