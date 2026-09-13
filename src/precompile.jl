# Precompile what CausalFrames' own workload cannot: its parquet operators live
# in extensions behind weak dependencies there, but Loki loads both backends,
# so the round trip through each can be compiled here. Loki's own operators
# join this workload as they are added.
@setup_workload begin
    dir = mktempdir()
    table = (time = [1, 2, 3], x = [1.0, 2.0, 3.0])
    @compile_workload begin
        ctx = Context(0, 10)
        for backend in (:parquet2, :duckdb)
            path = joinpath(dir, "precompile-$backend.parquet")
            scan(ctx, readtable(table) |> writeparquet(path; backend))
            load(ctx, readparquet(path; backend))
        end
    end
end
