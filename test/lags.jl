@testset "Lags and lags" begin
    @test_throws ArgumentError Lags(:x, 0)
    @test keys(CausalFrames.emptyvalue(Lags(:x, 2))) == (:x_lag_1, :x_lag_2)
    @test keys(CausalFrames.emptyvalue(Lags(:x, 2; name = :h))) == (:h_1, :h_2)

    n = 20
    x = collect(1.0:n) .^ 2
    df = DataFrame(time = 1:n, x = x)
    ctx = Context(0, 100)
    out = streamequalsload(src -> src |> lags(:x, 3), ctx, df)
    for k in 1:3
        col = out[!, Symbol(:x_lag_, k)]
        @test eltype(col) == Union{Missing,Float64}
        @test all(ismissing, col[1:k])
        @test col[(k+1):end] == x[1:(end-k)]
    end
    @test isequal(DataFrame(load(ctx, lags(readtable(df), :x, 1))).x_lag_1,
        out.x_lag_1)

    # Per key: each key's history is its own.
    dk = DataFrame(time = 1:10, k = repeat([1, 2], 5), x = 1:10)
    outk = streamequalsload(src -> src |> lags(:x, 2; key = :k), ctx, dk)
    for key in (1, 2)
        rows = outk[outk.k .== key, :]
        @test isequal(rows.x_lag_1, [missing; rows.x[1:(end-1)]])
        @test isequal(rows.x_lag_2, [missing; missing; rows.x[1:(end-2)]])
    end

    # A missing-admitting input keeps its missings, and a string column works.
    dm = DataFrame(time = 1:4, x = [1, missing, 3, 4], s = ["a", "b", "c", "d"])
    outm = DataFrame(load(ctx, readtable(dm) |> lags(:x, 1) |> lags(:s, 2)))
    @test isequal(outm.x_lag_1, [missing, 1, missing, 3])
    @test isequal(outm.s_lag_2, [missing, missing, "a", "b"])

    # A chunk widening the column type mid-stream widens the buffered history.
    widening = CausalPipeline(
        ctx -> [DataFrame(time = [1, 2], x = [1, 2]),
            DataFrame(time = [3, 4], x = [3.5, 4.5])],
    )
    outw = DataFrame(load(ctx, widening |> lags(:x, 2)))
    @test isequal(outw.x_lag_2, [missing, missing, 1.0, 2.0])

    # Collision with an existing column is CausalFrames' error.
    @test_throws ArgumentError load(ctx, readtable(outm) |> lags(:x, 1))
end

@testset "difference" begin
    @test_throws ArgumentError difference(:x; order = 0)
    @test_throws ArgumentError difference(:x; lag = 0)

    n = 30
    x = cumsum(cumsum(collect(1.0:n) .^ 1.5))
    df = DataFrame(time = 1:n, x = x)
    ctx = Context(0, 100)

    out = streamequalsload(src -> src |> difference(:x), ctx, df)
    @test names(out) == ["time", "x", "x_diff"]
    @test ismissing(out.x_diff[1])
    @test out.x_diff[2:end] ≈ diff(x)

    out2 = streamequalsload(src -> src |> difference(:x; order = 2, lag = 3), ctx, df)
    @test names(out2) == ["time", "x", "x_diff_2_3"]
    @test all(ismissing, out2.x_diff_2_3[1:6])
    ref = [x[t] - 2x[t-3] + x[t-6] for t in 7:n]
    @test out2.x_diff_2_3[7:end] ≈ ref

    # An existing x_lag_1 column does not collide with difference's internal lags.
    withlag = DataFrame(load(ctx, readtable(df) |> lags(:x, 1) |>
                        difference(:x; name = :dx)))
    @test names(withlag) == ["time", "x", "x_lag_1", "dx"]

    dk = DataFrame(time = 1:10, k = repeat([1, 2], 5), x = (1:10) .^ 2)
    outk = streamequalsload(src -> src |> difference(:x; key = :k), ctx, dk)
    @test isequal(outk.x_diff, vcat(missing, missing, [dk.x[t] - dk.x[t-2] for t in 3:10]))
    @test eltype(outk.x_diff) == Union{Missing,Int}
end

@testset "logtransform and boxcox" begin
    ctx = Context(0, 10)
    df = DataFrame(time = 1:4, x = [1.0, 2.0, missing, 8.0])
    out = DataFrame(
        load(
            ctx,
            readtable(df) |> logtransform(:x) |>
            boxcox(:x; lambda = 0.5) |> boxcox(:x; lambda = 0, name = :b0),
        ),
    )
    @test isequal(out.x_log, [0.0, log(2.0), missing, log(8.0)])
    @test isequal(
        out.x_boxcox,
        [0.0, (sqrt(2.0) - 1) / 0.5, missing, (sqrt(8.0) - 1) / 0.5],
    )
    @test isequal(out.b0, out.x_log)
    @test_throws ArgumentError boxcox(:x; lambda = Inf)
    @test DataFrame(load(ctx, logtransform(readtable(df), :x; name = :l))).l[2] ≈ log(2)
end
