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
Loki.build
Loki.isacausal
Loki.iswrite
Loki.register_nodekind!
Loki.nodekind
Loki.nodekinds
```

## Graph

```@docs
Loki.Graph
Loki.Node
Loki.Edge
Loki.addnode!
Loki.setparams!
Loki.setposition!
Loki.removenode!
Loki.connect!
Loki.disconnect!
Loki.inedges
Loki.ancestors
Loki.topoorder
Loki.taint
```
