# Targeted JET checks, following CausalFrames: the per-row kernels (summarizer
# `update!`/`value`, the ARMA filter step) sit behind function barriers and must
# stay free of runtime dispatch, checked one by one with `JET.@test_opt`.
# Whole-package analysis is deliberately not used — the per-run setup around
# those barriers is intended dynamism and would flood a package-level report.
#
# Loki has no kernels yet; Milestone 1's summarizers add their checks here.

using JET
