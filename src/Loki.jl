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
using HTTP: HTTP
using JSON3: JSON3
using Random: Random
using PrecompileTools: @setup_workload, @compile_workload

using Dates: Dates
using Statistics: Statistics
using DataFrames: DataFrame, nrow
using Tables: Tables

using LinearAlgebra: I, dot, mul!
# Imported as modules, never `using`'d: `StatsBase.pacf` would clash with Loki's
# own exported `pacf`, and extending it on a `CausalFrame` would be piracy.
import StatsBase
import StatsFuns
import HypothesisTests as HT
using MatrixEquations: lyapd
# Imported as a module: StateSpaceModels exports a `LinearRegression` that would
# clash with CausalFrames'.
import StateSpaceModels as SSM
# Imported as a module: ModelContextProtocol exports a `Server`, a `stop!`, a
# `connect` and a `Transport`, every one of which Loki already has a name for.
import ModelContextProtocol as MCP
# The MCP server takes the global logger and never gives it back; Loki hands it
# over and takes it again when the server stops.
import Logging

export Lags, EMA, FitARMA, FittedARMA, ARMAFilter, lags, difference, logtransform,
    boxcox, ema, macd, ar, fitarma, applyarma, arma, fitonce, exportjulia,
    acf, pacf, adftest, ljungbox, fitreport, forecastfan, serve, serve_mcp

include("timeseries/summarizers.jl")
include("timeseries/operators.jl")
include("acausal.jl")
include("registry.jl")
include("graph.jl")
include("events.jl")
include("usercode.jl")
include("tables.jl")
include("nodes/causalframes.jl")
include("nodes/timeseries.jl")
include("compile.jl")
include("engine.jl")
include("diagnostics.jl")
include("session.jl")
# After the session: `exportjulia` takes one, and everything else here is reached
# from a node kind's `emit` at run time.
include("export.jl")
include("persist.jl")
include("server.jl")
# After the server: MCP mode is the web server plus a JSON-RPC transport over
# the same session, and its tools answer with the server's own JSON shapes.
include("mcp.jl")
include("precompile.jl")

end
