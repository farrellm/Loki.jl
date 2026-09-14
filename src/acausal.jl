"""
    Loki.Acausal

Loki's forward-looking operators, the counterpart of `CausalFrames.Acausal`.
Nothing here is re-exported from `Loki`: using an operator whose output at time
`t` depends on rows after `t` takes an explicit `using Loki.Acausal`.
"""
module Acausal

using CausalFrames
using DataFrames: DataFrame
import ..Loki

export insample

"""
    insample(s::Summarizer; fitcontext = nothing, key = nothing)
        -> (CausalPipeline -> CausalPipeline)
    insample(pipeline::CausalPipeline, s::Summarizer; ...) -> CausalPipeline

A transform appending a fitted model's in-sample fitted values and residuals:
the model `s` fits (one per key) over the whole fit window, applied to every row
of the stream — including the rows it was fit on, which is what makes it
acausal. Each run:

1. loads [`Loki.fitinput`](@ref)`(s, pipeline) |> summarize(s; key)` over
   `fitcontext`, or over the run's own context when it is `nothing`;
2. places each model row at the *start* of the run's context — the one
   acausal step;
3. applies the models to the stream with [`Loki.applyfit`](@ref).

| Fitting summarizer | Columns appended |
|---|---|
| [`FitARMA`](@ref Loki.FitARMA) | `x_fitted`, `x_residual`, `x_stdresidual` |
| CausalFrames' `LinearRegression` | `y_fitted`, `y_residual` |
| CausalFrames' `FitModel` (MLJ) | `y_fitted`, `y_residual` |

With a `fitcontext` narrower than the run's, the rows inside it carry in-sample
residuals and the rows after it the same model applied out of sample.
"""
function insample(s::Summarizer; fitcontext::Union{Nothing,Context} = nothing,
    key = nothing)
    return function (p::CausalPipeline)
        fit = Loki.fitinput(s, p) |> summarize(s; key)
        return CausalPipeline() do ctx::Context
            models = DataFrame(load(something(fitcontext, ctx), fit))
            placed = readtable(models; time = _ -> ctx.start)
            # A read of the composed pipeline's `run` field, as in `fitonce`:
            # the fit is materialized once per run, before the stream starts.
            return Loki.applyfit(s, p, placed; key).run(ctx)
        end
    end
end
insample(pipeline::CausalPipeline, s::Summarizer; kwargs...) =
    insample(s; kwargs...)(pipeline)

end
