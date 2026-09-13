# Loki

[![Build Status](https://github.com/farrellm/Loki.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/farrellm/Loki.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![Dev docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://farrellm.github.io/Loki.jl/dev/)

An interactive environment for time-series analysis built on
[CausalFrames](https://github.com/farrellm/CausalFrames.jl). You build a graph
of `CausalPipeline`s and time-series operators (differencing, EMA, MACD, AR,
ARMA, …), inspect each node's output through diagnostics such as ACF, PACF and
residual tests, and export the graph as a plain Julia script. The same session
can be driven from a browser or by an agent over MCP.

Loki is under construction; [DESIGN.md](DESIGN.md) describes the design and its
milestones.
