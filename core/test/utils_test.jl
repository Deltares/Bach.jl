@testitem "NodeID" begin
    using Ribasim: NodeID

    id = NodeID(:Basin, 2, 1)
    @test sprint(show, id) === "Basin #2"
    @test id < NodeID(:Basin, 3, 1)
    @test_throws ErrorException id < NodeID(:Pump, 3, 1)
    @test Int32(id) === Int32(2)
    @test convert(Int32, id) === Int32(2)
end

@testitem "bottom" begin
    using StructArrays: StructVector
    using Ribasim: NodeID, cache
    using DataInterpolations: LinearInterpolation, integral, invert_integral
    using DataStructures: OrderedSet

    # create two basins with different bottoms/levels
    area = [[0.01, 1.0], [0.01, 1.0]]
    level = [[0.0, 1.0], [4.0, 5.0]]
    level_to_area = LinearInterpolation.(area, level)
    storage_to_level = invert_integral.(level_to_area)
    demand = zeros(2)

    substances = OrderedSet([:test])
    concentration_state = zeros(2, 1)
    concentration = zeros(2, 2, 1)
    mass = zeros(2, 1)

    basin = Ribasim.Basin(;
        node_id = NodeID.(:Basin, [5, 7], [1, 2]),
        storage_to_level,
        level_to_area,
        demand,
        concentration_state,
        concentration,
        mass,
        substances,
        time = StructVector{Ribasim.BasinTimeV1}(undef, 0),
        concentration_time = StructVector{Ribasim.BasinConcentrationV1}(undef, 0),
    )

    (; current_level, current_area) = basin.current_properties

    current_level[Float64[]] .= [2.0, 3.0]
    current_area[Float64[]] .= [2.0, 3.0]

    @test Ribasim.basin_levels(basin, 2)[1] === 4.0
    @test Ribasim.basin_bottom(basin, NodeID(:Basin, 5, 1))[2] === 0.0
    @test Ribasim.basin_bottom(basin, NodeID(:Basin, 7, 2))[2] === 4.0
    @test !Ribasim.basin_bottom(basin, NodeID(:Terminal, 6, 1))[1]
end

@testitem "Convert levels to storages" begin
    using StructArrays: StructVector
    using Logging
    using Ribasim: NodeID
    using DataInterpolations: LinearInterpolation, invert_integral
    using DataStructures: OrderedSet

    level = [
        0.0,
        0.42601923740838954,
        1.1726055542568279,
        1.9918063978301288,
        2.945965660308591,
        3.7918607426596513,
        4.378609443214641,
        4.500422081139986,
        4.638188322915925,
        5.462975756944211,
    ]
    area = [
        0.5284895347829252,
        0.7036603783547138,
        0.6831597656207129,
        0.7582032614294112,
        0.5718206017422349,
        0.5390282084391234,
        0.9650081130058792,
        0.07071025361013983,
        0.10659325339342585,
        1.1,
    ]
    level_to_area = LinearInterpolation(area, level; extrapolate = true)
    storage_to_level = invert_integral(level_to_area)
    demand = zeros(1)

    substances = OrderedSet([:test])
    concentration_state = zeros(1, 1)
    concentration = zeros(2, 1, 1)
    mass = zeros(1, 1)

    basin = Ribasim.Basin(;
        node_id = NodeID.(:Basin, [1], 1),
        storage_to_level = [storage_to_level],
        level_to_area = [level_to_area],
        demand,
        time = StructVector{Ribasim.BasinTimeV1}(undef, 0),
        concentration_time = StructVector{Ribasim.BasinConcentrationV1}(undef, 0),
        concentration_state,
        concentration,
        mass,
        substances,
    )

    logger = TestLogger()
    with_logger(logger) do
        @test_throws ErrorException Ribasim.get_storages_from_levels(basin, [-1.0])
    end

    @test length(logger.logs) == 1
    @test logger.logs[1].level == Error
    @test logger.logs[1].message ==
          "The initial level (-1.0) of Basin #1 is below the bottom (0.0)."

    # Converting from storages to levels and back should return the same storages
    storages = range(0.0, 2 * storage_to_level.t[end], 50)
    levels = [Ribasim.get_level_from_storage(basin, 1, s) for s in storages]
    storages_ = [Ribasim.get_storage_from_level(basin, 1, l) for l in levels]
    @test storages ≈ storages_

    # At or below bottom the storage is 0
    @test Ribasim.get_storage_from_level(basin, 1, 0.0) == 0.0
    @test Ribasim.get_storage_from_level(basin, 1, -1.0) == 0.0
end

@testitem "Expand logic_mapping" begin
    using Ribasim: NodeID

    logic_mapping = [Dict{String, String}() for _ in 1:2]
    logic_mapping[1]["*T*"] = "foo"
    logic_mapping[2]["FF"] = "bar"
    node_id = NodeID.(:DiscreteControl, [1, 2], [1, 2])

    logic_mapping_expanded = Ribasim.expand_logic_mapping(logic_mapping, node_id)

    @test logic_mapping_expanded[1][Bool[1, 1, 1]] == "foo"
    @test logic_mapping_expanded[1][Bool[0, 1, 1]] == "foo"
    @test logic_mapping_expanded[1][Bool[1, 1, 0]] == "foo"
    @test logic_mapping_expanded[1][Bool[0, 1, 0]] == "foo"
    @test logic_mapping_expanded[2][Bool[0, 0]] == "bar"
    @test length.(logic_mapping_expanded) == [4, 1]

    new_truth_state = "duck"
    new_control_state = "quack"
    logic_mapping[2][new_truth_state] = new_control_state

    @test_throws "Truth state '$new_truth_state' contains illegal characters or is empty." Ribasim.expand_logic_mapping(
        logic_mapping,
        node_id,
    )

    delete!(logic_mapping[2], new_truth_state)

    new_truth_state = ""
    new_control_state = "bar"
    logic_mapping[1][new_truth_state] = new_control_state

    @test_throws "Truth state '' contains illegal characters or is empty." Ribasim.expand_logic_mapping(
        logic_mapping,
        node_id,
    )

    delete!(logic_mapping[1], new_truth_state)

    new_truth_state = "FTT"
    new_control_state = "foo"
    logic_mapping[1][new_truth_state] = new_control_state

    # This should not throw an error, as although "FTT" for node_id = 1 is already covered above, this is consistent
    Ribasim.expand_logic_mapping(logic_mapping, node_id)

    new_truth_state = "TTF"
    new_control_state = "bar"
    logic_mapping[1][new_truth_state] = new_control_state

    @test_throws "AssertionError: Multiple control states found for DiscreteControl #1 for truth state `TTF`: [\"bar\", \"foo\"]." Ribasim.expand_logic_mapping(
        logic_mapping,
        node_id,
    )
end

@testitem "Jacobian sparsity" begin
    import SQLite
    using ComponentArrays: ComponentVector
    using SparseArrays: sparse, findnz

    toml_path = normpath(@__DIR__, "../../generated_testmodels/basic/ribasim.toml")

    cfg = Ribasim.Config(toml_path)
    db_path = Ribasim.database_path(cfg)
    db = SQLite.DB(db_path)

    p = Ribasim.Parameters(db, cfg)
    close(db)
    t0 = 0.0
    u0 = Ribasim.build_state_vector(p)
    du0 = copy(u0)
    p = Ribasim.build_flow_to_storage(p, u0)
    jac_prototype = Ribasim.get_jac_prototype(du0, u0, p, t0)

    # rows, cols, _ = findnz(jac_prototype)
    #! format: off
    rows_expected = [1, 2, 3, 6, 7, 9, 13, 1, 2, 3, 4, 6, 7, 9, 10, 13, 14, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13, 15, 2, 3, 4, 5, 10, 11, 14, 15, 3, 4, 5, 11, 15, 1, 2, 3, 6, 7, 9, 13, 1, 2, 3, 6, 7, 8, 9, 12, 13, 7, 8, 12, 1, 2, 3, 6, 7, 9, 13, 2, 4, 10, 14, 3, 4, 5, 11, 15, 7, 8, 12, 1, 2, 3, 6, 7, 9, 13, 2, 4, 10, 14, 3, 4, 5, 11, 15]
    cols_expected = [1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 11, 11, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 15, 15, 15, 15, 15]
    #! format: on
    jac_prototype_expected =
        sparse(rows_expected, cols_expected, true, size(jac_prototype)...)
    @test jac_prototype == jac_prototype_expected

    toml_path = normpath(@__DIR__, "../../generated_testmodels/pid_control/ribasim.toml")

    cfg = Ribasim.Config(toml_path)
    db_path = Ribasim.database_path(cfg)
    db = SQLite.DB(db_path)

    p = Ribasim.Parameters(db, cfg)
    close(db)
    u0 = Ribasim.build_state_vector(p)
    du0 = copy(u0)
    p = Ribasim.build_flow_to_storage(p, u0)
    jac_prototype = Ribasim.get_jac_prototype(du0, u0, p, t0)

    #! format: off
    rows_expected = [1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6, 1, 2]
    cols_expected = [1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 5, 6]
    #! format: on
    jac_prototype_expected =
        sparse(rows_expected, cols_expected, true, size(jac_prototype)...)
    @test jac_prototype == jac_prototype_expected
end

@testitem "FlatVector" begin
    vv = [[2.2, 3.2], [4.3, 5.3], [6.4, 7.4]]
    fv = Ribasim.FlatVector(vv)
    @test length(fv) == 6
    @test size(fv) == (6,)
    @test collect(fv) == [2.2, 3.2, 4.3, 5.3, 6.4, 7.4]
    @test fv[begin] == 2.2
    @test fv[5] == 6.4
    @test fv[end] == 7.4

    vv = Vector{Float64}[]
    fv = Ribasim.FlatVector(vv)
    @test isempty(fv)
    @test length(fv) == 0
end

@testitem "reduction_factor" begin
    using Ribasim: reduction_factor
    @test reduction_factor(-2.0, 2.0) === 0.0
    @test reduction_factor(0.0f0, 2.0) === 0.0f0
    @test reduction_factor(0.0, 2.0) === 0.0
    @test reduction_factor(1.0f0, 2.0) === 0.5f0
    @test reduction_factor(1.0, 2.0) === 0.5
    @test reduction_factor(3.0f0, 2.0) === 1.0f0
    @test reduction_factor(3.0, 2.0) === 1.0
    @test reduction_factor(Inf, 2.0) === 1.0
    @test reduction_factor(-Inf, 2.0) === 0.0
end

@testitem "constraints_from_nodes" begin
    using Ribasim:
        Model,
        snake_case,
        nodetypes,
        NodeType,
        is_flow_constraining,
        is_flow_direction_constraining

    toml_path = normpath(@__DIR__, "../../generated_testmodels/basic/ribasim.toml")
    @test ispath(toml_path)
    model = Model(toml_path)
    (; p) = model.integrator
    constraining_types = (NodeType.Pump, NodeType.Outlet, NodeType.LinearResistance)
    directed = (
        NodeType.Pump,
        NodeType.Outlet,
        NodeType.TabulatedRatingCurve,
        NodeType.UserDemand,
        NodeType.FlowBoundary,
    )

    for symbol in nodetypes
        type = NodeType.T(symbol)
        if type in constraining_types
            @test is_flow_constraining(type)
        else
            @test !is_flow_constraining(type)
        end
        if type in directed
            @test is_flow_direction_constraining(type)
        else
            @test !is_flow_direction_constraining(type)
        end
    end
end

@testitem "Node types" begin
    using Ribasim: nodetypes, NodeType, Parameters, AbstractParameterNode, snake_case

    @test Set(nodetypes) == Set([
        :Basin,
        :ContinuousControl,
        :DiscreteControl,
        :FlowBoundary,
        :FlowDemand,
        :LevelBoundary,
        :LevelDemand,
        :LinearResistance,
        :ManningResistance,
        :Outlet,
        :PidControl,
        :Pump,
        :TabulatedRatingCurve,
        :Terminal,
        :UserDemand,
    ])
    for nodetype in nodetypes
        NodeType.T(nodetype)
        if nodetype != :Terminal
            # It has a struct which is added to Parameters
            T = getproperty(Ribasim, nodetype)
            @test T <: AbstractParameterNode
            @test hasfield(Parameters, snake_case(nodetype))
        end
    end
end

@testitem "flow_to_storage matrix" begin
    using ComponentArrays: ComponentArray, Axis, getaxes
    using LinearAlgebra: I
    toml_path = normpath(@__DIR__, "../../generated_testmodels/basic/ribasim.toml")
    @test ispath(toml_path)
    model = Ribasim.Model(toml_path)
    (; u, p) = model.integrator
    n_basins = length(u.evaporation)
    (; flow_to_storage) = p
    flow_to_storage =
        ComponentArray(flow_to_storage, (Axis(; basins = 1:n_basins), only(getaxes(u))))

    @test flow_to_storage[:, :evaporation] == -I
    @test flow_to_storage[:, :infiltration] == -I

    for node_name in
        [:tabulated_rating_curve, :pump, :outlet, :linear_resistance, :manning_resistance]
        flow_to_storage_node = flow_to_storage[:, node_name]
        # In every column there is either 0 or 1 instance of 1.0 (flow into a basin)
        @test all(
            i -> i ∈ (0, 1),
            count(==(1.0), collect(flow_to_storage[:, :tabulated_rating_curve]); dims = 1),
        )

        # In every column there is either 0 or 1 instance of -1.0 (flow out of a basin)
        @test all(
            i -> i ∈ (0, 1),
            count(
                ==(1 - 0.0),
                collect(flow_to_storage[:, :tabulated_rating_curve]);
                dims = 1,
            ),
        )
    end
end
