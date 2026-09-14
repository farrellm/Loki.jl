# Shared test helpers.

# A source serving `df`'s in-window rows in chunks of `n` rows, so every operator
# can be run over the same data at several chunk boundaries.
function chunksource(df::DataFrame, n::Integer)
    return CausalPipeline() do ctx::Context
        rows = findall(t -> ctx.start <= t < ctx.stop, df.time)
        return (df[rows[i:min(i+n-1, end)], :] for i in 1:n:length(rows))
    end
end

# The streaming property: concatenating `stream(ctx, p)` equals `load(ctx, p)`,
# and neither depends on where the source's chunks break. `build(src)` wraps a
# source in the pipeline under test. Returns the loaded DataFrame.
function streamequalsload(build, ctx::Context, df::DataFrame; sizes = (1, 3, 7, 1000))
    reference = DataFrame(load(ctx, build(chunksource(df, first(sizes)))))
    for n in sizes
        p = build(chunksource(df, n))
        @test isequal(DataFrame(load(ctx, p)), reference)
        streamed = reduce(vcat, [DataFrame(f) for f in stream(ctx, p)])
        @test isequal(streamed, reference)
    end
    return reference
end
