import StateSpaceModels as SSM
using LinearAlgebra: I
using Random: Xoshiro, randn

function simulate(rng, n; ar = [0.6], ma = [0.3])
    e = randn(rng, n)
    y = zeros(n)
    for t in 1:n
        y[t] = e[t]
        for (i, φ) in enumerate(ar)
            t > i && (y[t] += φ * y[t-i])
        end
        for (j, θ) in enumerate(ma)
            t > j && (y[t] += θ * e[t-j])
        end
    end
    return y
end

fitone(y, order; seasonal_order = (0, 0, 0, 0)) =
    only(
        DataFrame(
            load(Context(0, length(y) + 1),
                readtable(DataFrame(time = 1:length(y), y = y)) |>
                fitarma(:y; order, seasonal_order)),
        ).model,
    )

# StateSpaceModels' own filter over `ys` with `fm`'s fitted hyperparameters, with
# its steady-state shortcut disabled (a negative tolerance): past the tolerance
# it freezes the covariance, which after a gap leaves the variance stale.
function nonsteadyfilter(fm::FittedARMA)
    k = length(fm.Z)
    return SSM.UnivariateKalmanFilter(zeros(k), Matrix(1e6I, k, k), 0, -1.0)
end
function ssmmodel(fm::FittedARMA, ys::Vector{Float64})
    m = SSM.SARIMA(copy(ys); order = fm.order, seasonal_order = fm.seasonal_order,
        include_mean = fm.include_mean)
    m.hyperparameters = deepcopy(fm.model.hyperparameters)
    return m
end
function ssmfilter(fm::FittedARMA, ys::Vector{Float64})
    fo = SSM.kalman_filter(ssmmodel(fm, ys); filter = nonsteadyfilter(fm))
    return SSM.get_innovations(fo)[:, 1], SSM.get_innovations_variance(fo)[:, 1, 1]
end

# `out`'s rows are `ys`'s, filtered by `fm` from the first row.
function checkfilter(out::AbstractDataFrame, fm::FittedARMA, ys::Vector{Float64})
    v, F = ssmfilter(fm, ys)
    obs = findall(!isnan, ys)
    @test all(ismissing, out.y_residual[findall(isnan, ys)])
    @test all(ismissing, out.y_stdresidual[findall(isnan, ys)])
    @test Float64.(out.y_residual[obs]) ≈ v[obs] rtol = 1e-6 atol = 1e-8
    @test Float64.(out.y_stdresidual[obs]) ≈ v[obs] ./ sqrt.(F[obs]) rtol = 1e-6 atol = 1e-8
    @test Float64.(out.y_fitted[obs]) ≈ ys[obs] .- v[obs] rtol = 1e-6 atol = 1e-8
end

modeltable(times, fms) =
    readtable(DataFrame(time = times, model = Union{Missing,FittedARMA}[fms...]))

function filterallocs(st, row)
    CausalFrames.update!(st, row)
    CausalFrames.value(st)
    return @allocated begin
        CausalFrames.update!(st, row)
        CausalFrames.value(st)
    end
end

@testset "FitARMA and fitarma" begin
    @test_throws ArgumentError FitARMA(:y; order = (-1, 0, 0))
    @test_throws ArgumentError FitARMA(:y; order = (1, 0))
    @test_throws ArgumentError FitARMA(:y; order = (1, 0, 0), seasonal_order = (1, 0, 0, 1))
    @test_throws ArgumentError FitARMA(:y; order = (1, 0, 0), name = :y)

    rng = Xoshiro(7)
    n = 300
    y = simulate(rng, n)
    df = DataFrame(time = 1:n, y = y)
    ctx = Context(0, n + 1)
    out = DataFrame(load(ctx, readtable(df) |> fitarma(:y; order = (1, 0, 1))))
    @test names(out) == ["time", "model"]
    @test out.time == [n + 1]
    @test eltype(out.model) == Union{Missing,FittedARMA}
    fm = only(out.model)
    ref = SSM.SARIMA(copy(y); order = (1, 0, 1))
    SSM.fit!(ref; save_hyperparameter_distribution = false)
    @test fm.status === :ok
    @test fm.names == SSM.get_names(ref)
    @test fm.coefs ≈ [SSM.get_constrained_value(ref, k) for k in fm.names]
    @test fm.loglik ≈ ref.results.llk
    @test fm.aic ≈ ref.results.aic
    @test fm.bic ≈ ref.results.bic
    @test fm.nobs == n
    @test occursin("ARIMA(1, 0, 1)", sprint(show, fm))

    # A missing value is a gap in the series, not a dropped row.
    dm = DataFrame(time = 1:n, y = allowmissing(y))
    dm.y[10] = missing
    fmm = only(
        DataFrame(load(ctx, fitarma(readtable(dm), :y; order = (1, 0, 0),
            name = :m))).m,
    )
    @test fmm.status === :ok
    @test fmm.nobs == n - 1

    # A fit that cannot succeed is recorded, not raised.
    bad = only(
        DataFrame(
            load(
                ctx,
                readtable(
                    DataFrame(time = 1:5,
                        y = Vector{Union{Missing,Float64}}(missing, 5)),
                ) |> fitarma(:y; order = (1, 0, 0)),
            ),
        ).model,
    )
    @test bad.status === :failed
    @test !isempty(bad.message)
    @test occursin("failed", sprint(show, bad))

    # Keyed: one model per key.
    y2 = simulate(rng, n; ar = [-0.4], ma = Float64[])
    dk = DataFrame(time = 1:(2n), k = repeat([1, 2], n), y = vec(permutedims(hcat(y, y2))))
    outk = DataFrame(
        load(Context(0, 2n + 1), readtable(dk) |>
            fitarma(:y; order = (1, 0, 0), key = :k)),
    )
    @test outk.k == [1, 2]
    @test outk.model[1].coefs ≈ fitone(y, (1, 0, 0)).coefs
    @test outk.model[2].coefs ≈ fitone(y2, (1, 0, 0)).coefs

    @test_throws ArgumentError load(
        ctx,
        readtable(DataFrame(time = 1:3,
            y = ["a", "b", "c"])) |> fitarma(:y; order = (1, 0, 0)),
    )

    # A model table survives writejls/readjls.
    path = joinpath(mktempdir(), "models.jls")
    scan(ctx, readtable(df) |> fitarma(:y; order = (1, 0, 1)) |> writejls(path))
    # The model row is at the fit window's stop, which a half-open read excludes.
    @test only(DataFrame(load(Context(0, n + 2), readjls(path))).model).coefs == fm.coefs
end

@testset "ARMAFilter and applyarma" begin
    @test_throws ArgumentError ARMAFilter(:y; horizon = -1)
    @test_throws ArgumentError ARMAFilter(:y; model = :y)
    @test keys(CausalFrames.emptyvalue(ARMAFilter(:y; horizon = 2, name = :z))) ==
          (:z_fitted, :z_residual, :z_stdresidual, :z_forecast_1, :z_forecast_2)

    rng = Xoshiro(11)
    n = 400
    ctx = Context(1, 151)
    series = (
        ((1, 0, 0), simulate(rng, n; ma = Float64[])),
        ((1, 0, 1), simulate(rng, n)),
        ((1, 1, 0), cumsum(simulate(rng, n; ma = Float64[]))),
        ((2, 1, 1), cumsum(simulate(rng, n; ar = [0.5, 0.1]))),
    )
    for (order, y) in series
        fm = fitone(y, order)
        @test fm.status === :ok
        ys = y[1:150]
        ys[40] = NaN
        ys[41] = NaN
        dfs = DataFrame(time = 1:150, y = ys)
        out = streamequalsload(src -> src |> applyarma(modeltable([1], [fm]), :y), ctx, dfs)
        @test names(out) == ["time", "y", "y_fitted", "y_residual", "y_stdresidual"]
        checkfilter(out, fm, ys)
    end

    order, y = series[2]
    fm1 = fitone(y, order)
    fm2 = fitone(y[1:200], (2, 0, 0))
    ys = y[201:350]
    dfs = DataFrame(time = 1:150, y = ys)

    # A model change mid-stream restarts the filter from the new model.
    out = DataFrame(
        load(ctx, readtable(dfs) |> applyarma(modeltable([1, 80], [fm1, fm2]), :y)),
    )
    checkfilter(out[1:79, :], fm1, ys[1:79])
    checkfilter(out[80:150, :], fm2, ys[80:150])

    # No model yet, a failed model, a missing model cell, and no model rows at all.
    out = DataFrame(load(ctx, applyarma(readtable(dfs), modeltable([20], [fm1]), :y)))
    @test all(ismissing, out.y_fitted[1:19])
    checkfilter(out[20:150, :], fm1, ys[20:150])
    bad = FitARMA(:y; order = (1, 0, 0))
    failed = Loki.failedarma(bad, 0, "no")
    out = DataFrame(
        load(
            ctx,
            readtable(dfs) |>
            applyarma(modeltable([1, 50, 100], [fm1, failed, missing]), :y),
        ),
    )
    @test all(!ismissing, out.y_fitted[1:49])
    @test all(ismissing, out.y_fitted[50:150])
    out = DataFrame(load(ctx, readtable(dfs) |> applyarma(modeltable([500], [fm1]), :y)))
    @test names(out) == ["time", "y", "y_fitted", "y_residual", "y_stdresidual"]
    @test all(ismissing, out.y_fitted)

    # Forecasts: forecast_1 is the next row's prediction, and each matches
    # StateSpaceModels' forecast from the same filtered state.
    out = DataFrame(
        load(
            ctx,
            readtable(dfs) |>
            applyarma(modeltable([1], [fm1]), :y; horizon = 3, name = :y),
        ),
    )
    @test Float64.(out.y_forecast_1[1:(end-1)]) ≈ Float64.(out.y_fitted[2:end])
    fc = SSM.forecast(ssmmodel(fm1, ys), 3; filter = nonsteadyfilter(fm1))
    @test [out[150, Symbol(:y_forecast_, h)] for h in 1:3] ≈
          [e[1] for e in fc.expected_value] rtol = 1e-6

    # Keyed: each key is filtered by its own model.
    y2 = series[1][2][1:150]
    fk = fitone(series[1][2], (1, 0, 0))
    dk =
        DataFrame(time = 1:300, k = repeat([1, 2], 150), y = vec(permutedims(hcat(ys, y2))))
    models = readtable(
        DataFrame(time = [0, 0], k = [1, 2],
            model = Union{Missing,FittedARMA}[fm1, fk]),
    )
    outk =
        streamequalsload(src -> src |> applyarma(models, :y; key = :k), Context(0, 301), dk)
    checkfilter(outk[outk.k .== 1, :], fm1, ys)
    checkfilter(outk[outk.k .== 2, :], fk, y2)

    # The per-row step allocates nothing once the model is in place.
    st = CausalFrames.fresh(ARMAFilter(:y; horizon = 2),
        (time = Int, y = Float64, model = Union{Missing,FittedARMA}))
    R = NamedTuple{(:time, :y, :model),Tuple{Int,Float64,Union{Missing,FittedARMA}}}
    @test filterallocs(st, R((1, 0.5, fm1))) == 0
    @test filterallocs(st, R((2, NaN, fm1))) == 0
end

@testset "arma" begin
    rng = Xoshiro(3)
    n = 300
    y = simulate(rng, n)
    df = DataFrame(time = 1:n, y = y)
    ctx = Context(1, n + 1)
    out =
        streamequalsload(src -> src |> arma(clock(50), 100, :y; order = (1, 0, 0)), ctx, df;
            sizes = (7, 1000))
    @test names(out) == ["time", "y", "y_fitted", "y_residual", "y_stdresidual"]
    # The tick at 1 has an empty window; from 51 on each tick fits on the rows
    # before it and filters the rows up to the next tick.
    @test all(ismissing, out.y_fitted[1:50])
    for τ in (51, 151, 251)
        rows = τ:min(τ+49, n)
        fm = only(
            DataFrame(
                load(Context(max(τ - 100, 1), τ),
                    readtable(df) |> fitarma(:y; order = (1, 0, 0))),
            ).model,
        )
        checkfilter(out[rows, :], fm, y[rows])
    end
    @test isequal(
        DataFrame(load(ctx, arma(readtable(df), clock(50), 100, :y;
            order = (1, 0, 0)))), out)
end

@testset "fitonce" begin
    rng = Xoshiro(5)
    n = 300
    y = simulate(rng, n)
    df = DataFrame(time = 1:n, y = y)
    trainctx = Context(1, 101)
    models = readtable(df) |> fitonce(trainctx, FitARMA(:y; order = (1, 0, 0)))
    whole = DataFrame(load(Context(1, n + 1), models))
    @test whole.time == [101]
    fm = only(whole.model)
    @test fm.coefs ≈ fitone(y[1:100], (1, 0, 0)).coefs
    @test nrow(DataFrame(load(Context(150, n + 1), models))) == 0

    # Rows before the training window's stop see no model.
    out = DataFrame(load(Context(51, n + 1), readtable(df) |> applyarma(models, :y)))
    @test all(ismissing, out.y_fitted[out.time .< 101])
    checkfilter(out[out.time .>= 101, :], fm, y[101:n])

    # A later window reaches the model through tolerance, which also bounds how
    # stale a matched model may be.
    later = DataFrame(
        load(Context(201, n + 1),
            readtable(df) |> applyarma(models, :y; tolerance = n)),
    )
    @test all(!ismissing, later.y_fitted)
    checkfilter(later, fm, y[201:n])

    @test DataFrame(
        load(Context(1, n + 1),
            fitonce(readtable(df), trainctx, FitARMA(:y; order = (1, 0, 0)))),
    ).time == [101]
end
