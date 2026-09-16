using Aqua
using CausalFrames
using DataFrames
using Loki
using Test

include("fixtures.jl")

@testset "Loki.jl" begin
    @testset "Aqua" begin
        Aqua.test_all(Loki)
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
    include("graph.jl")
    include("nodes.jl")
    include("engine.jl")
    include("diagnostics.jl")
    include("events.jl")
    include("export.jl")
    include("persist.jl")

    # JET can lag pre-release Julia; the checks are the same on every
    # released version, so skipping them there loses nothing.
    if isempty(VERSION.prerelease)
        include("jet.jl")
    end
end
