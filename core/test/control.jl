import Ribasim
using Dates: Date

@testset "Pump discrete control" begin
    toml_path =
        normpath(@__DIR__, "../../data/pump_discrete_control/pump_discrete_control.toml")
    @test ispath(toml_path)
    model = Ribasim.run(toml_path)
    p = model.integrator.p
    (; discrete_control) = p

    # Control input
    pump_control_mapping = p.pump.control_mapping
    @test pump_control_mapping[(4, "off")].flow_rate == 0
    @test pump_control_mapping[(4, "on")].flow_rate == 1.0e-5

    logic_mapping::Dict{Tuple{Int, String}, String} =
        Dict((5, "TT") => "on", (5, "TF") => "off", (5, "FF") => "on", (5, "FT") => "off")

    @test discrete_control.logic_mapping == logic_mapping

    # Control result
    @test discrete_control.record.truth_state == ["TF", "FF", "FT"]
    @test discrete_control.record.control_state == ["off", "on", "off"]

    level = Ribasim.get_storages_and_levels(model).level
    timesteps = Ribasim.timesteps(model)

    # Control times
    t_1 = discrete_control.record.time[2]
    t_1_index = findfirst(timesteps .≈ t_1)
    @test level[1, t_1_index] ≈ discrete_control.greater_than[1]

    t_2 = discrete_control.record.time[3]
    t_2_index = findfirst(timesteps .≈ t_2)
    @test level[2, t_2_index] ≈ discrete_control.greater_than[2]
end

@testset "Flow condition control" begin
    toml_path = normpath(@__DIR__, "../../data/flow_condition/flow_condition.toml")
    @test ispath(toml_path)
    model = Ribasim.run(toml_path)
    p = model.integrator.p
    (; discrete_control) = p

    timesteps = Ribasim.timesteps(model)
    t_control = discrete_control.record.time[2]
    t_control_index = searchsortedfirst(timesteps, t_control)

    greater_than = discrete_control.greater_than[1]
    flow_t_control = model.saved_flow.saveval[t_control_index][1]

    @test isapprox(flow_t_control, greater_than, rtol = 0.005)
end

@testset "PID control" begin
    toml_path = normpath(@__DIR__, "../../data/pid_control/pid_control.toml")
    @test ispath(toml_path)
    model = Ribasim.run(toml_path)
    p = model.integrator.p
    (; basin, pid_control, flow_boundary) = p

    storage = Ribasim.get_storages_and_levels(model).storage[1, :]
    timesteps = Ribasim.timesteps(model)

    K_p = pid_control.proportional[2]
    K_i = pid_control.integral[2]
    A = basin.area[1][1]
    target_level = basin.target_level[1]
    initial_storage = storage[1]
    flow_rate = flow_boundary.flow_rate[1].u[1]
    du0 = flow_rate + K_p * (target_level - initial_storage / A)
    target_storage = A * target_level
    Δstorage = initial_storage - target_storage
    alpha = -K_p / (2 * A)
    omega = sqrt(4 * K_i / A - (K_i / A)^2) / 2
    phi = atan(du0 / Δstorage - alpha) / omega
    a = abs(Δstorage / cos(phi))
    # This bound is the exact envelope of the analytical solution
    bound = @. a * exp(alpha * timesteps)
    eps = 3.0

    @test all((storage .- target_storage) .< bound .+ eps)
end

@testset "TabulatedRatingCurve control" begin
    toml_path = normpath(
        @__DIR__,
        "../../data/tabulated_rating_curve_control/tabulated_rating_curve_control.toml",
    )
    @test ispath(toml_path)
    model = Ribasim.run(toml_path)
    p = model.integrator.p
    (; discrete_control) = p
    # it takes some months to fill the Basin above 0.5 m
    # with the initial "high" control_state
    @test discrete_control.record.control_state == ["high", "low"]
    @test discrete_control.record.time[1] == 0.0
    t = Ribasim.datetime_since(discrete_control.record.time[2], model.config.starttime)
    @test Date(t) == Date("2020-03-15")
    # then the rating curve is updated to the "low" control_state
    @test only(p.tabulated_rating_curve.tables).t[2] == 1.2
end

@testset "Setpoint with bounds control" begin
    toml_path = normpath(
        @__DIR__,
        "../../data/level_setpoint_with_minmax/level_setpoint_with_minmax.toml",
    )
    @test ispath(toml_path)
    model = Ribasim.run(toml_path)
    p = model.integrator.p
    (; discrete_control) = p
    (; record, greater_than) = discrete_control
    level = Ribasim.get_storages_and_levels(model).level[1, :]
    timesteps = Ribasim.timesteps(model)

    t_none_1 = discrete_control.record.time[2]
    t_in = discrete_control.record.time[3]
    t_none_2 = discrete_control.record.time[4]

    level_min = greater_than[1]
    setpoint = greater_than[2]

    t_1_none_index = findfirst(timesteps .≈ t_none_1)
    t_in_index = findfirst(timesteps .≈ t_in)
    t_2_none_index = findfirst(timesteps .≈ t_none_2)

    @test record.control_state == ["out", "none", "in", "none"]
    @test level[t_1_none_index] ≈ setpoint
    @test level[t_in_index] ≈ level_min
    @test level[t_2_none_index] ≈ setpoint
end
