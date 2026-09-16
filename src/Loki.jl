"""
    Loki

An interactive environment for time-series analysis built on CausalFrames: a
graph of `CausalPipeline`s and time-series operators, diagnostics over every
node's output, and export of the graph as a plain Julia script. See DESIGN.md.
"""
module Loki

using CausalFrames
# CausalFrames' optional dependencies are Loki's hard dependencies: loading them
# here loads its parquet and MLJ extensions, so every operator is available.
using DuckDB: DuckDB
using Parquet2: Parquet2
# Imported, not used: MLJModelInterface re-exports the scientific types, and its
# `Count` would clash with CausalFrames' summarizer.
import MLJModelInterface
using JSON3: JSON3
using PrecompileTools: @setup_workload, @compile_workload

using Dates: Dates
using Statistics: Statistics
using DataFrames: DataFrame, nrow
using Tables: Tables

using LinearAlgebra: I, dot, mul!
using MatrixEquations: lyapd
# Imported as a module: StateSpaceModels exports a `LinearRegression` that would
# clash with CausalFrames'.
import StateSpaceModels as SSM

export Lags, EMA, FitARMA, FittedARMA, ARMAFilter, lags, difference, logtransform,
    boxcox, ema, macd, ar, fitarma, applyarma, arma, fitonce, exportjulia

include("timeseries/summarizers.jl")
include("timeseries/operators.jl")
include("acausal.jl")
include("registry.jl")
include("graph.jl")
include("usercode.jl")
include("tables.jl")
include("nodes/causalframes.jl")
include("nodes/timeseries.jl")
include("compile.jl")
include("engine.jl")
include("session.jl")
# After the session: `exportjulia` takes one, and everything else here is reached
# from a node kind's `emit` at run time.
include("export.jl")
include("persist.jl")
include("precompile.jl")

end
