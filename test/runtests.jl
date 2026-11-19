using Test
using Random
using JuliaBenchmarksExamples

@testset "type stability patterns agree" begin
    events = PaymentEvent[Refund(400) for _ in 1:10_000]
    refunds = Refund[Refund(400) for _ in 1:10_000]
    @test total_untyped(events) == total_typed(refunds) == 4_000_000
end

@testset "global and const paths agree" begin
    @test convert_to_usd_global(123.45, :eur) ≈ convert_to_usd_const(123.45, :eur)
    @test convert_many_global(10_000) ≈ convert_many_const(10_000)
end

@testset "row copies and views agree" begin
    Random.seed!(1)
    matrix = rand(100, 8)
    @test row_means_copy(matrix) ≈ row_means_views(matrix)
    @test length(col_means_views(matrix)) == size(matrix, 2)
end

@testset "threaded counters agree with serial" begin
    Random.seed!(2)
    xs = rand(Int32(-10):Int32(10), 200_000)
    expected = count_above_serial(xs, Int32(0))
    @test count_above_threaded(xs, Int32(0)) == expected
    @test count_above_threaded_padded(xs, Int32(0)) == expected
    @test count_above_spawn(xs, Int32(0)) == expected
end
