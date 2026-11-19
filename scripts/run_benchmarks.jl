#!/usr/bin/env julia
# Reproducible microbenchmarks for the patterns in the Julia performance guide.
#
# Usage:
#   julia --project=. --threads=4 scripts/run_benchmarks.jl
#   julia --project=. --threads=4 scripts/run_benchmarks.jl --append
#
# Every case compares a known-slow variant with one or more faster variants.
# The CSV contains raw timings; the console/README ratios are what matter.

using JuliaBenchmarksExamples
using BenchmarkTools
using Statistics
using Printf
using Dates
using Random

struct Row
    julia_version::String
    case::String
    variant::String
    role::String
    time_ns::Float64
    median_ns::Float64
    allocs::Int
    memory::Int
    samples::Int
end

function bench_call(f; samples::Int = 20, seconds::Float64 = 1.0)
    f() # warm up compilation and dispatch
    trial = BenchmarkTools.@benchmark $f() samples=samples seconds=seconds
    minimum_trial = minimum(trial)
    median_trial = median(trial)
    return (
        time_ns = Float64(minimum_trial.time),
        median_ns = Float64(median_trial.time),
        allocs = minimum_trial.allocs,
        memory = minimum_trial.memory,
        samples = length(trial.times),
    )
end

function add_row!(rows, case::String, variant::String, role::String, stats)
    push!(rows, Row(
        string(VERSION),
        case,
        variant,
        role,
        stats.time_ns,
        stats.median_ns,
        stats.allocs,
        stats.memory,
        stats.samples,
    ))
end

function machine_info()
    return """
    julia_version=$(VERSION)
    julia_commit=$(Base.GIT_VERSION_INFO.commit_short)
    threads=$(Threads.nthreads())
    cpu=$(Sys.CPU_NAME)
    cpu_threads=$(Sys.CPU_THREADS)
    arch=$(Sys.ARCH)
    kernel=$(Sys.KERNEL)
    machine=$(Sys.MACHINE)
    word_size=$(Sys.WORD_SIZE)
    benchmark_tools=$(pkgversion(BenchmarkTools))
    utc_started=$(Dates.now(UTC))
    """
end

function write_results(rows, out::String, append_mode::Bool)
    mkpath(dirname(out))
    write_header = !append_mode || !isfile(out)
    open(out, append_mode ? "a" : "w") do io
        if write_header
            println(io, "julia_version,case,variant,role,time_ns_min,time_ns_median,allocs,memory_bytes,samples,speedup_vs_baseline")
        end
        baselines = Dict{String, Float64}()
        for row in rows
            if row.role == "slow"
                baselines[row.case] = row.time_ns
            end
        end
        for row in rows
            speedup = get(baselines, row.case, row.time_ns) / row.time_ns
            @printf(io, "%s,%s,%s,%s,%.0f,%.0f,%d,%d,%d,%.2f\n",
                row.julia_version, row.case, row.variant, row.role,
                row.time_ns, row.median_ns, row.allocs, row.memory, row.samples, speedup)
        end
    end
end

function print_summary(rows)
    println("\nJulia $(VERSION), $(Threads.nthreads()) thread(s)\n")
    @printf("%-18s %-30s %12s %10s %8s\n", "case", "variant", "min time", "allocs", "speedup")
    println("-"^84)
    baselines = Dict{String, Float64}()
    for row in rows
        if row.role == "slow"
            baselines[row.case] = row.time_ns
        end
    end
    for row in rows
        speedup = get(baselines, row.case, row.time_ns) / row.time_ns
        @printf("%-18s %-30s %9.3f ms %10d %7.2fx\n",
            row.case, row.variant, row.time_ns / 1e6, row.allocs, speedup)
    end
end

function main()
    append_mode = "--append" in ARGS
    out = "results/results.csv"
    for arg in ARGS
        if startswith(arg, "--output=")
            out = split(arg, "="; limit = 2)[2]
        end
    end

    Random.seed!(42)
    rows = Row[]

    # 1. Abstract container element type vs concrete element type.
    n_events = 200_000
    abstract_events = PaymentEvent[Refund(400) for _ in 1:n_events]
    concrete_events = Refund[Refund(400) for _ in 1:n_events]
    @assert total_untyped(abstract_events) == total_typed(concrete_events)
    add_row!(rows, "type_stability", "Vector{PaymentEvent}", "slow",
        bench_call(() -> total_untyped(abstract_events)))
    add_row!(rows, "type_stability", "Vector{Refund}", "fast",
        bench_call(() -> total_typed(concrete_events)))

    # 2. Non-const global + untyped arguments vs const + typed arguments.
    n_conversions = 200_000
    @assert isapprox(convert_many_global(n_conversions), convert_many_const(n_conversions))
    add_row!(rows, "const_global", "non-const untyped", "slow",
        bench_call(() -> convert_many_global(n_conversions)))
    add_row!(rows, "const_global", "const typed", "fast",
        bench_call(() -> convert_many_const(n_conversions)))

    # 3. Copying row slices vs row views. Row views are not guaranteed faster:
    # Julia matrices are column-major, so rows are strided.
    matrix = rand(4_000, 64)
    @assert isapprox(row_means_copy(matrix), row_means_views(matrix))
    add_row!(rows, "slice_vs_view", "copy row slice", "slow",
        bench_call(() -> row_means_copy(matrix)))
    add_row!(rows, "slice_vs_view", "view row slice", "fast",
        bench_call(() -> row_means_views(matrix)))
    add_row!(rows, "slice_vs_view", "view column", "control",
        bench_call(() -> col_means_views(matrix)))

    # 4. Serial vs threaded accumulation. Run this script with --threads=4 (or more).
    n_values = 5_000_000
    xs = rand(Int32(-10):Int32(10), n_values)
    threshold = Int32(0)
    expected = count_above_serial(xs, threshold)
    add_row!(rows, "threads", "serial", "slow",
        bench_call(() -> count_above_serial(xs, threshold)))

    if Threads.nthreads() > 1
        @assert count_above_threaded(xs, threshold) == expected
        @assert count_above_threaded_padded(xs, threshold) == expected
        @assert count_above_spawn(xs, threshold) == expected
        add_row!(rows, "threads", "false sharing", "variant",
            bench_call(() -> count_above_threaded(xs, threshold)))
        add_row!(rows, "threads", "padded counters", "variant",
            bench_call(() -> count_above_threaded_padded(xs, threshold)))
        add_row!(rows, "threads", "spawn + chunk", "variant",
            bench_call(() -> count_above_spawn(xs, threshold)))
    else
        @warn "Running with 1 thread; skipped threaded comparisons. Re-run with --threads=4."
    end

    write_results(rows, out, append_mode)
    machine_path = joinpath(dirname(out), "machine-$(VERSION)-$(Threads.nthreads())t.txt")
    write(machine_path, machine_info())
    print_summary(rows)
    println("\nWrote $(out) and $(machine_path)")
end

main()
