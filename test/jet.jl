# Targeted JET checks, following CausalFrames: the per-row kernels (summarizer
# `update!`/`value`, the ARMA filter step) sit behind function barriers and must
# stay free of runtime dispatch, checked one by one with `JET.@test_opt`.
# Whole-package analysis is deliberately not used — the per-run setup around
# those barriers is intended dynamism and would flood a package-level report.

using JET

@testset "JET" begin
    @testset "Lags" begin
        for T in (Float64, Union{Missing,Int}, String)
            st = CausalFrames.fresh(Lags(:x, 3), (time = Int, x = T))
            row = (time = 1, x = T === String ? "a" : 1)
            JET.@test_opt CausalFrames.update!(st, row)
            JET.@test_opt CausalFrames.value(st)
        end
    end

    @testset "row functions" begin
        row = (time = 1, x = 2.0, var"#x_difflag_1" = 1.0, var"#x_difflag_2" = missing)
        f = Loki.DiffRow{:x,(Symbol("#x_difflag_1"), Symbol("#x_difflag_2")),:x_diff,
            Tuple{Int,Int}}((-2, 1))
        JET.@test_opt f(row)
        JET.@test_opt Loki.LogRow{:x,:x_log}()(row)
        JET.@test_opt Loki.BoxCoxRow{:x,:x_boxcox}(0.5)(row)
        mrow = (time = 1, x = 2.0, macd = missing, macd_signal = 1.0)
        JET.@test_opt Loki.ColumnDiff{:macd,:macd_signal,:macd_hist}()(mrow)
        JET.@test_opt Loki.CompleteRows{(:x, :macd)}()(mrow)
    end

    @testset "EMA" begin
        for e in (EMA(:x; span = 5), EMA(:x; halflife = 2))
            st = CausalFrames.fresh(e, (time = Int, x = Float64))
            JET.@test_opt CausalFrames.update!(st, (time = 3, x = 1.5))
            JET.@test_opt CausalFrames.value(st)
        end
        st = CausalFrames.fresh(EMA(:x; halflife = Dates.Minute(2)),
            (time = Dates.DateTime, x = Union{Missing,Int}))
        for x in (missing, 4)
            JET.@test_opt CausalFrames.update!(st, (time = Dates.DateTime(2020), x = x))
        end
        JET.@test_opt CausalFrames.value(st)
    end

    @testset "ARMA" begin
        fm = fitone(sin.(1:80) .+ 0.1 .* cos.((1:80) .^ 2), (1, 1, 1))
        intypes =
            (time = Int, y = Union{Missing,Float64}, model = Union{Missing,FittedARMA})
        R = NamedTuple{keys(intypes),Tuple{values(intypes)...}}
        st = CausalFrames.fresh(ARMAFilter(:y; horizon = 2), intypes)
        for row in (R((1, 1.0, fm)), R((2, missing, fm)), R((3, 1.0, missing)))
            JET.@test_opt CausalFrames.update!(st, row)
            JET.@test_opt CausalFrames.value(st)
        end
        fst = CausalFrames.fresh(FitARMA(:y; order = (1, 0, 0)), intypes)
        JET.@test_opt CausalFrames.update!(fst, R((1, missing, fm)))
    end

    @testset "fit row functions" begin
        B = (Symbol("#fit_intercept_beta"), Symbol("#fit_x_beta"))
        row = NamedTuple{(:time, :x, :z, B...)}((1, 2.0, 1.0, 0.5, missing))
        JET.@test_opt Loki.LinearFitRow{(:x,),:z,B,true,:z_fitted,:z_residual}()(row)
        JET.@test_opt Loki.LinearFitRow{(:x,),:z,B[2:2],false,:z_fitted,:z_residual}()(row)
    end
end
