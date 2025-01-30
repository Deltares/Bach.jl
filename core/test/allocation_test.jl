@testitem "Allocation solve" begin
    using Ribasim: NodeID, OptimizationType
    using ComponentArrays: ComponentVector
    import SQLite
    import JuMP

    toml_path = normpath(@__DIR__, "../../generated_testmodels/subnetwork/ribasim.toml")
    @test ispath(toml_path)
    model = Ribasim.Model(toml_path)
    p = model.integrator.p

    (; graph, allocation) = p

    allocation.mean_input_flows[1][(NodeID(:FlowBoundary, 1, p), NodeID(:Basin, 2, p))] =
        4.5
    allocation_model = p.allocation.allocation_models[1]
    (; flow) = allocation_model
    u = ComponentVector(; storage = zeros(length(p.basin.node_id)))
    t = 0.0
    Ribasim.allocate_demands!(p, allocation_model, t, u)

    # Last demand priority (= 2) flows
    @test flow[(NodeID(:Basin, 2, p), NodeID(:Pump, 5, p))] ≈ 0.0
    @test flow[(NodeID(:Basin, 2, p), NodeID(:UserDemand, 10, p))] ≈ 0.5
    @test flow[(NodeID(:Basin, 8, p), NodeID(:UserDemand, 12, p))] ≈ 3.0 rtol = 1e-5
    @test flow[(NodeID(:UserDemand, 12, p), NodeID(:Basin, 8, p))] ≈ 1.0 rtol = 1e-5
    @test flow[(NodeID(:Basin, 6, p), NodeID(:Outlet, 7, p))] ≈ 2.0 rtol = 1e-5
    @test flow[(NodeID(:FlowBoundary, 1, p), NodeID(:Basin, 2, p))] ≈ 0.5
    @test flow[(NodeID(:Basin, 6, p), NodeID(:UserDemand, 11, p))] ≈ 0.0

    (; allocated) = p.user_demand
    @test allocated[1, :] ≈ [0.0, 0.5]
    @test allocated[2, :] ≈ [4.0, 0.0]
    @test allocated[3, :] ≈ [0.0, 3.0] atol = 1e-5
end

@testitem "Allocation objective" begin
    using DataFrames: DataFrame
    using SciMLBase: successful_retcode
    using Ribasim: NodeID
    import JuMP

    toml_path =
        normpath(@__DIR__, "../../generated_testmodels/minimal_subnetwork/ribasim.toml")
    @test ispath(toml_path)

    model = Ribasim.run(toml_path)
    @test successful_retcode(model)
    (; u, p, t) = model.integrator
    (; user_demand) = p
    allocation_model = p.allocation.allocation_models[1]
    Ribasim.set_initial_values!(allocation_model, u, p, t)
    Ribasim.set_objective_demand_priority!(allocation_model, u, p, t, 1)
    objective = JuMP.objective_function(allocation_model.problem)
    @test objective isa JuMP.QuadExpr # Quadratic expression
    F = allocation_model.problem[:F]

    to_user_5 = F[(NodeID(:Basin, 4, p), NodeID(:UserDemand, 5, p))]
    to_user_6 = F[(NodeID(:Basin, 4, p), NodeID(:UserDemand, 6, p))]

    @test objective.aff.constant ≈ sum(user_demand.demand)
    @test objective.aff.terms[to_user_5] ≈ -2.0
    @test objective.aff.terms[to_user_6] ≈ -2.0
    @test objective.terms[JuMP.UnorderedPair(to_user_5, to_user_5)] ≈
          1 / user_demand.demand[1]
    @test objective.terms[JuMP.UnorderedPair(to_user_6, to_user_6)] ≈
          1 / user_demand.demand[2]
end

@testitem "main allocation network initialization" begin
    using SQLite
    using Ribasim: NodeID

    toml_path = normpath(
        @__DIR__,
        "../../generated_testmodels/main_network_with_subnetworks/ribasim.toml",
    )
    @test ispath(toml_path)
    model = Ribasim.Model(toml_path)
    p = model.integrator.p
    (; allocation, graph) = p
    (; main_network_connections, subnetwork_ids, allocation_models) = allocation
    @test Ribasim.has_main_network(allocation)
    @test Ribasim.is_main_network(first(subnetwork_ids))

    # Connections from main network to subnetworks
    @test isempty(main_network_connections[1])
    @test only(main_network_connections[2]) == (NodeID(:Basin, 2, p), NodeID(:Pump, 11, p))
    @test only(main_network_connections[3]) == (NodeID(:Basin, 6, p), NodeID(:Pump, 24, p))
    @test only(main_network_connections[4]) == (NodeID(:Basin, 10, p), NodeID(:Pump, 38, p))

    # main-sub connections are part of main network allocation network
    allocation_model_main_network = Ribasim.get_allocation_model(p, Int32(1))
    @test [
        (NodeID(:Basin, 2, p), NodeID(:Pump, 11, p)),
        (NodeID(:Basin, 6, p), NodeID(:Pump, 24, p)),
        (NodeID(:Basin, 10, p), NodeID(:Pump, 38, p)),
    ] ⊆ keys(allocation_model_main_network.capacity.data)

    # In each subnetwork, the connection from the main network to the subnetwork is
    # interpreted as a source
    @test Ribasim.get_allocation_model(p, Int32(3)).problem[:source_main_network].axes[1] ==
          [(NodeID(:Basin, 2, p), NodeID(:Pump, 11, p))]
    @test Ribasim.get_allocation_model(p, Int32(5)).problem[:source_main_network].axes[1] ==
          [(NodeID(:Basin, 6, p), NodeID(:Pump, 24, p))]
    @test Ribasim.get_allocation_model(p, Int32(7)).problem[:source_main_network].axes[1] ==
          [(NodeID(:Basin, 10, p), NodeID(:Pump, 38, p))]
end

@testitem "Allocation with main network optimization problem" begin
    using SQLite
    using Ribasim: NodeID, NodeType, OptimizationType
    using ComponentArrays: ComponentVector
    using JuMP
    using DataFrames: DataFrame, ByRow, transform!

    toml_path = normpath(
        @__DIR__,
        "../../generated_testmodels/main_network_with_subnetworks/ribasim.toml",
    )
    @test ispath(toml_path)
    model = Ribasim.Model(toml_path)

    (; p) = model.integrator
    (; allocation, user_demand, graph, basin) = p
    (;
        allocation_models,
        subnetwork_demands,
        subnetwork_allocateds,
        record_flow,
        mean_input_flows,
    ) = allocation
    t = 0.0

    # Collecting demands
    u = ComponentVector(; storage = zeros(length(basin.node_id)))
    for allocation_model in allocation_models[2:end]
        Ribasim.collect_demands!(p, allocation_model, t, u)
    end

    # See the difference between these values here and in
    # "subnetworks_with_sources"
    @test subnetwork_demands[(NodeID(:Basin, 2, p), NodeID(:Pump, 11, p))] ≈ [4.0, 4.0, 0.0] atol =
        1e-4
    @test subnetwork_demands[(NodeID(:Basin, 6, p), NodeID(:Pump, 24, p))] ≈
          [0.001, 0.0, 0.0] atol = 1e-4
    @test subnetwork_demands[(NodeID(:Basin, 10, p), NodeID(:Pump, 38, p))][1:2] ≈
          [0.001, 0.002] atol = 1e-4

    # Solving for the main network, containing subnetworks as UserDemands
    allocation_model = allocation_models[1]
    (; problem) = allocation_model
    main_source =
        allocation_model.sources[(NodeID(:FlowBoundary, 1, p), NodeID(:Basin, 2, p))]
    main_source.capacity_reduced = 4.5
    Ribasim.optimize_demand_priority!(
        allocation_model,
        u,
        p,
        t,
        1,
        OptimizationType.allocate,
    )

    # Main network objective function
    F = problem[:F]
    objective = JuMP.objective_function(problem)
    objective_edges = keys(objective.terms)
    F_1 = F[(NodeID(:Basin, 2, p), NodeID(:Pump, 11, p))]
    F_2 = F[(NodeID(:Basin, 6, p), NodeID(:Pump, 24, p))]
    F_3 = F[(NodeID(:Basin, 10, p), NodeID(:Pump, 38, p))]
    @test JuMP.UnorderedPair(F_1, F_1) ∈ objective_edges
    @test JuMP.UnorderedPair(F_2, F_2) ∈ objective_edges
    @test JuMP.UnorderedPair(F_3, F_3) ∈ objective_edges

    # Running full allocation algorithm
    (; Δt_allocation) = allocation_models[1]
    mean_input_flows[1][(NodeID(:FlowBoundary, 1, p), NodeID(:Basin, 2, p))] =
        4.5 * Δt_allocation
    Ribasim.update_allocation!(model.integrator)

    @test subnetwork_allocateds[NodeID(:Basin, 2, p), NodeID(:Pump, 11, p)] ≈
          [4, 0.49775, 0.0] atol = 1e-4
    @test subnetwork_allocateds[NodeID(:Basin, 6, p), NodeID(:Pump, 24, p)] ≈
          [0.001, 0.0, 0.0] rtol = 1e-3
    @test subnetwork_allocateds[NodeID(:Basin, 10, p), NodeID(:Pump, 38, p)] ≈
          [0.001, 0.00024888, 0.0] rtol = 1e-3

    # Test for existence of edges in allocation flow record
    allocation_flow = DataFrame(record_flow)
    transform!(
        allocation_flow,
        [:from_node_type, :from_node_id, :to_node_type, :to_node_id] =>
            ByRow(
                (a, b, c, d) ->
                    haskey(graph, NodeID(Symbol(a), b, p), NodeID(Symbol(c), d, p)),
            ) => :edge_exists,
    )
    @test all(allocation_flow.edge_exists)

    @test user_demand.allocated[2, :] ≈ [4.0, 0.0, 0.0] atol = 1e-3
    @test user_demand.allocated[7, :] ≈ [0.0, 0.0, 0.0] atol = 1e-3
end

@testitem "Subnetworks with sources" begin
    using SQLite
    using Ribasim: NodeID, OptimizationType
    using ComponentArrays: ComponentVector
    using OrdinaryDiffEqCore: get_du
    using JuMP

    toml_path = normpath(
        @__DIR__,
        "../../generated_testmodels/subnetworks_with_sources/ribasim.toml",
    )
    @test ispath(toml_path)
    model = Ribasim.Model(toml_path)
    p = model.integrator.p

    (; allocation, user_demand, graph, basin) = p
    (; allocation_models, subnetwork_demands, subnetwork_allocateds, mean_input_flows) =
        allocation
    t = 0.0

    # Set flows of sources in subnetworks
    mean_input_flows[2][(NodeID(:FlowBoundary, 58, p), NodeID(:Basin, 16, p))] = 1.0
    mean_input_flows[4][(NodeID(:FlowBoundary, 59, p), NodeID(:Basin, 44, p))] = 1e-3

    # Collecting demands
    u = ComponentVector(; storage = zeros(length(basin.node_id)))
    for allocation_model in allocation_models[2:end]
        Ribasim.collect_demands!(p, allocation_model, t, u)
    end

    # See the difference between these values here and in
    # "allocation with main network optimization problem", internal sources
    # lower the subnetwork demands
    @test subnetwork_demands[(NodeID(:Basin, 2, p), NodeID(:Pump, 11, p))] ≈ [4.0, 4.0, 0.0] rtol =
        1e-4
    @test subnetwork_demands[(NodeID(:Basin, 6, p), NodeID(:Pump, 24, p))] ≈
          [0.001, 0.0, 0.0] rtol = 1e-4
    @test subnetwork_demands[(NodeID(:Basin, 10, p), NodeID(:Pump, 38, p))][1:2] ≈
          [0.001, 0.001] rtol = 1e-4

    model = Ribasim.run(toml_path)
    (; u, p, t) = model.integrator
    (; current_storage) = p.basin.current_properties
    current_storage = current_storage[Float64[]]
    du = get_du(model.integrator)
    Ribasim.formulate_storages!(current_storage, du, u, p, t)

    @test current_storage ≈ Float32[
        1.0346908f6,
        1.03469f6,
        1.0346894f6,
        1.034689f6,
        1.0346888f6,
        13.833241,
        40.109993,
        187761.73,
        4641.365,
        2402.6687,
        6.039952,
        928.84283,
        8.0175905,
        10419.247,
        5.619053,
        10419.156,
        4.057502,
    ]
end

@testitem "Allocation level control" begin
    import JuMP
    using Ribasim: NodeID
    using DataFrames: DataFrame
    using OrdinaryDiffEqCore: get_du
    using DataInterpolations: LinearInterpolation, integral

    toml_path = normpath(@__DIR__, "../../generated_testmodels/level_demand/ribasim.toml")
    @test ispath(toml_path)
    model = Ribasim.Model(toml_path)

    p = model.integrator.p
    (; user_demand, graph, allocation, basin, level_demand) = p

    # Initial "integrated" vertical flux
    @test allocation.mean_input_flows[1][(NodeID(:Basin, 2, p), NodeID(:Basin, 2, p))] ≈ 1e2

    Ribasim.solve!(model)

    storage = Ribasim.get_storages_and_levels(model).storage[1, :]
    t = Ribasim.tsaves(model)
    du = get_du(model.integrator)

    d = user_demand.demand_itp[1][2](0)
    ϕ = 1e-3 # precipitation
    q = Ribasim.get_flow(
        du,
        p,
        0.0,
        (Ribasim.NodeID(:FlowBoundary, 1, p), Ribasim.NodeID(:Basin, 2, p)),
    )
    A = Ribasim.basin_areas(basin, 1)[1]
    l_max = level_demand.max_level[1](0)
    Δt_allocation = allocation.allocation_models[1].Δt_allocation

    # In this section the Basin leaves no supply for the UserDemand
    stage_1 = t .<= 2 * Δt_allocation
    u_stage_1(τ) = storage[1] + (q + ϕ) * τ
    @test storage[stage_1] ≈ u_stage_1.(t[stage_1]) rtol = 1e-4

    # In this section (and following sections) the basin has no longer a (positive) demand,
    # since precipitation provides enough water to get the basin to its target level
    # The FlowBoundary flow gets fully allocated to the UserDemand
    stage_2 = 2 * Δt_allocation .<= t .<= 8 * Δt_allocation
    stage_2_start_idx = findfirst(stage_2)
    u_stage_2(τ) = storage[stage_2_start_idx] + ϕ * (τ - t[stage_2_start_idx])
    @test storage[stage_2] ≈ u_stage_2.(t[stage_2]) rtol = 1e-4

    # In this section the basin enters its surplus stage,
    # even though initially the level is below the maximum level. This is because the simulation
    # anticipates that the current precipitation is going to bring the basin level over
    # its maximum level
    stage_3 = 8 * Δt_allocation .<= t .<= 13 * Δt_allocation
    stage_3_start_idx = findfirst(stage_3)
    u_stage_3(τ) = storage[stage_3_start_idx] + (q + ϕ - d) * (τ - t[stage_3_start_idx])
    @test storage[stage_3] ≈ u_stage_3.(t[stage_3]) rtol = 1e-4

    # At the start of this section precipitation stops, and so the UserDemand
    # partly uses surplus water from the basin to fulfill its demand
    stage_4 = 13 * Δt_allocation .<= t .<= 17 * Δt_allocation
    stage_4_start_idx = findfirst(stage_4)
    u_stage_4(τ) = storage[stage_4_start_idx] + (q - d) * (τ - t[stage_4_start_idx])
    @test storage[stage_4] ≈ u_stage_4.(t[stage_4]) rtol = 1e-4

    # From this point the basin is in a dynamical equilibrium,
    # since the basin has no supply so the UserDemand abstracts precisely
    # the flow from the level boundary
    stage_5 = 18 * Δt_allocation .<= t
    stage_5_start_idx = findfirst(stage_5)
    u_stage_5(τ) = storage[stage_5_start_idx]
    @test storage[stage_5] ≈ u_stage_5.(t[stage_5]) rtol = 1e-4

    # Isolated LevelDemand + Basin pair to test optional min_level
    problem = allocation.allocation_models[2].problem
    @test JuMP.value(only(problem[:F_basin_in])) == 0.0
    @test JuMP.value(only(problem[:F_basin_out])) == 0.0
    q = JuMP.normalized_rhs(only(problem[:basin_outflow]))
    storage_surplus = 1000.0  # Basin #7 is 1000 m2 and 1 m above LevelDemand max_level
    @test q ≈ storage_surplus / Δt_allocation

    # Realized level demand
    record_demand = DataFrame(allocation.record_demand)
    df_basin_2 = record_demand[record_demand.node_id .== 2, :]
    itp_basin_2 = LinearInterpolation(storage, t)
    realized_numeric = diff(itp_basin_2.(df_basin_2.time)) / Δt_allocation
    @test all(isapprox.(realized_numeric, df_basin_2.realized[2:end], atol = 2e-4))

    # Realized user demand
    flow_table = DataFrame(Ribasim.flow_table(model))
    flow_table_user_3 = flow_table[flow_table.edge_id .== 2, :]
    itp_user_3 = LinearInterpolation(
        flow_table_user_3.flow_rate,
        Ribasim.seconds_since.(flow_table_user_3.time, model.config.starttime),
    )
    df_user_3 = record_demand[
        (record_demand.node_id .== 3) .&& (record_demand.demand_priority .== 1),
        :,
    ]
    realized_numeric = diff(integral.(Ref(itp_user_3), df_user_3.time)) ./ Δt_allocation
    @test all(isapprox.(realized_numeric[3:end], df_user_3.realized[4:end], atol = 5e-4))
end

@testitem "Flow demand" begin
    using JuMP
    using Ribasim: NodeID, OptimizationType
    using DataFrames: DataFrame
    using Tables.DataAPI: nrow
    import Arrow
    import Tables
    using Dates: DateTime

    toml_path = normpath(@__DIR__, "../../generated_testmodels/flow_demand/ribasim.toml")
    @test ispath(toml_path)
    model = Ribasim.Model(toml_path)
    (; p) = model.integrator
    (; graph, allocation, flow_demand, user_demand, level_boundary) = p

    # Test has_external_demand
    @test !any(
        Ribasim.has_external_demand(graph, node_id, :flow_demand)[1] for
        node_id in graph[].node_ids[2] if node_id.value != 2
    )
    @test Ribasim.has_external_demand(
        graph,
        NodeID(:TabulatedRatingCurve, 2, p),
        :flow_demand,
    )[1]

    (; allocation_models, record_flow) = allocation
    allocation_model = allocation_models[1]
    (; problem, flow, sources) = allocation_model

    F = problem[:F]
    F_flow_buffer_in = problem[:F_flow_buffer_in]
    F_flow_buffer_out = problem[:F_flow_buffer_out]

    node_id_with_flow_demand = NodeID(:TabulatedRatingCurve, 2, p)

    # Test flow conservation constraint containing flow buffer
    constraint_with_flow_buffer =
        JuMP.constraint_object(problem[:flow_conservation][node_id_with_flow_demand])
    @test constraint_with_flow_buffer.func ==
          F[(NodeID(:LevelBoundary, 1, p), node_id_with_flow_demand)] -
          F[(node_id_with_flow_demand, NodeID(:Basin, 3, p))] -
          F_flow_buffer_in[node_id_with_flow_demand] +
          F_flow_buffer_out[node_id_with_flow_demand]

    t = 0.0
    (; u) = model.integrator
    optimization_type = OptimizationType.internal_sources
    Ribasim.set_initial_values!(allocation_model, u, p, t)
    sources[(NodeID(:LevelBoundary, 1, p), node_id_with_flow_demand)].capacity_reduced =
        2e-3

    # Priority 1
    Ribasim.optimize_demand_priority!(
        allocation_model,
        model.integrator.u,
        p,
        t,
        1,
        optimization_type,
    )
    objective = JuMP.objective_function(problem)
    @test JuMP.UnorderedPair(
        F_flow_buffer_in[node_id_with_flow_demand],
        F_flow_buffer_in[node_id_with_flow_demand],
    ) in keys(objective.terms)

    # Reduced demand
    @test flow_demand.demand[1] ≈ flow_demand.demand_itp[1](t) - 0.001 rtol = 1e-3

    ## Priority 2
    Ribasim.optimize_demand_priority!(
        allocation_model,
        model.integrator.u,
        p,
        t,
        2,
        optimization_type,
    )
    # No demand left
    @test flow_demand.demand[1] < 1e-10
    # Allocated
    @test JuMP.value(only(F_flow_buffer_in)) ≈ only(flow_demand.demand) atol = 1e-10

    ## Priority 3
    Ribasim.optimize_demand_priority!(
        allocation_model,
        model.integrator.u,
        p,
        t,
        3,
        optimization_type,
    )
    # The flow from the source is used up in previous demand priorities
    @test flow[(NodeID(:LevelBoundary, 1, p), node_id_with_flow_demand)] ≈ 0 atol = 1e-10
    # So flow from the flow buffer is used for UserDemand #4
    @test JuMP.value(F_flow_buffer_out[node_id_with_flow_demand]) ≈ 0.001 rtol = 1e-3
    # Flow taken from buffer
    @test JuMP.value(only(F_flow_buffer_out)) ≈ user_demand.demand_itp[1][3](t) rtol = 1e-3
    # No flow coming from level boundary
    @test JuMP.value(F[(only(level_boundary.node_id), node_id_with_flow_demand)]) ≈ 0 atol =
        1e-10

    ## Priority 4
    Ribasim.optimize_demand_priority!(
        allocation_model,
        model.integrator.u,
        p,
        t,
        4,
        optimization_type,
    )

    # Realized flow demand
    model = Ribasim.run(toml_path)
    record_demand = DataFrame(model.integrator.p.allocation.record_demand)
    df_rating_curve_2 = record_demand[record_demand.node_id .== 2, :]
    @test all(df_rating_curve_2.realized .≈ 0.002)

    @testset "Results" begin
        allocation_bytes = read(normpath(dirname(toml_path), "results/allocation.arrow"))
        allocation_flow_bytes =
            read(normpath(dirname(toml_path), "results/allocation_flow.arrow"))
        allocation = Arrow.Table(allocation_bytes)
        allocation_flow = Arrow.Table(allocation_flow_bytes)
        @test Tables.schema(allocation) == Tables.Schema(
            (
                :time,
                :subnetwork_id,
                :node_type,
                :node_id,
                :demand_priority,
                :demand,
                :allocated,
                :realized,
            ),
            (DateTime, Int32, String, Int32, Int32, Float64, Float64, Float64),
        )
        @test Tables.schema(allocation_flow) == Tables.Schema(
            (
                :time,
                :edge_id,
                :from_node_type,
                :from_node_id,
                :to_node_type,
                :to_node_id,
                :subnetwork_id,
                :demand_priority,
                :flow_rate,
                :optimization_type,
            ),
            (DateTime, Int32, String, Int32, String, Int32, Int32, Int32, Float64, String),
        )
        @test nrow(allocation) > 0
        @test nrow(allocation_flow) > 0
    end
end

@testitem "flow_demand_with_max_flow_rate" begin
    using Ribasim: NodeID
    using JuMP

    toml_path = normpath(
        @__DIR__,
        "../../generated_testmodels/linear_resistance_demand/ribasim.toml",
    )
    @test ispath(toml_path)
    model = Ribasim.Model(toml_path)
    (; p) = model.integrator

    # Test for pump max flow capacity constraint
    (; problem) = p.allocation.allocation_models[1]
    constraint = JuMP.constraint_object(
        problem[:capacity][(NodeID(:Basin, 1, p), NodeID(:LinearResistance, 2, p))],
    )
    @test constraint.set.upper == 2.0
end

@testitem "equal_fraction_allocation" begin
    using Ribasim: NodeID, NodeType
    using StructArrays: StructVector
    using DataFrames: DataFrame

    toml_path =
        normpath(@__DIR__, "../../generated_testmodels/fair_distribution/ribasim.toml")
    @test ispath(toml_path)
    model = Ribasim.run(toml_path)
    (; user_demand, graph) = model.integrator.p

    data_allocation = DataFrame(Ribasim.allocation_table(model))
    fractions = Vector{Float64}[]

    for id in user_demand.node_id
        data_allocation_id = filter(:node_id => ==(id.value), data_allocation)
        frac = data_allocation_id.allocated ./ data_allocation_id.demand
        push!(fractions, frac)
    end

    @test all(isapprox.(fractions[1], fractions[2], atol = 1e-4))
    @test all(isapprox.(fractions[1], fractions[3], atol = 1e-4))
    @test all(isapprox.(fractions[1], fractions[4], atol = 1e-4))
end

@testitem "direct_basin_allocation" begin
    using Ribasim: NodeID
    import SQLite
    import JuMP

    toml_path = normpath(@__DIR__, "../../generated_testmodels/level_demand/ribasim.toml")
    model = Ribasim.Model(toml_path)
    (; p) = model.integrator
    t = 0.0
    u = model.integrator.u
    demand_priority_idx = 2

    allocation_model = first(p.allocation.allocation_models)
    Ribasim.set_initial_values!(allocation_model, u, p, t)
    Ribasim.set_objective_demand_priority!(allocation_model, u, p, t, demand_priority_idx)
    Ribasim.allocate_to_users_from_connected_basin!(
        allocation_model,
        p,
        demand_priority_idx,
    )
    flow_data = allocation_model.flow.data
    @test flow_data[(NodeID(:FlowBoundary, 1, p), NodeID(:Basin, 2, p))] == 0.0
    @test flow_data[(NodeID(:Basin, 2, p), NodeID(:UserDemand, 3, p))] == 0.0015
    @test flow_data[(NodeID(:UserDemand, 3, p), NodeID(:Basin, 5, p))] == 0.0
end

@testitem "level_demand_without_max_level" begin
    using Ribasim: NodeID, get_basin_capacity, outflow_id
    using JuMP

    toml_path = normpath(@__DIR__, "../../generated_testmodels/level_demand/ribasim.toml")
    @test ispath(toml_path)
    model = Ribasim.Model(toml_path)
    (; p, u, t) = model.integrator
    (; allocation_models) = p.allocation
    (; basin, level_demand, graph) = p

    level_demand.max_level[1].u .= Inf
    level_demand.max_level[2].u .= Inf

    # Given a max_level of Inf, the basin capacity is 0.0 because it is not possible for the basin level to be > Inf
    @test Ribasim.get_basin_capacity(allocation_models[1], u, p, t, basin.node_id[1]) == 0.0
    @test Ribasim.get_basin_capacity(allocation_models[1], u, p, t, basin.node_id[2]) == 0.0
    @test Ribasim.get_basin_capacity(allocation_models[2], u, p, t, basin.node_id[3]) == 0.0
end
