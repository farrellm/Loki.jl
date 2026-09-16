# Export: the script printer, that every node kind's `emit` reproduces what its
# `build` does, the table snapshots a script reads back, and that including an
# exported script reproduces the session's frames.

using Dates

# Two fits of the same data say the same thing without being the same object: a
# FittedARMA holds a mutable SARIMA, which `isequal` compares by identity.
fitsummary(fm::FittedARMA) = (fm.order, fm.seasonal_order, fm.status, fm.coefs)
fitsummary(x) = x
comparable(df::DataFrame) = mapcols(col -> map(fitsummary, col), df)
comparable(frame::CausalFrame) = comparable(DataFrame(frame))

@testset "script printer" begin
    E = Loki.exprstring
    @test E(:p1) == "p1"
    @test E(QuoteNode(:x)) == ":x"
    @test E(QuoteNode(Symbol("#x_difflag"))) == "Symbol(\"#x_difflag\")"
    @test E("out.csv") == "\"out.csv\""
    @test E(3) == "3"
    @test E(1.5) == "1.5"
    @test E(true) == "true"
    @test E(nothing) == "nothing"

    @test E(Expr(:call, :emptyframe)) == "emptyframe()"
    @test E(Expr(:call, :head, 3)) == "head(3)"
    @test E(Expr(:call, :f, 1, Expr(:parameters, Expr(:kw, :k, QuoteNode(:v))))) ==
          "f(1; k = :v)"
    @test E(Expr(:call, :f, Expr(:parameters, Expr(:kw, :k, 1)))) == "f(; k = 1)"
    @test E(Expr(:call, :(|>), :p1, Expr(:call, :head, 3))) == "p1 |> head(3)"
    @test E(Expr(:call, :Dict, Expr(:call, :(=>), QuoteNode(:time), :Int))) ==
          "Dict(:time => Int)"

    @test E(Expr(:vect, QuoteNode(:a), QuoteNode(:b))) == "[:a, :b]"
    @test E(Expr(:vect)) == "[]"
    @test E(Expr(:tuple, 1, 0, 1)) == "(1, 0, 1)"
    @test E(Expr(:tuple, 1)) == "(1,)"
    @test E(Expr(:tuple, Expr(:kw, :w, 10))) == "(; w = 10)"

    @test E(Expr(:., :tables, QuoteNode(:prices))) == "tables.prices"
    @test E(Expr(:., :tables, QuoteNode(Symbol("my table")))) == "tables.var\"my table\""
    @test E(Loki.qualified(:CausalFrames, :Acausal, :settime)) ==
          "CausalFrames.Acausal.settime"
    @test E(Expr(:(=), :p_n1, Expr(:call, :emptyframe))) == "p_n1 = emptyframe()"

    # Source text is passed through as it was typed, parenthesized only where it
    # would not parse as a single argument.
    @test E(Loki.Code("r -> r.x > 0")) == "r -> r.x > 0"
    @test E(Loki.Code("Minute(5)")) == "Minute(5)"
    @test E(Loki.Code("(; y = 0.0)")) == "(; y = 0.0)"
    @test E(Loki.Code("[1, 2]")) == "[1, 2]"
    @test E(Loki.Code("5")) == "5"
    @test E(Loki.Code("x = 1")) == "(x = 1)"
    @test E(Loki.Code(2.5)) == "2.5"
    @test Loki.Code("f(x)") == Loki.Code("f(x)")

    @test_throws ArgumentError E(Expr(:block, 1))
end

@testset "every kind can be exported" begin
    for name in Loki.nodekinds()
        # The registry is global, and test/graph.jl registers kinds of its own.
        startswith(name, "test_") && continue
        @test Loki.canemit(Loki.nodekind(name))
    end
    noemit = Loki.OpKind("noemit"; category = "test",
        build = (params, inputs, env) -> (; out = emptyframe()))
    @test !Loki.canemit(noemit)
    @test_throws ArgumentError Loki.emit(noemit, Dict{String,Any}(), Dict{Symbol,Any}())
end

@testset "emit reproduces build" begin
    df = DataFrame(time = 1:10, k = repeat([1, 2], 5), x = Float64.(1:10),
        z = 2.0 .* (1:10) .+ 1, y = [missing; 2.0:10.0])
    ts = DataFrame(time = 1:120, y = simulate(Xoshiro(2), 120))
    quotes = DataFrame(time = [0, 5], q = [1.0, 2.0])
    dim = DataFrame(k = [1, 3], label = ["one", "three"])
    cycles = DataFrame(time = [1, 1, 1, 2, 2], s = ["b", "c", "a", "z", "y"],
        v = [2, 3, 1, 5, 4])
    tables = Dict{String,Any}("df" => df, "ts" => ts, "quotes" => quotes, "dim" => dim,
        "cycles" => cycles)
    contexts = Dict("analysis" => Context(0, 100), "train" => Context(0, 61))
    env = Loki.BuildEnv(; contexts, tables)
    ctx = Context(0, 100)
    tctx = Context(0, 121)

    build(kind, params = Dict{String,Any}(); inputs...) =
        Loki.build(Loki.nodekind(kind), params, Dict{Symbol,Any}(inputs), env)

    sources = Dict(:p_df => build("table", Dict("table" => "df")).out,
        :p_ts => build("table", Dict("table" => "ts")).out,
        :p_quotes => build("table", Dict("table" => "quotes")).out,
        :p_cycles => build("table", Dict("table" => "cycles")).out,
        :p_clock => build("clock", Dict("interval" => "5")).out)

    # The world an exported script runs in: the user module's imports, the
    # acausal names by name, and the session's tables and contexts.
    m = Module(:ExportedScript)
    Core.eval(m, :(using CausalFrames, Loki, Dates, Statistics))
    Core.eval(m, :(using Loki.Acausal: insample))
    Core.eval(m, :(using CausalFrames.Acausal: lead, futurejoin))
    Core.eval(m,
        :(tables = (df = $df, ts = $ts, quotes = $quotes, dim = $dim, cycles = $cycles)))
    Core.eval(m, :(const train = $(contexts["train"])))
    for (name, pipeline) in sources
        Core.eval(m, :($name = $pipeline))
    end

    # Build and emit the same node, then compare what each loads, port by port.
    function agrees(kind, params, context; ports = nothing, inputs...)
        pipes = Dict{Symbol,Any}(
            port => v isa Vector ? [sources[b] for b in v] : sources[v]
            for (port, v) in inputs
        )
        names = Dict{Symbol,Any}(
            port => v isa Vector ? collect(Any, v) : v for (port, v) in inputs
        )
        built = Loki.build(Loki.nodekind(kind), params, pipes, env)
        emitted = Loki.emit(Loki.nodekind(kind), params, names)
        for port in (ports === nothing ? keys(built) : ports)
            text = Loki.exprstring(emitted[port])
            value = Core.eval(m, Meta.parse(text))
            @test isequal(comparable(latest(context, built[port])),
                comparable(latest(context, value)))
        end
    end

    @testset "sources" begin
        agrees("table", Dict("table" => "df"), ctx)
        agrees("table", Dict("table" => "dim", "time" => "k", "checkorder" => false), ctx)
        agrees("emptyframe", Dict{String,Any}(), ctx)
        agrees("clock", Dict("interval" => "5", "batchsize" => 4), Context(0, 20))
        agrees("concatenate", Dict{String,Any}(), ctx; in = [:p_df])
        agrees("merge", Dict{String,Any}(), ctx; in = [:p_df, :p_quotes])
        # A frozen frame keeps frame semantics on both sides.
        frame = load(ctx, sources[:p_df])
        env.tables["frozen"] = frame
        Core.eval(m, :(tables = merge(tables, (frozen = $frame,))))
        agrees("table", Dict("table" => "frozen"), ctx)
    end

    @testset "rows and columns" begin
        agrees("filterrows", Dict("predicate" => "r -> r.x > 5"), ctx; in = :p_df)
        agrees("addcolumns", Dict("function" => "r -> (; w = 2r.x)"), ctx; in = :p_df)
        agrees("selectcolumns", Dict("columns" => ["x", "k"]), ctx; in = :p_df)
        agrees("dropcolumns", Dict("match" => "r\"^[kx]\$\""), ctx; in = :p_df)
        agrees("reordercolumns", Dict("columns" => "y"), ctx; in = :p_df)
        agrees("lag", Dict("offset" => "2"), ctx; in = :p_df)
        agrees("head", Dict("n" => 3), ctx; in = :p_df)
        agrees("settime", Dict("spec" => "r -> r.time + 1"), ctx; in = :p_df)
        agrees("lastrow", Dict("key" => "k"), ctx; in = :p_df)
        agrees("sortcycles", Dict("columns" => "s"), ctx; in = :p_cycles)
        agrees("sortcycles", Dict("function" => "r -> -r.v", "rev" => true), ctx;
            in = :p_cycles)
        agrees("forwardfill", Dict("columns" => "y", "key" => "k", "tolerance" => "5"),
            ctx; in = :p_df)
        agrees("fillmissing", Dict("values" => "(; y = 0.0)"), ctx; in = :p_df)
    end

    @testset "summarizing" begin
        entries = [Dict("summarizer" => "Count"),
            Dict("summarizer" => "Mean", "columns" => ["x"]),
            Dict("summarizer" => "SumPower", "columns" => ["x"],
                "options" => Dict("n" => 2)),
            Dict("summarizer" => "Std", "columns" => ["x"],
                "options" => Dict("corrected" => false)),
            Dict("summarizer" => "Correlation", "columns" => ["x", "z"]),
            Dict("summarizer" => "LinearRegression", "columns" => ["x"],
                "options" => Dict("response" => "z", "name" => "reg",
                    "intercept" => false)),
            Dict("summarizer" => "Lags", "columns" => ["x"],
                "options" => Dict("p" => 2, "name" => "back")),
            Dict("summarizer" => "EMA", "columns" => ["x"],
                "options" => Dict("span" => 3))]
        agrees("summarize", Dict("summarizers" => entries, "key" => "k"), ctx; in = :p_df)
        agrees("addsummarycolumns", Dict("summarizers" => entries), ctx; in = :p_df)
        count1 = [Dict("summarizer" => "Count")]
        agrees("summarizecycles",
            Dict("summarizers" => count1, "key" => "k", "keyset" => "[1, 2, 3]"), ctx;
            in = :p_df)
        sum1 = [Dict("summarizer" => "Sum", "columns" => ["x"])]
        agrees("addrollingcolumns", Dict("windows" => "(w = 2,)", "summarizers" => sum1),
            ctx; data = :p_df)
        agrees("addrollingcolumns", Dict("windows" => "(w = 2,)", "summarizers" => sum1),
            ctx; data = :p_df, from = :p_df)
        agrees("intervalize", Dict("summarizers" => count1, "closelast" => true),
            Context(0, 12); data = :p_df, clock = :p_clock)
        agrees("summarizewindows", Dict("summarizers" => count1, "lookback" => "5"),
            Context(0, 12); data = :p_df, clock = :p_clock)
    end

    @testset "joins and acausal" begin
        agrees("asofjoin", Dict("tolerance" => "5", "rightprefix" => "q_"), ctx;
            left = :p_df, right = :p_quotes)
        agrees("lookupjoin", Dict("table" => "dim", "key" => "k", "unmatched" => "drop"),
            ctx; in = :p_df)
        agrees("futurejoin", Dict{String,Any}(), ctx; left = :p_df, right = :p_quotes)
        agrees("lead", Dict("offset" => "1"), ctx; in = :p_df)
        agrees("acausal_settime", Dict("spec" => "r -> r.time - 1"), ctx; in = :p_df)
    end

    @testset "time series" begin
        agrees("lags", Dict("column" => "x", "p" => 2, "key" => "k"), ctx; in = :p_df)
        agrees("difference", Dict("column" => "x", "order" => 2, "lag" => 2), ctx;
            in = :p_df)
        agrees("logtransform", Dict("column" => "x", "name" => "logx"), ctx; in = :p_df)
        agrees("boxcox", Dict("column" => "x", "lambda" => 0.5), ctx; in = :p_df)
        agrees("ema", Dict("column" => "x", "span" => 3, "key" => "k"), ctx; in = :p_df)
        agrees("ema", Dict("column" => "x", "halflife" => "2"), ctx; in = :p_df)
        agrees("macd", Dict("column" => "x", "fast" => 2, "slow" => 3, "signal" => 2),
            ctx; in = :p_df)
        agrees("ar", Dict("column" => "y", "p" => 1), tctx; in = :p_ts)
    end

    @testset "ARMA and fits" begin
        agrees("fitarma", Dict("column" => "y", "order" => [1, 0, 0]), tctx; in = :p_ts)
        once = Dict("context" => "train",
            "summarizer" => [
                Dict("summarizer" => "FitARMA", "columns" => ["y"],
                    "options" => Dict("order" => [1, 0, 0])),
            ])
        agrees("fitonce", once, tctx; in = :p_ts)
        models = Loki.build(Loki.nodekind("fitonce"), once,
            Dict{Symbol,Any}(:in => sources[:p_ts]), env).out
        sources[:p_models] = models
        Core.eval(m, :(p_models = $models))
        agrees("applyarma", Dict("column" => "y", "horizon" => 1), tctx;
            data = :p_ts, models = :p_models)
        agrees("arma", Dict("column" => "y", "lookback" => "60", "order" => [1, 0, 0]),
            tctx; data = :p_ts, clock = :p_clock)
        agrees("fit", Dict("family" => "ar", "column" => "y", "p" => 2), tctx; in = :p_ts)
        agrees("fit",
            Dict("family" => "ar", "column" => "y", "p" => 1,
                "fitcontext" => "train"), tctx; in = :p_ts)
        agrees("fit", Dict("family" => "arma", "column" => "y", "order" => [1, 0, 1]),
            tctx; in = :p_ts)
    end
end

# The kinds a load cannot compare — file sinks write, and the MLJ operators need
# a model package — are pinned by the text they emit.
@testset "emitted text" begin
    text(kind, params = Dict{String,Any}(); port = :out, inputs...) =
        Loki.exprstring(
            getproperty(
                Loki.emit(Loki.nodekind(kind), params, Dict{Symbol,Any}(inputs)), port),
        )

    @test text(
        "readcsv",
        Dict("path" => "x.csv",
            "types" => "Dict(:time => Int, :x => Float64)"),
    ) ==
          "readcsv(\"x.csv\"; types = Dict(:time => Int, :x => Float64))"
    @test text("readcsv", Dict("path" => "x.csv", "sort" => true, "closed" => true)) ==
          "readcsv(\"x.csv\"; sort = true, closed = true)"
    @test text("writecsv", Dict("path" => "out.csv"); in = :p1) ==
          "p1 |> writecsv(\"out.csv\")"
    @test text("writecsv", Dict("path" => "out.csv", "queue" => 4); in = :p1) ==
          "p1 |> writecsv(\"out.csv\"; queue = 4)"
    @test text("readparquet", Dict("path" => "x.parquet", "backend" => "parquet2")) ==
          "readparquet(\"x.parquet\"; backend = :parquet2)"
    @test text("writeparquet", Dict("path" => "x.parquet"); in = :p1) ==
          "p1 |> writeparquet(\"x.parquet\")"
    @test text("readjls", Dict("path" => "x.jls", "closed" => true)) ==
          "readjls(\"x.jls\"; closed = true)"
    @test text("writejls", Dict("path" => "x.jls"); in = :p1) == "p1 |> writejls(\"x.jls\")"

    @test text("applymodels", Dict("column" => "m", "name" => "yhat");
        data = :p1, models = :p2) ==
          "p1 |> applymodels(p2; column = :m, name = :yhat)"
    @test text("modelreports"; in = :p1) == "p1 |> modelreports()"
    @test text("addpredictions",
        Dict("lookback" => "5", "model" => "Ridge()",
            "predictors" => ["x", "z"], "response" => "y"); data = :p1, clock = :p2) ==
          "p1 |> addpredictions(p2, 5, Ridge(), [:x, :z], :y)"
    @test text("summarize",
        Dict(
            "summarizers" => [
                Dict("summarizer" => "FitModel",
                    "columns" => ["x"],
                    "options" => Dict("model" => "Ridge()", "response" => "y")),
            ],
        ); in = :p1) ==
          "p1 |> summarize([FitModel(Ridge(), [:x], :y)])"
    @test text("fit",
        Dict("family" => "mlj", "column" => "y", "model" => "Ridge()",
            "predictors" => ["x"]); port = :model, in = :p1) ==
          "Loki.fitinput(FitModel(Ridge(), [:x], :y; name = :model), p1) |> \
           summarize(FitModel(Ridge(), [:x], :y; name = :model))"

    # A private intermediate column is spelled the only way it can be.
    @test text("lags", Dict("column" => "x", "p" => 1, "name" => "#tmp"); in = :p1) ==
          "p1 |> lags(:x, 1; name = Symbol(\"#tmp\"))"

    # What `emit` rejects, `build` rejects too.
    bad(kind, params; inputs...) =
        Loki.emit(Loki.nodekind(kind), params, Dict{Symbol,Any}(inputs))
    @test_throws ArgumentError bad("fit", Dict("family" => "arma", "column" => "y");
        in = :p1)
    @test_throws ArgumentError bad("fit", Dict("family" => "ar", "column" => "y");
        in = :p1)
    @test_throws ArgumentError bad("fit", Dict("family" => "mlj", "column" => "y");
        in = :p1)
    @test_throws ArgumentError bad("sortcycles",
        Dict("columns" => "s",
            "function" => "r -> r.v"); in = :p1)
    @test_throws ArgumentError bad("selectcolumns", Dict{String,Any}(); in = :p1)
    @test_throws ArgumentError bad("summarize",
        Dict("summarizers" => [Dict("summarizer" => "Nope")]); in = :p1)
    @test_throws ArgumentError bad("summarize",
        Dict("summarizers" => [Dict("summarizer" => "Sum")]); in = :p1)
    @test_throws ArgumentError bad("summarize", Dict("summarizers" => Dict{String,Any}[]);
        in = :p1)
    @test_throws ArgumentError bad("clock", Dict{String,Any}())
end

@testset "table snapshots" begin
    dir = mktempdir()
    plain = DataFrame(time = 1:3, i = Int32[1, 2, 3], f = [1.5, missing, 3.5],
        s = ["a", "b", missing], b = [true, false, true],
        d = Date(2020, 1, 1) .+ Day.(0:2), t = DateTime(2020, 1, 1) .+ Hour.(0:2))
    file = Loki.savetable(dir, "plain", plain)
    @test file.format === :parquet && !file.frame && file.context === nothing
    @test isequal(DataFrame(Loki.loadtable(file)), plain)

    # A lookup table has no time column, which parquet does not need.
    dim = DataFrame(k = [1, 3], label = ["one", "three"])
    @test isequal(DataFrame(Loki.loadtable(Loki.savetable(dir, "dim", dim))), dim)

    # A frozen frame comes back as the frame it was, rows at `stop` and all, and
    # still refuses a context outside its own.
    ctx = Context(0, 11)
    frame = load(ctx, readtable(plain) |> summarize(Mean(:f)))
    framefile = Loki.savetable(dir, "frame", frame)
    @test framefile.format === :parquet && framefile.frame
    back = Loki.loadtable(framefile)
    @test back isa CausalFrame
    @test context(back) == ctx
    @test isequal(DataFrame(back), DataFrame(frame))
    @test nrow(back) == 1                      # the summary row, emitted at stop
    @test_throws ArgumentError load(Context(0, 20), readtable(back))

    # A frame holding what parquet cannot store falls back to CausalFrames' JLS.
    ts = DataFrame(time = 1:120, y = simulate(Xoshiro(5), 120))
    tctx = Context(0, 121)
    models = load(tctx, readtable(ts) |> fitarma(:y; order = (1, 0, 0)))
    modelfile = Loki.savetable(dir, "models", models)
    @test modelfile.format === :jls && modelfile.frame
    reloaded = Loki.loadtable(modelfile)
    @test isequal(comparable(reloaded), comparable(models))
    @test only(DataFrame(reloaded).model) isa FittedARMA

    # A plain table parquet cannot hold is an error naming the column.
    symbols = DataFrame(time = 1:2, tag = [:a, :b])
    err = try
        Loki.savetable(dir, "symbols", symbols)
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("its column tag holds Symbol", err.msg)
    @test occursin("tables = :argument", err.msg)

    # A table that will not say what its columns hold cannot be checked, and the
    # error says that rather than naming a column called `unknown`.
    rows = Any[(time = 1, tag = :a), (time = 2, tag = :b)]
    err = try
        Loki.savetable(dir, "rows", rows)
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("its columns have unknown type", err.msg)
    @test !occursin("column unknown", err.msg)
end

# A session covering the shapes a script has to get right: a prelude the row
# functions need, several contexts, a table and a frozen frame, a file source, a
# fan-out, a multi-output fit node, and a write node with a consumer downstream.
function exportsession(dir)
    df = DataFrame(time = 1:50, k = repeat([1, 2], 25),
        close = 100.0 .+ cumsum(simulate(Xoshiro(8), 50)))
    dim = DataFrame(k = [1, 2], label = ["a", "b"])
    s = Loki.Session(; tables = (prices = df, dim = dim),
        contexts = (analysis = Context(0, 51), train = Context(0, 26)))
    Loki.setprelude!(s, "positive(x) = x > 0")
    src = Loki.addnode!(s, "table", Dict("table" => "prices"))
    kept = Loki.addnode!(s, "filterrows", Dict("predicate" => "r -> positive(r.close)"))
    logc = Loki.addnode!(s, "logtransform", Dict("column" => "close"))
    dlog = Loki.addnode!(s, "difference", Dict("column" => "close_log"))
    look = Loki.addnode!(s, "lookupjoin", Dict("table" => "dim", "key" => "k"))
    fit = Loki.addnode!(s, "fit",
        Dict("family" => "ar", "column" => "close_log_diff", "p" => 2))
    writer = Loki.addnode!(s, "writecsv", Dict("path" => joinpath(dir, "out.csv")))
    after = Loki.addnode!(s, "head", Dict("n" => 5))
    for (from, to) in ((src, kept), (kept, logc), (logc, dlog), (dlog, look),
        (look, fit), (look, writer), (writer, after))
        Loki.connect!(s, (from, :out), (to, :in))
    end
    wait(Loki.run!(s, [(fit, :insample), (fit, :model), after]))
    # Freezing pins an intermediate result, which exports as a frame snapshot.
    frozen = Loki.freeze!(s, dlog; name = "frozenlog")
    fnode = Loki.addnode!(s, "table", Dict("table" => frozen))
    smooth = Loki.addnode!(s, "ema", Dict("column" => "close_log_diff", "span" => 3))
    Loki.connect!(s, (fnode, :out), (smooth, :in))
    targets = [(fit, :insample), (fit, :model), (after, :out), (smooth, :out)]
    wait(Loki.run!(s, targets))
    return s, targets, joinpath(dir, "out.csv")
end

# The name the script binds a loaded frame to.
framebinding(s, id, port) =
    length(Loki.outputs(Loki.nodekind(s.graph.nodes[id].kind))) == 1 ?
    Symbol("frame_", id) : Symbol("frame_", id, "_", port)

@testset "exportjulia" begin
    @testset "including the script reproduces the session" begin
        dir = mktempdir()
        s, targets, csv = exportsession(dir)
        path = exportjulia(joinpath(dir, "script.jl"), s)
        @test isfile(path)
        @test Set(readdir(dir)) ==
              Set(["script.jl", "prices.parquet", "dim.parquet", "frozenlog.parquet"])

        m = Module(:ExportedSession)
        Base.include(m, path)
        for (id, port) in targets
            frame = Base.invokelatest(getfield, m, framebinding(s, id, port))
            @test isequal(comparable(frame), comparable(Loki.result(s, id; port)))
        end
        # Watching never writes, and neither does including a script.
        @test !isfile(csv)

        # The write node is still in the script, as a binding nothing reads.
        text = read(path, String)
        @test occursin("writecsv(", text)
        @test occursin("# scan(analysis, ", text)
    end

    @testset "tables as an argument" begin
        dir = mktempdir()
        s, targets, _ = exportsession(dir)
        text = exportjulia(s)
        @test occursin("# `tables`: supplied by the caller", text)
        @test !occursin("SCRIPTDIR", text)
        @test isempty(filter(f -> endswith(f, ".parquet"), readdir(dir)))

        m = Module(:ExportedWithTables)
        Core.eval(m, :(using CausalFrames, Loki))
        Core.eval(
            m,
            :(
                tables = (prices = $(s.tables["prices"]), dim = $(s.tables["dim"]),
                    frozenlog = $(s.tables["frozenlog"]))
            ),
        )
        Base.include_string(m, text)
        for (id, port) in targets
            frame = Base.invokelatest(getfield, m, framebinding(s, id, port))
            @test isequal(comparable(frame), comparable(Loki.result(s, id; port)))
        end
    end

    @testset "targets" begin
        dir = mktempdir()
        s, _, _ = exportsession(dir)
        # By default the last run's targets.
        text = exportjulia(s)
        @test occursin("frame_n6_insample = load(analysis, p_n6_insample)", text)
        # Or exactly what is asked for, node ids and (id, port) pairs alike.
        one = exportjulia(s; targets = [("n4", :out)])
        @test occursin("frame_n4 = load(analysis, p_n4)", one)
        @test !occursin("frame_n6", one)
        # A context other than the analysis window.
        @test occursin("load(train,", exportjulia(s; context = "train"))
        @test_throws ArgumentError exportjulia(s; context = "nope")
        @test_throws ArgumentError exportjulia(s; tables = :snapshot)
        @test_throws ArgumentError exportjulia(s; tables = :nonsense)
    end

    @testset "what cannot be exported" begin
        s = Loki.Session(; contexts = (analysis = Context(0, 10),))
        lonely = Loki.addnode!(s, "logtransform", Dict("column" => "x"))
        @test_throws Loki.NodeError exportjulia(s)

        s2 = Loki.Session(; contexts = (analysis = Context(0, 10),))
        Loki.addnode!(s2, "emptyframe"; id = "an id")
        @test_throws ArgumentError exportjulia(s2)

        s3 = Loki.Session(; contexts = (analysis = Context(0, 10),))
        Loki.setcontext!(s3, "my window", Context(0, 5))
        Loki.addnode!(s3, "emptyframe")
        @test_throws ArgumentError exportjulia(s3)
    end

    @testset "only what the targets need" begin
        dir = mktempdir()
        prices = DataFrame(time = 1:10, x = collect(1.0:10.0))
        scratch = DataFrame(time = 1:10, y = collect(1.0:10.0))
        s = Loki.Session(; tables = (prices = prices, scratch = scratch),
            contexts = (analysis = Context(0, 11),))
        src = Loki.addnode!(s, "table", Dict("table" => "prices"))
        logc = Loki.addnode!(s, "logtransform", Dict("column" => "x"))
        writer = Loki.addnode!(s, "writecsv", Dict("path" => joinpath(dir, "out.csv")))
        Loki.connect!(s, (src, :out), (logc, :in))
        Loki.connect!(s, (logc, :out), (writer, :in))
        # An unfinished branch the targets do not reach: a table nothing reads, a
        # node with nothing wired into it, and a write fed by neither.
        other = Loki.addnode!(s, "table", Dict("table" => "scratch"))
        lonely = Loki.addnode!(s, "difference", Dict("column" => "y"))
        stray = Loki.addnode!(s, "writecsv", Dict("path" => joinpath(dir, "stray.csv")))

        # Exporting every sink does reach the half-wired node, and says so.
        @test_throws Loki.NodeError exportjulia(s)

        text = exportjulia(s; targets = [(logc, :out)])
        @test occursin("p_$logc = ", text)
        @test !occursin("p_$lonely", text)
        @test !occursin("p_$other", text)
        @test !occursin("p_$stray", text)
        @test !occursin("scratch", text)
        # A write hanging off an exported pipeline keeps its binding and the
        # commented line that runs it, though no target loads it.
        @test occursin("writecsv(", text)
        @test occursin("# scan(analysis, p_$writer)", text)

        # The last run's targets narrow it the same way, with no targets passed.
        wait(Loki.run!(s, [(logc, :out)]))
        @test exportjulia(s) == text

        # A snapshot writes only the tables the script reads.
        exportjulia(joinpath(dir, "script.jl"), s; targets = [(logc, :out)])
        @test Set(readdir(dir)) == Set(["script.jl", "prices.parquet"])
    end
end

@testset "golden script" begin
    # A graph with fixed ids and no temporary paths, so its script is stable
    # enough to diff. Regenerate with LOKI_UPDATE_GOLDEN=1.
    s = Loki.Session(;
        contexts = (analysis = Context(DateTime(2015, 1, 1), DateTime(2026, 1, 1)),
            train = Context(DateTime(2015, 1, 1), DateTime(2020, 6, 30, 12, 30))))
    Loki.setprelude!(s, "const TYPES = Dict(:time => DateTime, :close => Float64)")
    csv = Loki.addnode!(s, "readcsv",
        Dict("path" => "prices.csv", "types" => "TYPES"); id = "csv")
    logc = Loki.addnode!(s, "logtransform", Dict("column" => "close"); id = "log")
    diff = Loki.addnode!(s, "difference", Dict("column" => "close_log"); id = "diff")
    clk = Loki.addnode!(s, "clock", Dict("interval" => "Day(1)"); id = "clk")
    win = Loki.addnode!(s, "summarizewindows",
        Dict("lookback" => "Day(30)",
            "summarizers" => [Dict("summarizer" => "Count"),
                Dict("summarizer" => "Std", "columns" => ["close_log_diff"])]);
        id = "win")
    join = Loki.addnode!(s, "asofjoin", Dict("tolerance" => "Day(7)"); id = "join")
    ahead = Loki.addnode!(s, "lead", Dict("offset" => "Day(1)"); id = "ahead")
    fit = Loki.addnode!(s, "fit",
        Dict("family" => "arma", "column" => "close_log_diff", "order" => [1, 0, 1],
            "fitcontext" => "train"); id = "fit")
    out = Loki.addnode!(s, "writeparquet", Dict("path" => "residuals.parquet"); id = "out")
    Loki.connect!(s, (csv, :out), (logc, :in))
    Loki.connect!(s, (logc, :out), (diff, :in))
    Loki.connect!(s, (diff, :out), (win, :data))
    Loki.connect!(s, (clk, :out), (win, :clock))
    Loki.connect!(s, (diff, :out), (join, :left))
    Loki.connect!(s, (win, :out), (join, :right))
    Loki.connect!(s, (join, :out), (ahead, :in))
    Loki.connect!(s, (join, :out), (fit, :in))
    Loki.connect!(s, (fit, :insample), (out, :in))

    text = exportjulia(s)
    golden = joinpath(@__DIR__, "golden", "session.jl.txt")
    if get(ENV, "LOKI_UPDATE_GOLDEN", "") == "1"
        mkpath(dirname(golden))
        write(golden, text)
    end
    @test text == read(golden, String)
end
