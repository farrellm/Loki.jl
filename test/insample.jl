using Loki.Acausal

@testset "insample" begin
    @test :insample in names(Loki.Acausal)
    @test :insample ∉ names(Loki)

    rng = Xoshiro(21)
    n = 250
    y = simulate(rng, n)
    df = DataFrame(time = 1:n, y = y)
    ctx = Context(1, n + 1)

    @testset "ARMA" begin
        out = streamequalsload(src -> src |> insample(FitARMA(:y; order = (1, 0, 1))), ctx,
            df; sizes = (7, 1000))
        @test names(out) == ["time", "y", "y_fitted", "y_residual", "y_stdresidual"]
        fm = fitone(y, (1, 0, 1))
        checkfilter(out, fm, y)

        # Fit on a narrower window, apply over the whole one.
        narrow = DataFrame(
            load(ctx,
                insample(readtable(df), FitARMA(:y; order = (1, 0, 1));
                    fitcontext = Context(1, 101))),
        )
        checkfilter(narrow, fitone(y[1:100], (1, 0, 1)), y)

        # Acausal by construction: a late row changes the first row's residual.
        late = copy(df)
        late.y[end] += 100
        moved = DataFrame(
            load(ctx, readtable(late) |>
                      insample(FitARMA(:y; order = (1, 0, 1)))),
        )
        @test moved.y_residual[2] != out.y_residual[2]
    end

    @testset "LinearRegression" begin
        x = randn(rng, n)
        z = 2 .+ 3 .* x .+ 0.1 .* randn(rng, n)
        dl = DataFrame(time = 1:n, x = allowmissing(x), z = z)
        dl.x[5] = missing
        out = streamequalsload(src -> src |> insample(LinearRegression(:x, :z; name = :m)),
            ctx, dl)
        @test names(out) == ["time", "x", "z", "z_fitted", "z_residual"]
        keep = setdiff(1:n, 5)
        β = hcat(ones(n - 1), x[keep]) \ z[keep]
        @test ismissing(out.z_fitted[5])
        @test Float64.(out.z_fitted[keep]) ≈ β[1] .+ β[2] .* x[keep]
        @test Float64.(out.z_residual[keep]) ≈ z[keep] .- (β[1] .+ β[2] .* x[keep])

        # Without an intercept, and keyed with a different slope per key.
        k = repeat([1, 2], n ÷ 2)
        zk = [ki == 1 ? 2x[i] : -x[i] for (i, ki) in enumerate(k)]
        dk = DataFrame(time = 1:n, k = k, x = x, z = zk)
        outk = DataFrame(
            load(
                ctx,
                readtable(dk) |>
                insample(LinearRegression([:x], :z; intercept = false);
                    key = :k),
            ),
        )
        @test Float64.(outk.z_fitted) ≈ zk
        @test maximum(abs, outk.z_residual) < 1e-10
    end

    @testset "AR by least squares" begin
        out = DataFrame(
            load(ctx,
                readtable(df) |> lags(:y, 2) |>
                insample(LinearRegression([:y_lag_1, :y_lag_2], :y))),
        )
        @test all(ismissing, out.y_fitted[1:2])
        X = hcat(ones(n - 2), y[2:(n-1)], y[1:(n-2)])
        β = X \ y[3:n]
        @test Float64.(out.y_fitted[3:n]) ≈ X * β
    end
end
