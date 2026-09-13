using Aqua
using CausalFrames
using Loki
using Test

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

    # JET can lag pre-release Julia; the checks are the same on every
    # released version, so skipping them there loses nothing.
    if isempty(VERSION.prerelease)
        include("jet.jl")
    end
end
