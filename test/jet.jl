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
    end
end
