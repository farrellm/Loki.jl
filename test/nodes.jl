using Dates

# Functions evaluated from source text are newer than this file's top-level
# expressions, so anything that calls them runs in the latest world — as the
# engine's runs do.
latest(ctx, p) = DataFrame(Base.invokelatest(load, ctx, p))

@testset "user code" begin
    uc = Loki.UserCode(; prelude = "double(x) = 2x\nconst OFFSET = 10")
    f = Loki.evalcode(uc, "r -> double(r.x) + OFFSET")
    @test Base.invokelatest(f, (; x = 1)) == 12
    @test Loki.evalcode(uc, "r -> double(r.x) + OFFSET") === f
    @test Loki.evalcode(uc, 2.5) == 2.5
    @test Loki.evalcode(uc, "Minute(5)") == Minute(5)
    @test Loki.evalcode(uc, "mean([1, 2, 3])") == 2.0
    @test Loki.evalcode(uc, "Count()") isa Summarizer
    @test Loki.evalcode(uc, "EMA(:x; span = 3)") isa EMA
    @test_throws ArgumentError Loki.evalcode(uc, "r -> (r.x")
    @test_throws ArgumentError Loki.evalcode(uc, "1 2")
    @test_throws ArgumentError Loki.evalcode(uc, "  ")

    Loki.setprelude!(uc, "triple(x) = 3x")
    @test_throws UndefVarError Loki.evalcode(uc, "double(1)")
    @test Loki.evalcode(uc, "triple(2)") == 6
    @test_throws Exception Loki.setprelude!(uc, "error(\"bad prelude\")")
    @test uc.prelude == "triple(x) = 3x"
    @test Loki.evalcode(uc, "triple(3)") == 9

    env = Loki.BuildEnv(; contexts = (analysis = Context(0, 10),), tables = Dict("t" => 1))
    @test Loki.namedcontext(env, "analysis") == Context(0, 10)
    @test Loki.namedtable(env, "t") == 1
    @test_throws ArgumentError Loki.namedcontext(env, "train")
    @test_throws ArgumentError Loki.namedtable(env, "nope")
end

@testset "node catalog" begin
    kinds = ["emptyframe", "clock", "concatenate", "merge", "table", "readcsv",
        "writecsv", "readparquet", "writeparquet", "readjls", "writejls", "filterrows",
        "addcolumns", "selectcolumns", "dropcolumns", "reordercolumns", "lag", "head",
        "settime", "lastrow", "sortcycles", "forwardfill", "fillmissing", "summarize",
        "summarizecycles", "addsummarycolumns", "addrollingcolumns", "asofjoin",
        "lookupjoin",
        "intervalize", "summarizewindows", "applymodels", "addpredictions",
        "modelreports", "lead", "futurejoin", "acausal_settime", "lags", "difference",
        "logtransform", "boxcox", "ema", "macd", "ar", "fitarma", "applyarma", "arma",
        "fitonce", "fit"]
    for name in kinds
        kind = Loki.nodekind(name)
        @test Loki.paramschema(kind)["type"] == "object"
        @test !isempty(kind.category)
        @test Loki.iswrite(kind) == startswith(name, "write")
        @test any(p -> Loki.isacausal(kind, Dict{String,Any}(), p), Loki.outputs(kind)) ==
              (kind.category == "acausal" || name == "fit")
    end

    df = DataFrame(time = 1:10, k = repeat([1, 2], 5), x = Float64.(1:10),
        z = 2.0 .* (1:10) .+ 1, y = [missing; 2.0:10.0])
    y = simulate(Xoshiro(2), 120)
    ts = DataFrame(time = 1:120, y = y)
    env = Loki.BuildEnv(;
        contexts = Dict("analysis" => Context(0, 100), "train" => Context(0, 61)),
        tables = Dict("df" => df, "ts" => ts, "a" => df[1:5, :], "b" => df[6:10, :],
            "quotes" => DataFrame(time = [0, 5], q = [1.0, 2.0]),
            "dim" => DataFrame(k = [1, 3], label = ["one", "three"]),
            "cycles" =>
                DataFrame(time = [1, 1, 1, 2, 2], s = ["b", "c", "a", "z", "y"],
                    v = [2, 3, 1, 5, 4])))
    b(kind, params = Dict{String,Any}(); inputs...) =
        Loki.build(Loki.nodekind(kind), params, Dict{Symbol,Any}(inputs), env)
    ctx = Context(0, 100)
    tctx = Context(0, 121)

    @testset "sources" begin
        src = b("table", Dict("table" => "df")).out
        @test isequal(latest(ctx, src), df)
        @test_throws ArgumentError b("table", Dict("table" => "nope"))
        env.tables["frame"] = load(ctx, src)
        @test isequal(latest(ctx, b("table", Dict("table" => "frame")).out), df)
        @test_throws ArgumentError b("table", Dict("table" => "frame", "time" => "x"))
        @test nrow(latest(ctx, b("emptyframe").out)) == 0
        @test latest(Context(0, 20), b("clock", Dict("interval" => "5")).out).time ==
              [0, 5, 10, 15]
        pa, pb = b("table", Dict("table" => "a")).out, b("table", Dict("table" => "b")).out
        @test isequal(latest(ctx, b("concatenate"; in = [pa, pb]).out), df)
        @test isequal(latest(ctx, b("merge"; in = [pb, pa]).out), df)
        @test_throws ArgumentError b("merge"; in = CausalPipeline[])
    end

    src = b("table", Dict("table" => "df")).out

    @testset "rows and columns" begin
        cyc = b("table", Dict("table" => "cycles")).out
        bycolumn = latest(ctx, b("sortcycles", Dict("columns" => "s"); in = cyc).out)
        @test bycolumn.time == [1, 1, 1, 2, 2]
        @test bycolumn.s == ["a", "b", "c", "y", "z"]
        @test latest(ctx,
            b("sortcycles", Dict("function" => "r -> -r.v"); in = cyc).out).v ==
              [3, 2, 1, 5, 4]
        @test latest(ctx,
            b("sortcycles", Dict("columns" => ["s"], "rev" => true); in = cyc).out).s ==
              ["c", "b", "a", "z", "y"]
        @test_throws ArgumentError b("sortcycles"; in = cyc)
        @test_throws ArgumentError b("sortcycles",
            Dict("columns" => "s", "function" => "r -> r.v"); in = cyc)

        @test latest(
            ctx,
            b("filterrows", Dict("predicate" => "r -> r.x > 5"); in = src).out,
        ).x ==
              6.0:10.0
        @test_throws ArgumentError b(
            "filterrows",
            Dict("predicate" => "r -> (r.x");
            in = src,
        )
        @test_throws ArgumentError b("filterrows"; in = src)
        @test latest(ctx,
            b("addcolumns", Dict("function" => "r -> (; w = 2r.x)"); in = src).out).w ==
              2 .* df.x
        @test names(
            latest(ctx, b("selectcolumns", Dict("columns" => "x"); in = src).out),
        ) ==
              ["time", "x"]
        @test names(
            latest(ctx,
                b("dropcolumns", Dict("match" => "r\"^[kx]\$\""); in = src).out),
        ) ==
              ["time", "z", "y"]
        @test Set(
            names(
                latest(ctx,
                    b("reordercolumns", Dict("columns" => ["y", "x"]); in = src).out),
            ),
        ) ==
              Set(names(df))
        @test_throws ArgumentError b("selectcolumns"; in = src)
        @test latest(ctx, b("lag", Dict("offset" => "2"); in = src).out).time == 3:12
        @test nrow(latest(ctx, b("head", Dict("n" => 3); in = src).out)) == 3
        @test latest(ctx, b("settime", Dict("spec" => "r -> r.time + 1"); in = src).out).time ==
              2:11
        @test latest(ctx, b("lastrow", Dict("key" => "k"); in = src).out).k == [1, 2]
        filled = latest(ctx, b("forwardfill", Dict("columns" => "y"); in = src).out)
        @test ismissing(filled.y[1]) && filled.y[2] == 2.0
        @test latest(ctx, b("fillmissing", Dict("values"=>"(; y = 0.0)"); in = src).out).y[1] ==
              0.0
    end

    @testset "summarizing" begin
        ss = [
            Dict("summarizer" => "Count"),
            Dict("summarizer" => "Mean", "columns" => ["x"]),
            Dict("summarizer" => "LinearRegression", "columns" => ["x"],
                "options" => Dict("response" => "z", "name" => "reg")),
            Dict("summarizer" => "EMA", "columns" => ["x"], "options" => Dict("span" => 3)),
            Dict(
                "summarizer" => "SumPower",
                "columns" => ["x"],
                "options" => Dict("n" => 2),
            ),
        ]
        sm = latest(ctx, b("summarize", Dict("summarizers" => ss); in = src).out)
        @test sm.count == [10]
        @test sm.x_mean ≈ [5.5]
        @test sm.reg_x_beta ≈ [2.0]
        @test "x_ema_3" in names(sm)
        @test sm.x_sumpower_2 ≈ [sum(abs2, df.x)]
        keyed = latest(
            ctx,
            b("summarize", Dict("summarizers" => ss[1:2], "key" => "k");
                in = src).out,
        )
        @test keyed.k == [1, 2]
        bad(entries) = b("summarize", Dict("summarizers" => entries); in = src)
        @test_throws ArgumentError bad([Dict("summarizer" => "Nope")])
        @test_throws ArgumentError bad([Dict("summarizer" => "Sum")])
        @test_throws ArgumentError bad([
            Dict("summarizer" => "Sum", "columns" => ["x"],
                "options" => Dict("bogus" => 1)),
        ])
        @test_throws ArgumentError bad([
            Dict("summarizer" => "SumPower", "columns" => ["x"]),
        ])
        @test_throws ArgumentError bad([Dict("summarizer" => "Count", "extra" => 1)])
        @test_throws ArgumentError bad(Dict{String,Any}[])

        sum1 = [Dict("summarizer" => "Sum", "columns" => ["x"])]
        @test all(
            ==(1),
            latest(ctx,
                b("summarizecycles", Dict("summarizers" => [Dict("summarizer" => "Count")]);
                    in = src).out).count,
        )
        @test latest(
            ctx,
            b("addsummarycolumns", Dict("summarizers" => sum1); in = src).out,
        ).x_sum ==
              cumsum(df.x)
        rolled = latest(
            ctx,
            b("addrollingcolumns",
                Dict("windows" => "(w = 2,)", "summarizers" => sum1); data = src).out,
        )
        @test rolled.w_x_sum[5] == 12.0
        from = latest(
            ctx,
            b("addrollingcolumns",
                Dict("windows" => "(w = 2,)", "summarizers" => sum1); data = src,
                from = src).out,
        )
        @test from.w_x_sum == rolled.w_x_sum
        clk = b("clock", Dict("interval" => "5")).out
        count1 = [Dict("summarizer" => "Count")]
        @test latest(
            Context(0, 12),
            b("intervalize", Dict("summarizers" => count1);
                data = src, clock = clk).out,
        ).count == [4, 5]
        @test latest(
            Context(0, 12),
            b("summarizewindows",
                Dict("summarizers" => count1, "lookback" => "5"); data = src, clock = clk).out,
        ).count ==
              [0, 4, 5]

        # a declared keyset: every close emits every key, 3 never occurring
        dense = Dict("summarizers" => count1, "key" => "k", "keyset" => "[1, 2, 3]")
        cycles = latest(ctx, b("summarizecycles", dense; in = src).out)
        @test cycles.k == repeat([1, 2, 3], 10)
        @test cycles.count == reduce(vcat, [isodd(t) ? [1, 0, 0] : [0, 1, 0] for t in 1:10])
        intervals = latest(Context(0, 12),
            b("intervalize", dense; data = src, clock = clk).out)
        @test intervals.k == repeat([1, 2, 3], 2)
        @test intervals.count == [2, 2, 0, 3, 2, 0]
        @test latest(Context(0, 12),
            b("summarizewindows", merge(dense, Dict("lookback" => "5"));
                data = src, clock = clk).out).count == [0, 0, 0, 2, 2, 0, 3, 2, 0]
    end

    @testset "joins, files, models, acausal" begin
        quotes = b("table", Dict("table" => "quotes")).out
        @test latest(ctx, b("asofjoin"; left = src, right = quotes).out).q ==
              [1, 1, 1, 1, 2, 2, 2, 2, 2, 2]
        looked =
            latest(ctx, b("lookupjoin", Dict("table" => "dim", "key" => "k"); in = src).out)
        @test isequal(looked.label, [isodd(t) ? "one" : missing for t in 1:10])
        dropped = latest(ctx,
            b("lookupjoin", Dict("table" => "dim", "key" => "k", "unmatched" => "drop");
                in = src).out)
        @test dropped.time == 1:2:9
        @test dropped.label == fill("one", 5)
        # a lookup table is timeless
        @test_throws ArgumentError b("lookupjoin", Dict("table" => "quotes", "key" => "q");
            in = src)
        future = latest(ctx, b("futurejoin"; left = src, right = quotes).out)
        @test future.q[1:5] == fill(2.0, 5)
        @test all(ismissing, future.q[6:10])
        @test latest(ctx, b("lead", Dict("offset" => "1"); in = src).out).time == 0:9
        @test latest(ctx,
            b("acausal_settime", Dict("spec" => "r -> r.time - 1"); in = src).out).time ==
              0:9

        dir = mktempdir()
        csv = joinpath(dir, "x.csv")
        scan(ctx, b("writecsv", Dict("path" => csv); in = src).out)
        @test latest(
            ctx,
            b(
                "readcsv",
                Dict("path" => csv,
                    "types" => "Dict(:time => Int, :x => Float64)"),
            ).out,
        ).x == df.x
        pq = joinpath(dir, "x.parquet")
        scan(ctx, b("writeparquet", Dict("path" => pq); in = src).out)
        @test latest(ctx, b("readparquet", Dict("path" => pq)).out).x == df.x
        # files not stored in time order, read with sort
        unsortedcsv = joinpath(dir, "unsorted.csv")
        write(unsortedcsv, "time,x\n3,3.0\n1,1.0\n2,2.0\n")
        @test latest(ctx,
            b("readcsv",
                Dict("path" => unsortedcsv, "sort" => true,
                    "types" => "Dict(:time => Int, :x => Float64)")).out).x == [1.0, 2.0, 3.0]
        unsortedpq = joinpath(dir, "unsorted.parquet")
        db = Loki.DuckDB.DB()
        Loki.DuckDB.DBInterface.execute(db,
            "COPY (SELECT * FROM (VALUES (3, 3.0::DOUBLE), (1, 1.0::DOUBLE), \
            (2, 2.0::DOUBLE)) t(time, x)) TO '$unsortedpq' (FORMAT PARQUET)")
        close(db)
        for backend in ("duckdb", "parquet2")
            @test latest(ctx,
                b("readparquet",
                    Dict("path" => unsortedpq, "sort" => true, "backend" => backend)).out).x ==
                  [1.0, 2.0, 3.0]
        end
        jls = joinpath(dir, "x.jls")
        scan(ctx, b("writejls", Dict("path" => jls); in = src).out)
        @test isequal(latest(ctx, b("readjls", Dict("path" => jls)).out), df)
        # closed keeps the row at stop, which the half-open default drops
        stoptimes(kind, params) = latest(Context(0, 10), b(kind, params).out).time
        for closed in (false, true)
            want = closed ? (1:10) : (1:9)
            @test stoptimes("readcsv",
                Dict("path" => csv, "closed" => closed,
                    "types" => "Dict(:time => Int, :x => Float64)")) == want
            for backend in ("duckdb", "parquet2")
                @test stoptimes("readparquet",
                    Dict("path" => pq, "closed" => closed, "backend" => backend)) == want
            end
            @test stoptimes("readjls", Dict("path" => jls, "closed" => closed)) == want
        end

        clk = b("clock", Dict("interval" => "5")).out
        @test_throws ArgumentError b("addpredictions",
            Dict("lookback" => "5",
                "model" => "1", "predictors" => ["x"], "response" => "z"); data = src,
            clock = clk)
        @test b("applymodels"; data = src, models = src).out isa CausalPipeline
        @test b("modelreports"; in = src).out isa CausalPipeline
    end

    @testset "time series" begin
        tsrc = b("table", Dict("table" => "ts")).out
        @test latest(tctx, b("lags", Dict("column"=>"y", "p"=>2); in = tsrc).out).y_lag_2[3] ==
              y[1]
        @test_throws ArgumentError b("difference", Dict("column" => "y", "order" => 0);
            in = tsrc)
        @test latest(tctx, b("difference", Dict("column"=>"y"); in = tsrc).out).y_diff[2] ≈
              y[2] - y[1]
        @test latest(ctx, b("logtransform", Dict("column" => "x"); in = src).out).x_log ≈
              log.(df.x)
        @test latest(ctx, b("boxcox", Dict("column" => "x", "lambda" => 1); in = src).out).x_boxcox ≈
              df.x .- 1
        @test isequal(
            latest(
                ctx,
                b("ema", Dict("column" => "x", "span" => 3, "key" => "k"); in = src).out,
            ),
            latest(ctx, src |> ema(:x; span = 3, key = :k)))
        @test isequal(
            latest(ctx, b("ema", Dict("column" => "x", "halflife" => "2"); in = src).out),
            latest(ctx, src |> ema(:x; halflife = 2)))
        @test "macd_hist" in
              names(latest(ctx, b("macd", Dict("column" => "x"); in = src).out))
        @test latest(tctx, b("ar", Dict("column" => "y", "p" => 1); in = tsrc).out).ar_y_lag_1_beta ≈
              latest(tctx, tsrc |> ar(:y, 1)).ar_y_lag_1_beta

        fm = only(
            latest(tctx,
                b("fitarma", Dict("column" => "y", "order" => [1, 0, 0]); in = tsrc).out,
            ).model,
        )
        @test fm isa FittedARMA && fm.order == (1, 0, 0)
        once = b("fitonce",
            Dict(
                "context" => "train",
                "summarizer" => [
                    Dict("summarizer" => "FitARMA", "columns" => ["y"],
                        "options" => Dict("order" => [1, 0, 0]))],
            ); in = tsrc).out
        @test latest(tctx, once).time == [61]
        @test_throws ArgumentError b("fitonce",
            Dict("context" => "train",
                "summarizer" =>
                    [Dict("summarizer" => "Count"), Dict("summarizer" => "Count")]);
            in = tsrc)
        reference =
            tsrc |> applyarma(tsrc |> fitonce(Context(0, 61),
                FitARMA(:y; order = (1, 0, 0))), :y)
        @test isequal(
            latest(
                tctx,
                b("applyarma", Dict("column" => "y"); data = tsrc,
                    models = once).out,
            ), latest(tctx, reference))
        @test isequal(
            latest(
                tctx,
                b("arma", Dict("column" => "y", "lookback" => "60",
                    "order" => [1, 0, 0]); data = tsrc,
                    clock = b("clock", Dict("interval" => "30")).out).out,
            ),
            latest(tctx, tsrc |> arma(clock(30), 60, :y; order = (1, 0, 0))))
    end

    @testset "fit node" begin
        tsrc = b("table", Dict("table" => "ts")).out
        ports = b("fit", Dict("family" => "arma", "column" => "y", "order" => [1, 0, 1]);
            in = tsrc)
        @test keys(ports) == (:model, :insample)
        @test only(latest(tctx, ports.model).model).order == (1, 0, 1)
        @test isequal(latest(tctx, ports.insample),
            latest(tctx, tsrc |> Loki.Acausal.insample(FitARMA(:y; order = (1, 0, 1)))))

        arports = b("fit", Dict("family" => "ar", "column" => "y", "p" => 1); in = tsrc)
        @test names(latest(tctx, arports.insample)) ==
              ["time", "y", "y_fitted", "y_residual"]
        @test latest(tctx, arports.model).ar_y_lag_1_beta ≈
              latest(tctx, tsrc |> ar(:y, 1)).ar_y_lag_1_beta

        trained = b("fit",
            Dict("family" => "arma", "column" => "y", "order" => [1, 0, 0],
                "fitcontext" => "train"); in = tsrc)
        @test latest(tctx, trained.model).time == [61]

        @test_throws ArgumentError b("fit", Dict("family" => "arma", "column" => "y");
            in = tsrc)
        @test_throws ArgumentError b(
            "fit",
            Dict("family" => "ar", "column" => "y");
            in = tsrc,
        )
        @test_throws ArgumentError b("fit", Dict("family" => "mlj", "column" => "y");
            in = tsrc)
        @test_throws ArgumentError b("fit",
            Dict("family" => "mlj", "column" => "y",
                "predictors" => ["x"], "model" => "1"); in = tsrc)
        @test_throws ArgumentError b("fit",
            Dict("family" => "arma", "column" => "y",
                "order" => [1, 0, 0], "fitcontext" => "nope"); in = tsrc)
        @test_throws ArgumentError b("fit", Dict("family" => "garch", "column" => "y");
            in = tsrc)
    end
end
