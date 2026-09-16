# Diagnostics over a loaded frame. Every diagnostic is checked to be
# chunk-independent — the same answers from a three-chunk frame as from a
# one-chunk one — which is how "it never reads `frame.chunks`" gets tested, and
# to survive `JSON3.write`, which refuses NaN and Inf.

using Dates: Dates
using JSON3: JSON3
using Random: Xoshiro, randn
import HypothesisTests as HT
import StatsBase
import StatsFuns
using Statistics: Statistics

const DIAGCTX = Context(0, 101)

# `DiagnosticResult` holds `Dict`s, so the default `==` on an immutable struct
# compares them by identity. Compare what they hold instead.
samediagnostic(a::Loki.DiagnosticResult, b::Loki.DiagnosticResult) =
    a.kind === b.kind && isequal(a.data, b.data) && isequal(a.summary, b.summary) &&
    a.warnings == b.warnings && sort(collect(keys(a.panels))) ==
                                sort(collect(keys(b.panels)))

# The same rows as one chunk and as several, so a diagnostic can be run over both.
function diagframes(df::DataFrame; breaks = (17, 40, 88))
    whole = CausalFrame(DIAGCTX, df)
    edges = [1, breaks..., nrow(df) + 1]
    chunks = [df[edges[i]:(edges[i+1]-1), :] for i in 1:(length(edges)-1)]
    return whole, CausalFrame(DIAGCTX, chunks)
end

function diagdata()
    rng = Xoshiro(13)
    x = cumsum(randn(rng, 100))
    df = DataFrame(time = 1:100, x = x, k = repeat(["a", "b"], 50),
        label = string.(1:100))
    allowmissing!(df, :x)
    df.x[7] = missing
    df.x[63] = missing
    return df
end

@testset "diagnostics" begin
    df = diagdata()
    whole, chunked = diagframes(df)

    @testset "extraction" begin
        cols = Loki.columnvectors(whole, :time, :x)
        @test cols.time == df.time
        @test isequal(cols.x, df.x)
        # The same, read one backing chunk at a time.
        @test isequal(Loki.columnvectors(chunked, :time, :x), cols)

        a = Loki.columnvectors(whole, :time; key = :k => "a")
        @test a.time == df.time[df.k.=="a"]
        # A key arriving from a query string is a string whatever the column holds.
        @test Loki.columnvectors(whole, :time; key = :time => "5").time == [5]
        @test_throws ArgumentError Loki.columnvectors(whole, :nope)
        @test_throws ArgumentError Loki.columnvectors(whole, :time; key = :nope => 1)

        v = Loki.numericvalues(whole, :x)
        @test v.dropped == 2
        @test length(v.values) == 98 == length(v.times)
        @test all(isfinite, v.values)
        @test isequal(Loki.numericvalues(chunked, :x), v)
        # A non-numeric column is named, not silently empty.
        @test_throws ArgumentError Loki.numericvalues(whole, :label)

        @test Loki.keyvalues(whole, :k) == [(k = "a",), (k = "b",)]
        @test Loki.keyvalues(chunked, [:k]) == Loki.keyvalues(whole, :k)
        @test length(Loki.keyvalues(whole, :time; limit = 4)) == 4
    end

    @testset "spacing" begin
        @test Loki.spacing(1:10).regular
        @test Loki.spacing([1, 2, 5, 6]).regular == false
        @test Loki.spacing([1, 2]).regular          # too short to judge
        @test Loki.spacing(collect(1:10) .* 1.0).delta == 1.0
        stamps = Dates.DateTime(2020) .+ Dates.Minute(5) .* (0:9)
        @test Loki.spacing(stamps).delta == Dates.Minute(5)
        @test Loki.spelldelta(Dates.Millisecond(300_000)) == "Minute(5)"
        @test Loki.spelldelta(2.5) == "2.5"
    end

    @testset "lttb" begin
        x = collect(1.0:1000.0)
        y = sin.(x ./ 20)
        idx = Loki.lttb(x, y, 50)
        @test length(idx) == 50
        @test first(idx) == 1 && last(idx) == 1000
        @test issorted(idx) && allunique(idx)
        # A series already short enough comes back whole, in order.
        @test Loki.lttb(x[1:10], y[1:10], 50) == 1:10
        @test Loki.lttb(x, y, 2) == 1:1000
        # The extremes of a spiky series survive downsampling, which is the point.
        spiky = zeros(1000)
        spiky[404] = 100.0
        spiky[777] = -100.0
        kept = Loki.lttb(x, spiky, 40)
        @test 404 in kept && 777 in kept
        @test_throws ArgumentError Loki.lttb(x, y[1:10], 5)
    end

    @testset "seriesplot" begin
        r = Loki.seriesplot(whole, :x)
        @test r.kind === :seriesplot
        trace = only(r.data["series"])
        @test trace["downsampled"] == false
        # Short enough to send whole, so `missing` stays a gap rather than a point.
        @test length(trace["values"]) == 100
        @test trace["values"][7] === nothing
        @test r.summary["series"]["x"]["n"] == 98
        @test r.summary["series"]["x"]["missing"] == 2
        @test r.summary["rows"] == 100
        @test r.summary["context"] == Any[0, 101]
        @test samediagnostic(Loki.seriesplot(chunked, :x), r)

        two = Loki.seriesplot(whole, :x, "time")
        @test length(two.data["series"]) == 2
        @test two.summary["column"] === nothing

        keyed = Loki.seriesplot(whole, :x; key = :k => "b")
        @test length(only(keyed.data["series"])["values"]) == 50
        @test keyed.summary["key"] == Dict("k" => "b")

        # A non-numeric column loses its line, not the panel.
        note = only(Loki.seriesplot(whole, :label).data["series"])
        @test isempty(note["values"])
        @test occursin("not numeric", note["note"])

        @test_throws ArgumentError Loki.seriesplot(whole)
    end

    @testset "seriesplot downsamples" begin
        long = DataFrame(time = 1:10_000, y = sin.((1:10_000) ./ 50))
        frame = CausalFrame(Context(0, 10_001), long)
        r = Loki.seriesplot(frame, :y; maxpoints = 500)
        trace = only(r.data["series"])
        @test trace["downsampled"] == true
        @test length(trace["values"]) == 500 == length(trace["time"])
        # Downsampling is a view of the data, not a recomputation of it.
        @test r.summary["series"]["y"]["n"] == 10_000
        @test trace["time"][1] == 1 && trace["time"][end] == 10_000
    end

    @testset "preview" begin
        r = Loki.preview(whole; limit = 4)
        @test r.data["columns"] == ["time", "x", "k", "label"]
        @test r.data["types"][2] == "Union{Missing, Float64}"
        @test length(r.data["rows"]) == 4
        @test r.data["total"] == 100
        @test r.data["rows"][1][1] === 1          # an integer time stays an integer
        @test samediagnostic(Loki.preview(chunked; limit = 4), r)

        page = Loki.preview(whole; offset = 98, limit = 10)
        @test length(page.data["rows"]) == 2
        @test page.summary["returned"] == 2

        gap = Loki.preview(whole; offset = 6, limit = 1, columns = [:x])
        @test gap.data["rows"] == [[nothing]]

        keyed = Loki.preview(whole; key = :k => "b", limit = 1000)
        @test keyed.data["total"] == 50

        @test_throws ArgumentError Loki.preview(whole; offset = -1)
        @test_throws ArgumentError Loki.preview(whole; columns = [:nope])
    end

    # A frame of fitted models previews as text rather than failing to serialize.
    @testset "preview of an opaque column" begin
        models = load(Context(0, 41),
            readtable((time = collect(1:40), y = sin.(1:40))) |>
            fitarma(:y; order = (1, 0, 0)))
        r = Loki.preview(models)
        @test "model" in r.data["columns"]
        cell = r.data["rows"][1][findfirst(==("model"), r.data["columns"])]
        @test cell isa String && occursin("FittedARMA", cell)
        @test JSON3.read(JSON3.write(r)).data.total == 1
    end

    # `JSON3.write` refuses NaN and Inf, and a constant or empty series makes
    # both, so every diagnostic sanitizes at construction.
    @testset "JSON survives degenerate input" begin
        flat = CausalFrame(DIAGCTX, DataFrame(time = 1:10, x = fill(2.0, 10)))
        allmissing = CausalFrame(DIAGCTX,
            DataFrame(time = 1:5, x = Vector{Union{Missing,Float64}}(missing, 5)))
        for frame in (flat, allmissing),
            r in (Loki.seriesplot(frame, :x), Loki.preview(frame))

            text = JSON3.write(r)
            @test !occursin("NaN", text) && !occursin("Inf", text)
            @test JSON3.read(text).kind == String(r.kind)
        end
        @test Loki.seriesplot(allmissing, :x).summary["series"]["x"]["mean"] === nothing

        # An empty frame reports only `:time` and the context's time type — it has
        # never seen a chunk, so it knows no other column.
        empt = CausalFrame(DIAGCTX, DataFrame(time = Int[], x = Float64[]))
        e = Loki.preview(empt)
        @test e.data["columns"] == ["time"]
        @test e.data["total"] == 0
        @test JSON3.read(JSON3.write(e)).data.total == 0
        @test_throws ArgumentError Loki.seriesplot(empt, :x)
    end
end

@testset "correlation and distribution diagnostics" begin
    rng = Xoshiro(29)
    # An AR(1), so the ACF decays and the PACF cuts off after lag 1.
    y = zeros(400)
    for t in 2:400
        y[t] = 0.7 * y[t-1] + randn(rng)
    end
    df = DataFrame(time = 1:400, y = y, k = repeat(["a", "b"], 200))
    ctx = Context(0, 401)
    whole = CausalFrame(ctx, df)
    chunked = CausalFrame(ctx, [df[1:130, :], df[131:290, :], df[291:400, :]])

    @testset "acf and pacf" begin
        a = acf(whole, :y; lags = 20)
        @test a.kind === :acf
        @test a.data["lags"] == collect(0:20)
        # The values are StatsBase's; what Loki adds is the band and the reading.
        @test a.data["values"] ≈ StatsBase.autocor(y, 0:20)
        @test a.data["band"] ≈ 1.959963984540054 / sqrt(400) rtol = 1e-9
        @test a.data["values"][1] == 1.0
        @test 1 in a.summary["significant"] && 0 ∉ a.summary["significant"]
        @test a.summary["clamped"] == false
        @test isempty(a.warnings)
        @test samediagnostic(acf(chunked, :y; lags = 20), a)

        p = pacf(whole, :y; lags = 20)
        @test p.data["lags"] == collect(1:20)
        @test p.data["values"] ≈ StatsBase.pacf(y, 1:20)
        # AR(1): lag 1 spikes and dominates. A 5% band lets roughly one of the
        # remaining 19 lags cross by chance, so "only lag 1" would be a flaky test.
        @test 1 in p.summary["significant"]
        @test argmax(abs.(p.data["values"])) == 1
        @test all(v -> abs(v) < 0.5 * abs(p.data["values"][1]), p.data["values"][2:end])
        @test samediagnostic(pacf(chunked, :y; lags = 20), p)

        # A wider band admits fewer lags.
        @test length(acf(whole, :y; lags = 20, level = 0.999).summary["significant"]) <=
              length(a.summary["significant"])
        @test_throws ArgumentError acf(whole, :y; level = 1.0)
        @test_throws ArgumentError acf(whole, :y; lags = 0)
    end

    @testset "acf and pacf clamp rather than raise" begin
        short = CausalFrame(Context(0, 11), DataFrame(time = 1:10, y = y[1:10]))
        a = acf(short, :y; lags = 40)
        @test a.summary["lags"] == 9 && a.summary["clamped"]
        @test occursin("supports 9", only(a.warnings))
        # PACF supports half as many lags as ACF: StatsBase needs 2·maxlag < n.
        p = pacf(short, :y; lags = 40)
        @test p.summary["lags"] == 4
        @test length(p.data["values"]) == 4

        # A constant window has no correlogram at all, which is data, not a bug.
        flat = CausalFrame(Context(0, 31), DataFrame(time = 1:30, y = fill(2.0, 30)))
        c = acf(flat, :y; lags = 5)
        @test all(v -> v === nothing, c.data["values"][2:end])
        @test isempty(c.summary["significant"])
        @test !occursin("NaN", JSON3.write(c))
    end

    @testset "irregular spacing warns with the fix" begin
        gappy = DataFrame(time = [1, 2, 3, 4, 9, 10, 11, 12], y = y[1:8])
        frame = CausalFrame(Context(0, 13), gappy)
        for r in (acf(frame, :y; lags = 3), pacf(frame, :y; lags = 2),
            ljungbox(frame, :y; lags = 3, dof = 0))
            @test any(w -> occursin("not evenly spaced", w), r.warnings)
            @test r.summary["suggestion"] == "intervalize(clock(1), Last(:y))"
        end
        @test isempty(filter(w -> occursin("evenly spaced", w),
            acf(whole, :y; lags = 3).warnings))
    end

    @testset "adftest" begin
        r = adftest(whole, :y)
        reference = HT.ADFTest(y, :constant, r.summary["lag"])
        @test r.summary["statistic"] ≈ reference.stat
        @test r.summary["pvalue"] ≈ HT.pvalue(reference)
        @test r.summary["stationary"] == (HT.pvalue(reference) < 0.05)
        @test sort(collect(keys(r.summary["criticalvalues"]))) == ["1%", "10%", "5%"]
        @test r.summary["lag"] == floor(Int, 12 * (400 / 100)^0.25)
        @test samediagnostic(adftest(chunked, :y), r)

        # A random walk is the textbook unit root; its difference is not.
        walk = CausalFrame(ctx, DataFrame(time = 1:400, y = cumsum(y)))
        @test adftest(walk, :y).summary["stationary"] == false
        @test adftest(whole, :y).summary["stationary"] == true

        tiny = CausalFrame(Context(0, 6), DataFrame(time = 1:5, y = y[1:5]))
        t = adftest(tiny, :y)
        @test t.summary["pvalue"] === nothing
        @test occursin("too few rows", only(t.warnings))
    end

    @testset "ljungbox" begin
        r = ljungbox(whole, :y; lags = [10, 20], dof = 1)
        @test length(r.data["tests"]) == 2
        reference = HT.LjungBoxTest(y, 10, 1)
        @test r.data["tests"][1]["statistic"] ≈ reference.Q
        @test r.data["tests"][1]["pvalue"] ≈ HT.pvalue(reference)
        @test r.summary["dofsource"] == "given"
        @test r.summary["whitenoise"] == false      # it is an AR(1), not noise
        @test collect(keys(r.summary["pvalues"])) ⊆ ["10", "20"]
        @test samediagnostic(ljungbox(chunked, :y; lags = [10, 20], dof = 1), r)

        noise = CausalFrame(ctx, DataFrame(time = 1:400, y = randn(Xoshiro(5), 400)))
        @test ljungbox(noise, :y; lags = 20).summary["whitenoise"] == true

        # Neither `dof >= lag` nor a lag past the window raises; both are dropped.
        dropped = ljungbox(whole, :y; lags = [3, 10], dof = 5)
        @test [t["lags"] for t in dropped.data["tests"]] == [10]
        @test any(w -> occursin("degrees of freedom", w), dropped.warnings)
        short = CausalFrame(Context(0, 9), DataFrame(time = 1:8, y = y[1:8]))
        @test isempty(ljungbox(short, :y; lags = 20, dof = 0).data["tests"])
        @test ljungbox(short, :y; lags = 20, dof = 0).summary["whitenoise"] === nothing
    end

    @testset "dof comes from the model when the frame has one" begin
        models = load(Context(0, 121),
            readtable((time = collect(1:120), y = y[1:120])) |>
            fitarma(:y; order = (2, 0, 1)))
        @test Loki.armadof(models) == 3
        @test Loki.armadof(models; column = :model) == 3
        @test Loki.armadof(whole) === nothing
        # `applyarma` drops the model column, so an in-sample stream has none —
        # which is why the server supplies `dof` from the fit node's parameters.
        insample = load(Context(0, 121),
            readtable((time = collect(1:120), y = y[1:120])) |>
            Loki.Acausal.insample(FitARMA(:y; order = (2, 0, 1))))
        @test Loki.armadof(insample) === nothing
        @test ljungbox(insample, :y_residual; lags = 20).summary["dofsource"] == "none"
        @test ljungbox(insample, :y_residual; lags = 20, dof = 3).summary["dof"] == 3
    end

    @testset "histogram" begin
        r = Loki.histogram(whole, :y)
        @test sum(r.data["counts"]) == 400
        @test length(r.data["edges"]) == length(r.data["counts"]) + 1
        @test r.summary["skewness"] ≈ StatsBase.skewness(y)
        @test r.summary["kurtosis"] ≈ StatsBase.kurtosis(y)
        @test r.summary["median"] ≈ Statistics.median(y)
        @test r.data["normal"]["std"] ≈ r.summary["std"]
        @test samediagnostic(Loki.histogram(chunked, :y), r)
        @test length(Loki.histogram(whole, :y; bins = 7).data["counts"]) == 7

        # A constant column has no width to bin and no normal to fit.
        flat = CausalFrame(Context(0, 31), DataFrame(time = 1:30, y = fill(2.0, 30)))
        f = Loki.histogram(flat, :y)
        @test sum(f.data["counts"]) == 30
        @test f.data["normal"] === nothing
    end

    @testset "qqplot" begin
        r = Loki.qqplot(whole, :y)
        @test length(r.data["sample"]) == 400
        @test issorted(r.data["sample"])
        @test r.data["theoretical"][1] ≈ StatsFuns.norminvcdf(0.5 / 400)
        @test r.data["line"]["slope"] ≈ r.summary["std"]
        @test samediagnostic(Loki.qqplot(chunked, :y), r)
        # Normal data lies on the line; a heavily skewed sample does not.
        normal = CausalFrame(ctx, DataFrame(time = 1:400, y = randn(Xoshiro(7), 400)))
        skewed = CausalFrame(ctx, DataFrame(time = 1:400, y = exp.(randn(Xoshiro(7), 400))))
        @test Loki.qqplot(normal, :y).summary["correlation"] > 0.99
        @test Loki.qqplot(skewed, :y).summary["correlation"] <
              Loki.qqplot(normal, :y).summary["correlation"]

        thin = Loki.qqplot(whole, :y; maxpoints = 50)
        @test length(thin.data["sample"]) == 50
        @test thin.summary["n"] == 400

        one = CausalFrame(Context(0, 2), DataFrame(time = [1], y = [1.0]))
        @test Loki.qqplot(one, :y).data["line"] === nothing
    end
end
