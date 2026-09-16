# API

```@docs
Loki
Loki.Acausal
```

## Time-series operators

```@docs
Lags
lags
difference
logtransform
boxcox
EMA
ema
macd
ar
```

## ARMA

```@docs
FitARMA
FittedARMA
ARMAFilter
fitarma
applyarma
arma
fitonce
```

## In-sample fits

```@docs
Loki.Acausal.insample
Loki.applyfit
Loki.fitinput
```

## Node kinds

```@docs
Loki.NodeKind
Loki.OpKind
Loki.Port
Loki.Param
Loki.inputs
Loki.outputs
Loki.paramschema
Loki.validateparams
Loki.checkparams
Loki.build
Loki.isacausal
Loki.iswrite
Loki.register_nodekind!
Loki.nodekind
Loki.nodekinds
```

## Diagnostics

```@docs
Loki.DiagnosticResult
Loki.seriesplot
Loki.preview
Loki.columnvectors
Loki.keyvalues
Loki.lttb
```

### Correlation and tests

```@docs
acf
pacf
ljungbox
adftest
Loki.armadof
```

### Distribution

```@docs
Loki.histogram
Loki.qqplot
```

### Fits and residuals

```@docs
fitreport
forecastfan
Loki.residuals
```

### Running one by name

```@docs
Loki.diagnostic
Loki.diagnostics
```

## Events

```@docs
Loki.Event
Loki.Subscriber
Loki.subscribe!
Loki.unsubscribe!
Loki.nextevent
Loki.emit!
Loki.eventjson
Loki.withorigin
Loki.currentorigin
```

## Server

```@docs
serve
Loki.Server
Loki.stop!
Loki.server
Loki.port
Loki.token
Loki.weburl
Loki.graphjson
Loki.nodecalls
```

## Export

```@docs
exportjulia
Loki.emit
Loki.canemit
Loki.Code
Loki.exprstring
Loki.TableFile
Loki.savetable
Loki.loadtable
```

## Persistence

```@docs
Loki.savesession
Loki.opensession
Loki.opensession!
Loki.reset!
```

## User code

```@docs
Loki.UserCode
Loki.setprelude!
Loki.evalcode
Loki.BuildEnv
```

## Graph

```@docs
Loki.Graph
Loki.Node
Loki.Edge
Loki.addnode!
Loki.setparams!
Loki.removenode!
Loki.setposition!
Loki.connect!
Loki.disconnect!
Loki.inedges
Loki.ancestors
Loki.topoorder
Loki.taint
```

## Session and engine

```@docs
Loki.Session
Loki.setcontext!
Loki.addtable!
Loki.run!
Loki.Run
Loki.cancel!
Loki.status
Loki.nodeerror
Loki.result
Loki.write!
Loki.freeze!
Loki.NodeError
Loki.tagged
Loki.cachedsource
```
