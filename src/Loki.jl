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
using PrecompileTools: @setup_workload, @compile_workload

include("acausal.jl")

end
