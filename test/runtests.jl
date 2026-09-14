using Aqua
using CausalFrames
using DataFrames
using Loki
using Test

include("fixtures.jl")

@testset "Loki.jl" begin
    @testset "Aqua" begin
        # The persistent-tasks check resolves Loki in a fresh environment, which
        # finds the unregistered CausalFrames only through [sources] — and Julia
        # 1.10 ignores [sources]. 1.11+ still runs it.
        Aqua.test_all(Loki; persistent_tasks = VERSION >= v"1.11")
    end

    @testset "dependencies" begin
        # CausalFrames' optional dependencies are Loki's hard ones, so loading
        # Loki makes every CausalFrames operator available.
        for ext in (:CausalFramesDuckDBExt, :CausalFramesParquet2Ext,
            :CausalFramesMLJModelInterfaceExt)
            @test Base.get_extension(CausalFrames, ext) !== nothing
        end
    end

    @testset "Acausal is opt-in" begin
        @test Loki.Acausal isa Module
        @test :Acausal ∉ names(Loki)
    end

    include("lags.jl")
    include("ema.jl")
    include("arma.jl")
    include("insample.jl")

    # JET can lag pre-release Julia; the checks are the same on every
    # released version, so skipping them there loses nothing.
    if isempty(VERSION.prerelease)
        include("jet.jl")
    end
end
