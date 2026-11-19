module JuliaBenchmarksExamples

"""
    LedgerEntry

A concrete struct used to show that element type matters more than the loop body.
"""
struct LedgerEntry
    account_id::Int32
    amount_cents::Int64
    posted_at::Float64
end

"""Sum `amount_cents` over concrete `LedgerEntry` values."""
function net_balance(entries::Vector{LedgerEntry})
    total = 0.0
    for entry in entries
        total += entry.amount_cents
    end
    return total
end

abstract type PaymentEvent end

struct CardCharge <: PaymentEvent
    amount_cents::Int64
end

struct Refund <: PaymentEvent
    amount_cents::Int64
end

"""
    total_untyped(events::Vector{PaymentEvent})

The element type is abstract, so field access is resolved at runtime.
"""
function total_untyped(events::Vector{PaymentEvent})
    total = 0
    for event in events
        total += event.amount_cents
    end
    return total
end

"""Same loop over a concrete `Vector{Refund}`."""
function total_typed(events::Vector{Refund})
    total = 0
    for event in events
        total += event.amount_cents
    end
    return total
end

# Deliberately non-const and untyped arguments: the slow path.
exchange_rates = Dict{Symbol, Float64}(:usd => 1.0, :eur => 1.087, :gbp => 1.271)

# Const binding and concrete arguments: the fast path.
const EXCHANGE_RATES = Dict{Symbol, Float64}(:usd => 1.0, :eur => 1.087, :gbp => 1.271)

convert_to_usd_global(amount, currency) = amount * exchange_rates[currency]
convert_to_usd_const(amount::Float64, currency::Symbol) = amount * EXCHANGE_RATES[currency]

function convert_many_global(n::Int)
    total = 0.0
    for _ in 1:n
        total += convert_to_usd_global(123.45, :eur)
    end
    return total
end

function convert_many_const(n::Int)
    total = 0.0
    for _ in 1:n
        total += convert_to_usd_const(123.45, :eur)
    end
    return total
end

"""Row means with a copying slice (`m[i, :]`)."""
function row_means_copy(m::Matrix{Float64})
    return [sum(m[i, :]) / size(m, 2) for i in axes(m, 1)]
end

"""Row means with `@view`; no copy, but rows are strided in column-major Julia."""
function row_means_views(m::Matrix{Float64})
    return [sum(@view m[i, :]) / size(m, 2) for i in axes(m, 1)]
end

"""Column means with `@view`; contiguous access in column-major Julia."""
function col_means_views(m::Matrix{Float64})
    return [sum(@view m[:, j]) / size(m, 1) for j in axes(m, 2)]
end

function count_above_serial(xs::Vector{Int32}, threshold::Int32)
    count = 0
    @inbounds for x in xs
        count += (x > threshold)
    end
    return count
end

"""
    count_above_threaded(xs, threshold)

Race-free with `:static`, but adjacent `Int` counters share cache lines.
"""
function count_above_threaded(xs::Vector{Int32}, threshold::Int32)
    partials = zeros(Int, Threads.maxthreadid())
    Threads.@threads :static for i in eachindex(xs)
        if xs[i] > threshold
            partials[Threads.threadid()] += 1
        end
    end
    return sum(partials)
end

"""
    PaddedCounter

An `Int` plus 56 bytes of padding: one counter per 64-byte cache line.
"""
struct PaddedCounter
    value::Int
    pad::NTuple{7, Int}
end

"""Same `:static` loop, but counters are padded to avoid false sharing."""
function count_above_threaded_padded(xs::Vector{Int32}, threshold::Int32)
    counters = [PaddedCounter(0, ntuple(_ -> 0, 7)) for _ in 1:Threads.maxthreadid()]
    Threads.@threads :static for i in eachindex(xs)
        if xs[i] > threshold
            tid = Threads.threadid()
            current = counters[tid]
            counters[tid] = PaddedCounter(current.value + 1, current.pad)
        end
    end
    return sum(counter.value for counter in counters)
end

"""Chunked `@spawn`: each task owns a private counter and returns it."""
function count_above_spawn(xs::Vector{Int32}, threshold::Int32; nchunks::Int = 4 * Threads.nthreads())
    n = length(xs)
    chunk = cld(n, nchunks)
    tasks = Task[]
    for lo in 1:chunk:n
        hi = min(lo + chunk - 1, n)
        push!(tasks, Threads.@spawn begin
            count = 0
            @inbounds for i in lo:hi
                count += (xs[i] > threshold)
            end
            count
        end)
    end
    return sum(fetch, tasks)
end

export LedgerEntry, net_balance
export PaymentEvent, CardCharge, Refund, total_untyped, total_typed
export exchange_rates, EXCHANGE_RATES, convert_to_usd_global, convert_to_usd_const
export convert_many_global, convert_many_const
export row_means_copy, row_means_views, col_means_views
export count_above_serial, count_above_threaded, count_above_threaded_padded, count_above_spawn

end
