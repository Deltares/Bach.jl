using Ribasim
using Dates
using Configurations: UndefKeywordError
using OrdinaryDiffEq: alg_autodiff

@testset "config" begin
    config = Ribasim.parsefile(joinpath(@__DIR__, "testrun.toml"))
    @test config isa Ribasim.Config
    @test config.update_timestep == 86400.0
    @test config.endtime > config.starttime
    @test config.solver ==
          Ribasim.Solver("QNDF", false, 86400.0, 0, 1.0e-6, 0.001, Int(1e9))

    @test_throws UndefKeywordError Ribasim.Config()
    @test_throws UndefKeywordError Ribasim.Config(
        startime = now(),
        endtime = now(),
        geopackage = "",
        foo = "bar",
    )
end

@testset "Solver" begin
    @test Ribasim.Solver() ==
          Ribasim.Solver("QNDF", false, Float64[], 0, 1.0e-6, 0.001, Int(1e9))
    @test Ribasim.Solver(;
        algorithm = "Rosenbrock23",
        autodiff = true,
        saveat = 3600.0,
        dt = 0,
        abstol = 1e-5,
        reltol = 1e-4,
        maxiters = 1e5,
    ) == Ribasim.Solver("Rosenbrock23", true, 3600.0, 0, 1e-5, 1e-4, 1e5)
    Ribasim.Solver(; algorithm = "DoesntExist")
    @test_throws InexactError Ribasim.Solver(autodiff = 2)
    @test_throws "algorithm DoesntExist not supported" Ribasim.algorithm(
        Ribasim.Solver(; algorithm = "DoesntExist"),
    )
    @test alg_autodiff(
        Ribasim.algorithm(Ribasim.Solver(; algorithm = "QNDF", autodiff = true)),
    )
    @test !alg_autodiff(
        Ribasim.algorithm(Ribasim.Solver(; algorithm = "QNDF", autodiff = false)),
    )
    @test !alg_autodiff(Ribasim.algorithm(Ribasim.Solver(; algorithm = "QNDF")))
    # autodiff is not a kwargs for explicit algorithms, but we use try-catch to bypass
    Ribasim.algorithm(Ribasim.Solver(; algorithm = "Euler", autodiff = true))
end
