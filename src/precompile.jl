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
    end
end
