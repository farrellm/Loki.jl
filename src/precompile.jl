# Precompile what CausalFrames' own workload cannot: its parquet operators live
# in extensions behind weak dependencies there, but Loki loads both backends,
# so the round trip through each can be compiled here. Loki's own operators
# join this workload as they are added.
@setup_workload begin
    dir = mktempdir()
    table = (time = [1, 2, 3], x = [1.0, 2.0, 3.0])
    @compile_workload begin
        ctx = Context(0, 10)
        for backend in (:parquet2, :duckdb)
            path = joinpath(dir, "precompile-$backend.parquet")
            scan(ctx, readtable(table) |> writeparquet(path; backend))
            load(ctx, readparquet(path; backend))
        end
        load(ctx,
            readtable(table) |> lags(:x, 2) |> difference(:x) |> logtransform(:x) |>
            boxcox(:x; lambda = 0.5))
        load(ctx,
            readtable(table) |> ema(:x; span = 3) |> ema(:x; halflife = 2) |>
            macd(:x; fast = 2, slow = 3, signal = 2))
        load(ctx, readtable(table) |> ar(:x, 1))

        # An ARMA fit and filter: the first `fit!` otherwise costs a user many
        # seconds of compilation.
        series = (time = collect(1:40), y = sin.(1:40) .+ 0.1 .* cos.((1:40) .^ 2))
        src = readtable(series)
        models = src |> fitonce(Context(0, 21), FitARMA(:y; order = (1, 0, 1)))
        load(Context(0, 41), src |> applyarma(models, :y; horizon = 1))
        load(Context(0, 41), src |> arma(clock(10), 20, :y; order = (1, 0, 0)))
        load(Context(0, 41), src |> Acausal.insample(FitARMA(:y; order = (1, 0, 0))))
        load(Context(0, 41),
            src |> lags(:y, 1) |> Acausal.insample(LinearRegression(:y_lag_1, :y)))

        # The diagnostics a panel opens with, so the first one a user asks for
        # does not cost them StatsBase's and HypothesisTests' compilation.
        frame = load(Context(0, 41), src |> ema(:y; span = 5))
        acf(frame, :y; lags = 5)
        pacf(frame, :y; lags = 5)
        ljungbox(frame, :y; lags = 5, dof = 0)
        Loki.seriesplot(frame, :y)
        Loki.preview(frame; limit = 5)

        # A headless session: a graph built from node kinds, compiled, and
        # evaluated synchronously by freeze! (runs spawn tasks, which a
        # precompile workload should not leave behind).
        session = Session(; tables = (series = series,),
            contexts = (analysis = Context(0, 41),))
        node = addnode!(session, "table", Dict("table" => "series"))
        smooth = addnode!(session, "ema", Dict("column" => "y", "span" => 5))
        connect!(session, (node, :out), (smooth, :in))
        freeze!(session, smooth)
        # The exporter, printer and all: the first export otherwise costs a user
        # seconds of compilation. `:argument` writes nothing.
        exportjulia(session)
        # Saving and opening covers the JSON and the table snapshots with it.
        opensession(savesession(joinpath(dir, "precompile.loki.json"), session))
    end
end
