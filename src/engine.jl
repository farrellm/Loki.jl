# The engine: the result cache, and runs — evaluating watched ports on a worker
# task, chunk by chunk, with progress, cancellation and attributed errors.

# --- the cache ---------------------------------------------------------------------

const CacheKey = Tuple{String,Symbol,UInt,Context}

mutable struct CacheEntry
    const frame::CausalFrame
    const bytes::Int
    used::Int
end

# Loaded frames by (node, port, upstream hash, context), under a byte budget,
# evicting the least recently used first.
mutable struct ResultCache
    const entries::Dict{CacheKey,CacheEntry}
    const budget::Int
    bytes::Int
    clock::Int
end

ResultCache(budget::Integer) = ResultCache(Dict{CacheKey,CacheEntry}(), Int(budget), 0, 0)

function cacheget(cache::ResultCache, key)
    entry = get(cache.entries, key, nothing)
    entry === nothing && return nothing
    entry.used = (cache.clock += 1)
    return entry.frame
end

function cacheput!(cache::ResultCache, key, frame::CausalFrame)
    cachedrop!(cache, k -> k == key)
    bytes = Base.summarysize(frame)
    cache.entries[key] = CacheEntry(frame, bytes, (cache.clock += 1))
    cache.bytes += bytes
    while cache.bytes > cache.budget && length(cache.entries) > 1
        oldest = argmin(k -> k == key ? typemax(Int) : cache.entries[k].used,
            collect(keys(cache.entries)))
        oldest == key && break
        cachedrop!(cache, ==(oldest))
    end
    return frame
end

function cachedrop!(cache::ResultCache, pred)
    for k in collect(keys(cache.entries))
        pred(k) || continue
        cache.bytes -= cache.entries[k].bytes
        delete!(cache.entries, k)
    end
    return cache
end

# --- runs --------------------------------------------------------------------------

"""
    Loki.Run

A run started by [`Loki.run!`](@ref): the watched `targets` (node id, port), the
worker `task`, and a cancellation flag checked between chunks. `wait(run)` blocks
until it has finished, been cancelled, or failed; its outcome is recorded on the
session — see [`Loki.status`](@ref) and [`Loki.result`](@ref).
"""
mutable struct Run
    const targets::Vector{Tuple{String,Symbol}}
    const cancelled::Threads.Atomic{Bool}
    task::Union{Nothing,Task}
    # Captured on the requesting task. A scoped value is inherited by a task
    # started inside its scope, but the worker outlives the request, so the
    # origin is carried rather than read again from the worker.
    const origin::Symbol
    # The last time each target reported progress, so a fast pipeline does not
    # flood a socket with one event per chunk.
    const lastprogress::Dict{Tuple{String,Symbol},Float64}
end

Run(targets::Vector{Tuple{String,Symbol}}, cancelled::Threads.Atomic{Bool},
    task::Union{Nothing,Task}; origin::Symbol = :repl) =
    Run(targets, cancelled, task, origin, Dict{Tuple{String,Symbol},Float64}())

# At most one progress event per target per this many seconds. There is no final
# flush: a target's true row count arrives with its `result_ready`, and the run's
# end with `run_progress` "done".
const PROGRESSINTERVAL = 0.1

function Base.wait(run::Run)
    run.task === nothing || wait(run.task)
    return run
end

struct Job
    id::String
    port::Symbol
    hash::UInt
    pipeline::CausalPipeline
end
