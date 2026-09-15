# The node kinds for Loki's own time-series operators, and the fit node: one model
# fit with two outputs, the causal model table and the acausal in-sample stream.

const SERIES = Param("column", :column; required = true, description = "the series")
const OUTNAME = Param("name", :column; description = "the output column (or prefix)")

namekw(params::AbstractDict) =
    params["name"] === nothing ? (;) : (; name = Symbol(params["name"]))

emitnamekw(params::AbstractDict) =
    params["name"] === nothing ? (;) : (; name = QuoteNode(Symbol(params["name"])))

emitseries(params::AbstractDict) = QuoteNode(Symbol(params["column"]))

register_nodekind!(
    OpKind("lags"; category = "time series",
        doc = "The previous p values of a column, as row lags.",
        inputs = ONEINPUT,
        params = [SERIES, Param("p", :integer; required = true), KEY, OUTNAME],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |> lags(Symbol(params["column"]), params["p"];
                    key = paramkey(params["key"]), namekw(params)...)
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:lags, emitseries(params), params["p"];
                        key = emitkey(params["key"]), emitnamekw(params)...))
            )),
)

register_nodekind!(
    OpKind("difference"; category = "time series",
        doc = "The order-th difference of a column at a row lag.",
        inputs = ONEINPUT,
        params = [
            SERIES, Param("order", :integer; default = 1),
            Param("lag", :integer; default = 1),
            KEY, OUTNAME,
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |> difference(Symbol(params["column"]);
                    order = params["order"], lag = params["lag"],
                    key = paramkey(params["key"]),
                    namekw(params)...)
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:difference, emitseries(params);
                        order = unless(params["order"], 1),
                        lag = unless(params["lag"], 1), key = emitkey(params["key"]),
                        emitnamekw(params)...))
            )),
)

register_nodekind!(
    OpKind("logtransform"; category = "time series",
        doc = "The natural logarithm of a column.",
        inputs = ONEINPUT, params = [SERIES, OUTNAME],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |>
                      logtransform(Symbol(params["column"]); namekw(params)...)
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:logtransform, emitseries(params); emitnamekw(params)...))
            )),
)

register_nodekind!(
    OpKind("boxcox"; category = "time series",
        doc = "The Box–Cox transform of a column with a fixed lambda.",
        inputs = ONEINPUT,
        params = [SERIES, Param("lambda", :number; required = true), OUTNAME],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |> boxcox(Symbol(params["column"]);
                    lambda = params["lambda"], namekw(params)...)
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:boxcox, emitseries(params); lambda = params["lambda"],
                        emitnamekw(params)...))
            )),
)

register_nodekind!(
    OpKind("ema"; category = "time series",
        doc = "An exponential moving average, by span or time-aware half-life.",
        inputs = ONEINPUT,
        params = [
            SERIES, Param("span", :number),
            Param("halflife", :code; description = "e.g. `Minute(30)`, or a number"),
            KEY, OUTNAME,
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |> ema(Symbol(params["column"]); span = params["span"],
                    halflife = paramcode(env, params, "halflife"),
                    key = paramkey(params["key"]),
                    namekw(params)...)
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:ema, emitseries(params); span = params["span"],
                        halflife = emitcode(params, "halflife"),
                        key = emitkey(params["key"]), emitnamekw(params)...))
            )),
)

register_nodekind!(
    OpKind("macd"; category = "time series",
        doc = "Moving average convergence/divergence, its signal and histogram.",
        inputs = ONEINPUT,
        params = [
            SERIES, Param("fast", :integer; default = 12),
            Param("slow", :integer; default = 26),
            Param("signal", :integer; default = 9),
            Param("name", :column; default = "macd"),
            KEY,
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |> macd(Symbol(params["column"]); fast = params["fast"],
                    slow = params["slow"], signal = params["signal"],
                    name = Symbol(params["name"]),
                    key = paramkey(params["key"]))
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:macd, emitseries(params); fast = unless(params["fast"], 12),
                        slow = unless(params["slow"], 26),
                        signal = unless(params["signal"], 9),
                        name = emitsym(unless(params["name"], "macd")),
                        key = emitkey(params["key"])))
            )),
)

register_nodekind!(
    OpKind("ar"; category = "time series",
        doc = "An AR(p) fit by least squares over the window.",
        inputs = ONEINPUT,
        params = [SERIES, Param("p", :integer; required = true), KEY,
            Param("name", :column; default = "ar")],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |> ar(Symbol(params["column"]), params["p"];
                    key = paramkey(params["key"]), name = Symbol(params["name"]))
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:ar, emitseries(params), params["p"];
                        key = emitkey(params["key"]),
                        name = emitsym(unless(params["name"], "ar"))))
            )),
)

const ORDER = Param("order", :integers; required = true, description = "(p, d, q)")
const SEASONAL = Param("seasonal_order", :integers; default = [0, 0, 0, 0],
    description = "(P, D, Q, s)")
const INCLUDEMEAN = Param("include_mean", :boolean; default = false)

armaspec(params::AbstractDict) = (; order = Tuple(params["order"]),
    seasonal_order = Tuple(params["seasonal_order"]),
    include_mean = params["include_mean"])

function emitarmaspec(params::AbstractDict)
    seasonal = unless(collect(params["seasonal_order"]), [0, 0, 0, 0])
    return (; order = Expr(:tuple, params["order"]...),
        seasonal_order = seasonal === nothing ? nothing : Expr(:tuple, seasonal...),
        include_mean = unless(params["include_mean"], false))
end

register_nodekind!(
    OpKind("fitarma"; category = "time series",
        doc = "One seasonal ARIMA model (per key) fit over the window.",
        inputs = ONEINPUT,
        params = [SERIES, ORDER, SEASONAL, INCLUDEMEAN,
            Param("name", :column; default = "model"),
            KEY],
        build = (params, inputs, env) ->
            (;
                out = inputs[:in] |>
                      fitarma(Symbol(params["column"]); armaspec(params)...,
                    name = Symbol(params["name"]), key = paramkey(params["key"]))
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:in],
                    opcall(:fitarma, emitseries(params); emitarmaspec(params)...,
                        name = emitsym(unless(params["name"], "model")),
                        key = emitkey(params["key"])))
            )),
)

register_nodekind!(
    OpKind("applyarma"; category = "time series",
        doc = "Filter a series with fitted ARIMA models: fitted values, residuals, forecasts.",
        inputs = [Port(:data), Port(:models)],
        params = [
            SERIES,
            Param("model", :column; default = "model", description = "the model column"),
            KEY, Param("tolerance", :code), Param("strict", :boolean; default = false),
            Param("horizon", :integer; default = 0), OUTNAME,
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:data] |>
                      applyarma(inputs[:models], Symbol(params["column"]);
                    column = Symbol(params["model"]), key = paramkey(params["key"]),
                    tolerance = paramcode(env, params, "tolerance"),
                    strict = params["strict"],
                    horizon = params["horizon"], namekw(params)...)
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:data],
                    opcall(:applyarma, inputs[:models], emitseries(params);
                        column = emitsym(unless(params["model"], "model")),
                        key = emitkey(params["key"]),
                        tolerance = emitcode(params, "tolerance"),
                        strict = unless(params["strict"], false),
                        horizon = unless(params["horizon"], 0), emitnamekw(params)...))
            )),
)

register_nodekind!(
    OpKind("arma"; category = "time series",
        doc = "Filter a series with an ARIMA model refit at each clock tick.",
        inputs = [Port(:data), Port(:clock)],
        params = [
            SERIES, Param("lookback", :code; required = true), ORDER, SEASONAL, INCLUDEMEAN,
            KEY, Param("horizon", :integer; default = 0), OUTNAME,
        ],
        build = (params, inputs, env) ->
            (;
                out = inputs[:data] |>
                      arma(inputs[:clock], requiredcode(env, params, "lookback"),
                    Symbol(params["column"]); armaspec(params)...,
                    key = paramkey(params["key"]),
                    horizon = params["horizon"], namekw(params)...)
            ),
        emit = (params, inputs) ->
            (;
                out = emitpipe(inputs[:data],
                    opcall(:arma, inputs[:clock], emitrequiredcode(params, "lookback"),
                        emitseries(params); emitarmaspec(params)...,
                        key = emitkey(params["key"]),
                        horizon = unless(params["horizon"], 0), emitnamekw(params)...))
            )),
)

register_nodekind!(
    OpKind("fitonce"; category = "models",
        doc = "Fit once over a named context and serve the model rows to any run.",
        inputs = ONEINPUT,
        params = [
            Param("context", :context; required = true),
            Param("summarizer", :summarizers; required = true,
                description = "exactly one fitting summarizer"),
            KEY,
        ],
        build = (params, inputs, env) -> begin
            ss = summarizers(env, params["summarizer"])
            length(ss) == 1 ||
                throw(
                    ArgumentError(
                        "fitonce takes exactly one summarizer, got $(length(ss))",
                    ),
                )
            (;
                out = inputs[:in] |>
                      fitonce(namedcontext(env, params["context"]), only(ss);
                    key = paramkey(params["key"]))
            )
        end,
        emit = (params, inputs) -> begin
            entries = params["summarizer"]
            checkentries(entries)
            length(entries) == 1 ||
                throw(
                    ArgumentError(
                        "fitonce takes exactly one summarizer, got $(length(entries))",
                    ),
                )
            (;
                out = emitpipe(inputs[:in],
                    opcall(:fitonce, emitcontext(params["context"]),
                        emitsummarizer(only(entries)); key = emitkey(params["key"])))
            )
        end),
)

# --- the fit node ---------------------------------------------------------------------

register_nodekind!(
    OpKind("fit"; category = "models",
        doc = "Fit a model: the causal model table, and the acausal in-sample residuals.",
        inputs = ONEINPUT, outputs = [:model, :insample], acausal = [:insample],
        params = [
            Param("family", :enum; choices = ["arma", "ar", "mlj"], required = true),
            Param("column", :column; required = true,
                description = "the series (arma, ar) or the response (mlj)"),
            Param("order", :integers; description = "(p, d, q), for arma"),
            SEASONAL, INCLUDEMEAN,
            Param("p", :integer; description = "the AR order, for ar"),
            Param("model", :code; description = "an MLJ model, for mlj"),
            Param("predictors", :columns; description = "the predictor columns, for mlj"),
            Param("fitcontext", :context;
                description = "fit over this named context instead of the run's"),
            KEY,
        ],
        build = (params, inputs, env) -> buildfit(params, inputs, env),
        emit = (params, inputs) -> emitfit(params, inputs)),
)

function buildfit(params::AbstractDict, inputs::AbstractDict, env::BuildEnv)
    p = inputs[:in]
    column = Symbol(params["column"])
    key = paramkey(params["key"])
    fitcontext =
        params["fitcontext"] === nothing ? nothing : namedcontext(env, params["fitcontext"])
    family = params["family"]
    if family == "arma"
        params["order"] === nothing && throw(ArgumentError("an arma fit needs order"))
        return fitports(p, FitARMA(column; armaspec(params)...), fitcontext, key)
    elseif family == "ar"
        order = params["p"]
        order === nothing && throw(ArgumentError("an ar fit needs p"))
        lagcols = lagnames(Symbol(column, :_lag), order)
        lagged = p |> lags(column, order; key)
        ports = fitports(lagged,
            LinearRegression(collect(lagcols), column; name = :ar), fitcontext, key)
        return (; model = ports.model, insample = ports.insample |> dropcolumns(lagcols...))
    end
    predictors = paramcolumns(params["predictors"])
    isempty(predictors) && throw(ArgumentError("an mlj fit needs predictors"))
    model = requiredcode(env, params, "model")
    return fitports(p, FitModel(model, predictors, column; name = :model), fitcontext, key)
end

# The model port fits over the run's context, or once over the fit context; the
# in-sample port applies the whole-window fit to its own rows.
function fitports(p::CausalPipeline, s::Summarizer, fitcontext, key)
    model =
        fitcontext === nothing ? fitinput(s, p) |> summarize(s; key) :
        fitinput(s, p) |> fitonce(fitcontext, s; key)
    return (; model, insample = p |> Acausal.insample(s; fitcontext, key))
end

# The same two ports as script text. The summarizer is inlined into each call it
# appears in: a pipeline is a value, so constructing it twice changes nothing but
# the reading, and it keeps the script to one binding per port.
function emitfit(params::AbstractDict, inputs::AbstractDict)
    p = inputs[:in]
    column = QuoteNode(Symbol(params["column"]))
    key = emitkey(params["key"])
    fitcontext =
        params["fitcontext"] === nothing ? nothing : emitcontext(params["fitcontext"])
    family = params["family"]
    if family == "arma"
        params["order"] === nothing && throw(ArgumentError("an arma fit needs order"))
        return emitfitports(p, opcall(:FitARMA, column; emitarmaspec(params)...),
            fitcontext, key)
    elseif family == "ar"
        order = params["p"]
        order === nothing && throw(ArgumentError("an ar fit needs p"))
        lagcols = columnexprs(lagnames(Symbol(params["column"], :_lag), order))
        s = opcall(:LinearRegression, Expr(:vect, lagcols...), column;
            name = QuoteNode(:ar))
        lagged = emitpipe(p, opcall(:lags, column, order; key))
        ports = emitfitports(lagged, s, fitcontext, key)
        return (; model = ports.model,
            insample = emitpipe(ports.insample, opcall(:dropcolumns, lagcols...)))
    end
    predictors = paramcolumns(params["predictors"])
    isempty(predictors) && throw(ArgumentError("an mlj fit needs predictors"))
    s = opcall(:FitModel, emitrequiredcode(params, "model"),
        Expr(:vect, columnexprs(predictors)...), column; name = QuoteNode(:model))
    return emitfitports(p, s, fitcontext, key)
end

function emitfitports(p, s, fitcontext, key)
    input = opcall(qualified(:Loki, :fitinput), s, p)
    model =
        fitcontext === nothing ? emitpipe(input, opcall(:summarize, s; key)) :
        emitpipe(input, opcall(:fitonce, fitcontext, s; key))
    # `insample` is imported by name at the top of the script, which is where the
    # acausal dependence is meant to be visible.
    return (; model, insample = emitpipe(p, opcall(:insample, s; fitcontext, key)))
end
