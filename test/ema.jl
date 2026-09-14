using Dates

# Reference EMA: seeded with the first non-missing value, `missing` before it; a
# `missing` value leaves the average unchanged. `alpha(t, tprev)` gives the
# weight of the new value.
function refema(x, times, alpha)
    out = Vector{Union{Missing,Float64}}(missing, length(x))
    s = 0.0
    tprev = nothing
    for i in eachindex(x)
        if !ismissing(x[i])
            s =
                tprev === nothing ? float(x[i]) :
                alpha(times[i], tprev) * x[i] + (1 - alpha(times[i], tprev)) * s
            tprev = times[i]
        end
        out[i] = tprev === nothing ? missing : s
    end
    return out
end

@testset "EMA and ema" begin
    @test_throws ArgumentError EMA(:x)
    @test_throws ArgumentError EMA(:x; span = 3, halflife = 2)
    @test_throws ArgumentError EMA(:x; span = 0.5)
    @test_throws ArgumentError EMA(:x; halflife = 0)
    @test keys(CausalFrames.emptyvalue(EMA(:x; span = 12))) == (:x_ema_12,)
    @test keys(CausalFrames.emptyvalue(EMA(:x; halflife = 5))) == (:x_ema_hl_5,)
    @test keys(CausalFrames.emptyvalue(EMA(:x; halflife = Minute(5)))) ==
          (:x_ema_hl_5minute,)
    @test keys(CausalFrames.emptyvalue(EMA(:x; span = 3, name = :e))) == (:e,)

    ctx = Context(0, 1000)
    x = [missing; sin.(1:40) .* 10; missing; 3.0]
    n = length(x)
    df = DataFrame(time = 1:n, x = x)

    out = streamequalsload(src -> src |> ema(:x; span = 5), ctx, df)
    @test eltype(out.x_ema_5) == Union{Missing,Float64}
    ref = refema(x, 1:n, (t, tp) -> 2 / 6)
    @test isequal(ismissing.(out.x_ema_5), ismissing.(ref))
    @test collect(skipmissing(out.x_ema_5)) ≈ collect(skipmissing(ref))

    # Time-aware form on an irregular numeric clock.
    times = cumsum(1 .+ mod.(7 .* (1:n), 5))
    dfi = DataFrame(time = times, x = x)
    outi = streamequalsload(src -> src |> ema(:x; halflife = 4), ctx, dfi)
    refi = refema(x, times, (t, tp) -> 1 - exp(-log(2) * (t - tp) / 4))
    @test collect(skipmissing(outi.x_ema_hl_4)) ≈ collect(skipmissing(refi))

    # DateTime time with a Period half-life.
    t0 = DateTime(2020, 1, 1)
    dts = [t0 + Minute(m) for m in times]
    dfd = DataFrame(time = dts, x = x)
    ctxd = Context(t0, t0 + Day(1))
    outd = streamequalsload(src -> src |> ema(:x; halflife = Minute(4)), ctxd, dfd)
    @test collect(skipmissing(outd.x_ema_hl_4minute)) ≈ collect(skipmissing(refi))
    @test_throws ArgumentError load(ctx, readtable(dfi) |> ema(:x; halflife = Minute(4)))

    # Keyed: each key averages its own rows.
    dk = DataFrame(time = 1:20, k = repeat([1, 2], 10), x = Float64.(1:20))
    outk = streamequalsload(src -> src |> ema(:x; span = 3, key = :k), ctx, dk)
    for key in (1, 2)
        rows = outk[outk.k .== key, :]
        @test rows.x_ema_3 ≈ refema(rows.x, rows.time, (t, tp) -> 0.5)
    end
    @test DataFrame(load(ctx, ema(readtable(dk), :x; span = 3, name = :e))).e[2] ≈ 1.5
end

@testset "macd" begin
    @test_throws ArgumentError macd(:x; fast = 26, slow = 12)
    ctx = Context(0, 1000)
    x = cumsum(sin.(1:60))
    df = DataFrame(time = 1:60, x = x)
    out = streamequalsload(src -> src |> macd(:x; fast = 3, slow = 7, signal = 4), ctx, df)
    @test names(out) == ["time", "x", "macd", "macd_signal", "macd_hist"]
    fast = refema(x, 1:60, (t, tp) -> 2 / 4)
    slow = refema(x, 1:60, (t, tp) -> 2 / 8)
    m = fast .- slow
    sig = refema(m, 1:60, (t, tp) -> 2 / 5)
    @test out.macd ≈ m
    @test out.macd_signal ≈ sig
    @test out.macd_hist ≈ m .- sig
    named = DataFrame(load(ctx, macd(readtable(df), :x; name = :m)))
    @test names(named) == ["time", "x", "m", "m_signal", "m_hist"]
end

@testset "ar" begin
    @test_throws ArgumentError ar(:x, 0)
    ctx = Context(0, 1000)
    n = 200
    x = zeros(n)
    e = sin.(1:n) .* 0.5 .+ cos.((1:n) .^ 1.3)
    for t in 3:n
        x[t] = 0.3 + 0.5x[t-1] - 0.2x[t-2] + e[t]
    end
    df = DataFrame(time = 1:n, x = x)
    out = streamequalsload(src -> src |> ar(:x, 2), ctx, df)
    @test nrow(out) == 1
    X = hcat(ones(n - 2), x[2:(n-1)], x[1:(n-2)])
    β = X \ x[3:n]
    @test out.ar_intercept_beta[1] ≈ β[1]
    @test out.ar_x_lag_1_beta[1] ≈ β[2]
    @test out.ar_x_lag_2_beta[1] ≈ β[3]
    @test out.ar_n[1] == n - 2

    dk = DataFrame(time = 1:(2n), k = repeat([1, 2], n), x = repeat(x, inner = 2))
    outk = DataFrame(load(ctx, ar(readtable(dk), :x, 2; key = :k, name = :m)))
    @test outk.k == [1, 2]
    @test outk.m_x_lag_1_beta ≈ [β[2], β[2]]
end
