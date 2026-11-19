# Julia Benchmarks: Performance Patterns, Not Myths

Reproducible microbenchmarks for the patterns in
[Julia Best Practices for Faster Code](https://sesamedisk.com/high-performance-julia-coding/).

The goal is not to prove "Julia is fast." It is to measure which structural change
actually moved the number, and which popular fix did not.

## What this measures

| Case | Slow variant | Fast variant | What changes |
|---|---|---|---|
| `type_stability` | `Vector{PaymentEvent}` | `Vector{Refund}` | Abstract container element type vs concrete element type |
| `const_global` | Non-const global + untyped args | `const` global + typed args | Global binding and argument types |
| `slice_vs_view` | `m[i, :]` copy | `@view m[i, :]` | Copying a row slice vs viewing it |
| `threads` | Serial accumulation | `@spawn` chunks | One thread vs four threads with private counters |

The thread case also measures the two common "fixes": adjacent per-thread counters
(false sharing) and cache-line-padded counters.

## Results: Julia 1.13.3, 4 threads

Machine: `skylake-avx512`, 8 CPU threads, Linux x86_64. BenchmarkTools 1.8.0.
Each entry is the minimum of 20 samples, 1 second target per sample.

| Case | Variant | Min time | Allocations | Speedup |
|---|---|---:|---:|---:|
| `type_stability` | `Vector{PaymentEvent}` | 10.08 ms | 199,999 | 1.00x |
| `type_stability` | `Vector{Refund}` | 0.050 ms | 0 | **201.25x** |
| `const_global` | non-const untyped | 16.80 ms | 800,000 | 1.00x |
| `const_global` | `const` typed | 1.30 ms | 0 | **12.97x** |
| `slice_vs_view` | copy row slice | 1.13 ms | 8,003 | 1.00x |
| `slice_vs_view` | view row slice | 0.71 ms | 3 | **1.60x** |
| `slice_vs_view` | view column | 0.081 ms | 2 | 13.93x* |
| `threads` | serial | 1.59 ms | 0 | 1.00x |
| `threads` | false sharing | 13.08 ms | 25 | **0.12x** |
| `threads` | padded counters | 10.27 ms | 25 | **0.16x** |
| `threads` | spawn + chunk | 0.478 ms | 115 | **3.33x** |

\* The column-view row is not the same operation as row means; it measures the
column-major memory layout, not "views are always faster."

### What the numbers say

- **Type stability dominates.** The abstract vector did the same arithmetic with
  the same number of elements, but paid 199,999 allocations and was 201x slower.
  The loop body was not the problem; the container type was.
- **Non-const globals are expensive even in a tiny function.** 200,000 conversions
  allocated 800,000 times on the slow path. The `const` + typed version allocated
  nothing.
- **`@views` is not a magic speed button.** Row views helped 1.60x because they
  removed 8,000 allocations, but the row is still strided. Iterating down columns
  was another 14x faster. Measure the access pattern, not just the allocation count.
- **False sharing is real, and padding alone may not rescue it.** Adjacent counters
  were 8.2x slower than serial. Padding improved that to 6.4x slower than serial.
  On this memory-bound loop, the scheduler and 64-byte writes still cost more than
  the parallel gain. Chunked `@spawn` with private counters won at 3.33x.
- **The lesson is not "always use threads."** It is "measure the thread topology
  and the reduction strategy, not just `Threads.@threads`." For short or
  memory-bound loops, serial can win.

Ratios move by roughly 10–30% between runs. The CSV is the source of truth; the
table is one run.

## Cross-version comparison: Julia 1.13.3 vs 1.10.12

Same machine, same 4-thread setting, same BenchmarkTools 1.8.0. Speedup is
relative to that version's slow variant.

| Case | Variant | 1.13.3 | 1.10.12 | Note |
|---|---|---:|---:|---|
| `type_stability` | `Vector{Refund}` vs abstract | 201.25x | 226.67x | Both allocate 0 on the fast path; the fast path itself got slower in 1.13 on this loop |
| `const_global` | `const` typed | 12.97x | 14.93x | Stable result |
| `slice_vs_view` | view row slice | 1.60x | 2.61x | Row views still trail column access |
| `slice_vs_view` | view column | 13.93x | 10.19x | Layout effect, not a `@views` effect |
| `threads` | false sharing | 0.12x | 0.19x | Slower than serial in both versions |
| `threads` | padded counters | 0.16x | 0.22x | Padding helps vs false sharing, still loses to serial here |
| `threads` | spawn + chunk | 3.33x | 4.66x | The only threaded variant that beat serial |

Do not read the version column as a general "1.13 is slower/faster" claim. This
is one microbenchmark on one machine; the ratios are the useful part.

## Reproduce

Requires Julia 1.10 or newer.

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. --threads=4 scripts/run_benchmarks.jl
```

Run the second version and append it to the same CSV:

```bash
julia --project=. --threads=4 scripts/run_benchmarks.jl --append
```

The runner writes:

- `results/results.csv` — one row per variant, with version and thread count
- `results/machine-<version>-<n>t.txt` — CPU, Julia commit, and tool versions

Run the correctness tests first:

```bash
julia --project=. --threads=4 -e 'using Pkg; Pkg.test()'
```

## Repo layout

```text
src/JuliaBenchmarksExamples.jl   benchmark functions and correctness-preserving variants
scripts/run_benchmarks.jl        BenchmarkTools runner and CSV writer
test/runtests.jl                 correctness tests for every variant
results/                         generated CSV and machine info
```

## Caveats

- These are microbenchmarks, not a Julia vs Python comparison.
- Absolute times are machine-specific; use the ratios and allocation counts.
- `@benchmark` reports the minimum by default; that is deliberate for comparing
  code paths, not for predicting production latency.
- The thread results depend on core count, scheduler, memory bandwidth, and
  workload size. Re-run on the machine you deploy to.
- The abstract-vector case has one allocation per element because the element
  type is not concrete. That is the point of the example, not a tuning artifact.

## License

MIT. See [LICENSE](LICENSE).
