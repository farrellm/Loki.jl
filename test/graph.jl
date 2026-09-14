@testset "registry" begin
    @test_throws ArgumentError Loki.Param("x", :nonsense)
    @test_throws ArgumentError Loki.Param("x", :enum)
    nobuild = (params, inputs, env) -> nothing
    @test_throws ArgumentError Loki.OpKind("bad"; category = "test", build = nobuild,
        outputs = Symbol[])
    @test_throws ArgumentError Loki.OpKind("bad"; category = "test", build = nobuild,
        acausal = [:elsewhere])

    source = Loki.register_nodekind!(
        Loki.OpKind("test_source"; category = "test",
            doc = "A small table.",
            params = [
                Loki.Param("rows", :integer; default = 3, description = "row count"),
                Loki.Param("mode", :enum; choices = ["a", "b"], default = "a"),
                Loki.Param("cols", :columns),
                Loki.Param("expr", :code),
                Loki.Param("weights", :integers),
            ],
            build = (params, inputs, env) -> (;
                out = readtable((time = collect(1:params["rows"]),
                    x = collect(1.0:params["rows"])))),
        ),
    )
    Loki.register_nodekind!(
        Loki.OpKind("test_map"; category = "test",
            inputs = [Loki.Port(:in)],
            build = (params, inputs, env) -> (; out = inputs[:in])),
    )
    Loki.register_nodekind!(
        Loki.OpKind("test_required"; category = "test",
            params = [Loki.Param("column", :column; required = true)],
            build = (params, inputs, env) -> (; out = emptyframe())),
    )
    Loki.register_nodekind!(
        Loki.OpKind("test_merge"; category = "test",
            inputs = [Loki.Port(:in; variadic = true)],
            build = (params, inputs, env) -> (; out = merge(inputs[:in]...))),
    )
    Loki.register_nodekind!(
        Loki.OpKind("test_fit"; category = "test",
            inputs = [Loki.Port(:in)], outputs = [:model, :insample], acausal = [:insample],
            build = (params, inputs, env) ->
                (; model = inputs[:in], insample = inputs[:in])),
    )
    Loki.register_nodekind!(
        Loki.OpKind("test_badbuild"; category = "test",
            build = (params, inputs, env) -> (; wrong = emptyframe())),
    )

    @test Loki.nodekind("test_source") === source
    @test "test_source" in Loki.nodekinds()
    @test issorted(Loki.nodekinds())
    @test_throws ArgumentError Loki.nodekind("no_such_kind")

    params = Loki.validateparams(source, Dict(:rows => 5, "cols" => ["a", "b"]))
    @test params["rows"] == 5
    @test params["mode"] == "a"
    @test params["expr"] === nothing
    @test_throws ArgumentError Loki.validateparams(source, Dict("rows" => "three"))
    @test_throws ArgumentError Loki.validateparams(source, Dict("rows" => true))
    @test_throws ArgumentError Loki.validateparams(source, Dict("mode" => "c"))
    @test_throws ArgumentError Loki.validateparams(source, Dict("cols" => [1]))
    @test_throws ArgumentError Loki.validateparams(source, Dict("weights" => [1.5]))
    @test_throws ArgumentError Loki.validateparams(source, Dict("bogus" => 1))
    @test Loki.validateparams(source, Dict("cols" => "a", "expr" => 2.5))["expr"] == 2.5
    @test_throws ArgumentError Loki.validateparams(Loki.nodekind("test_required"),
        Dict{String,Any}())

    schema = Loki.paramschema(source)
    @test schema["type"] == "object"
    @test schema["additionalProperties"] == false
    @test schema["properties"]["rows"] ==
          Dict("type" => "integer", "default" => 3, "description" => "row count")
    @test schema["properties"]["mode"]["enum"] == ["a", "b"]
    @test schema["properties"]["expr"]["x-loki"] == "code"
    @test Loki.paramschema(Loki.nodekind("test_required"))["required"] == ["column"]

    built = Loki.build(source, Dict("rows" => 2), Dict{Symbol,Any}(), nothing)
    @test keys(built) == (:out,)
    @test DataFrame(load(Context(0, 10), built.out)).x == [1.0, 2.0]
    @test_throws ArgumentError Loki.build(Loki.nodekind("test_badbuild"),
        Dict{String,Any}(), Dict{Symbol,Any}(), nothing)
    @test Loki.isacausal(Loki.nodekind("test_fit"), Dict(), :insample)
    @test !Loki.isacausal(Loki.nodekind("test_fit"), Dict(), :model)
    @test !Loki.iswrite(source)
end

@testset "graph" begin
    g = Loki.Graph()
    s = Loki.addnode!(g, "test_source"; position = (10, 20))
    @test s == "n1"
    @test g.nodes[s].position == (10.0, 20.0)
    @test_throws ArgumentError Loki.addnode!(g, "no_such_kind")
    @test_throws ArgumentError Loki.addnode!(g, "test_source"; id = s)
    @test_throws ArgumentError Loki.addnode!(g, "test_source", Dict("rows" => "x"))
    @test_throws ArgumentError Loki.addnode!(g, "test_required")
    @test length(g.nodes) == 1

    m = Loki.addnode!(g, "test_map"; id = "map")
    e1 = Loki.connect!(g, (s, :out), (m, "in"))
    @test g.edges[1] == Loki.Edge(e1, (s, :out), (m, :in))
    @test_throws ArgumentError Loki.connect!(g, (s, :out), (m, :in))      # arity
    @test_throws ArgumentError Loki.connect!(g, (s, :nope), (m, :in))     # no output
    @test_throws ArgumentError Loki.connect!(g, (s, :out), (s, :in))      # no input
    @test_throws ArgumentError Loki.connect!(g, (m, :out), (m, :in))      # self
    @test_throws ArgumentError Loki.connect!(g, ("ghost", :out), (m, :in))

    # A variadic port keeps connection order; a cycle through it is rejected.
    s2 = Loki.addnode!(g, "test_source")
    mg = Loki.addnode!(g, "test_merge")
    Loki.connect!(g, (s2, :out), (mg, :in))
    Loki.connect!(g, (m, :out), (mg, :in))
    Loki.connect!(g, (s, :out), (mg, :in))
    @test [e.from[1] for e in Loki.inedges(g, mg)] == [s2, m, s]
    after = Loki.addnode!(g, "test_map")
    Loki.connect!(g, (mg, :out), (after, :in))
    @test_throws ArgumentError Loki.connect!(g, (after, :out), (mg, :in))
    @test Loki.ancestors(g, after) == Set([s, s2, m, mg])
    @test Loki.descendants(g, s) == Set([m, mg, after])
    @test length(Loki.outedges(g, s)) == 2

    order = Loki.topoorder(g)
    @test sort(order) == sort(g.order)
    position = Dict(id => i for (i, id) in enumerate(order))
    @test all(e -> position[e.from[1]] < position[e.to[1]], g.edges)

    # Taint starts at an acausal port and flows downstream only from it.
    fit = Loki.addnode!(g, "test_fit")
    Loki.connect!(g, (s, :out), (fit, :in))
    frommodel = Loki.addnode!(g, "test_map")
    frominsample = Loki.addnode!(g, "test_map")
    Loki.connect!(g, (fit, :model), (frommodel, :in))
    Loki.connect!(g, (fit, :insample), (frominsample, :in))
    t = Loki.taint(g)
    @test !t[(fit, :model)]
    @test t[(fit, :insample)]
    @test !t[(frommodel, :out)]
    @test t[(frominsample, :out)]
    @test !t[(after, :out)]

    Loki.setparams!(g, s, Dict("rows" => 7))
    @test g.nodes[s].params == Dict("rows" => 7)
    @test_throws ArgumentError Loki.setparams!(g, s, Dict("rows" => -1.5))
    Loki.setposition!(g, s, (1, 2))
    @test g.nodes[s].position == (1.0, 2.0)

    edge = only(Loki.inedges(g, frominsample)).id
    Loki.disconnect!(g, edge)
    @test isempty(Loki.inedges(g, frominsample))
    @test_throws ArgumentError Loki.disconnect!(g, edge)

    Loki.removenode!(g, mg)
    @test !haskey(g.nodes, mg)
    @test mg ∉ g.order
    @test all(e -> e.from[1] != mg && e.to[1] != mg, g.edges)
    @test_throws ArgumentError Loki.removenode!(g, mg)
    # Freed ids are not reused.
    @test Loki.addnode!(g, "test_source") ∉ (s, s2, m, mg, after, fit)
end
