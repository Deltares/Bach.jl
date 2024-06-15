@testitem "Basin profile validation" begin
    using Ribasim: NodeID, valid_profiles, qh_interpolation, ScalarInterpolation
    using Logging
    using StructArrays: StructVector

    node_id = [NodeID(:Basin, 1, 1)]
    level = [[0.0, 0.0, 1.0]]
    area = [[0.0, 100.0, 90]]

    logger = TestLogger(; min_level = Debug)
    with_logger(logger) do
        @test !valid_profiles(node_id, level, area)
    end
    @test length(logger.logs) == 3
    @test logger.logs[1].level == Error
    @test logger.logs[1].message ==
          "Basin #1 profile has repeated levels, this cannot be interpolated."
    @test logger.logs[2].level == Error
    @test logger.logs[2].message ==
          "Basin #1 profile cannot start with area <= 0 at the bottom for numerical reasons."
    @test logger.logs[2].kwargs[:area] == 0
    @test logger.logs[3].level == Error
    @test logger.logs[3].message == "Basin #1 profile cannot have decreasing areas."

    table = StructVector(; flow_rate = [0.0, 0.1], level = [1.0, 2.0], node_id = [5, 5])
    itp = qh_interpolation(NodeID(:TabulatedRatingCurve, 5, 1), table)
    # constant extrapolation at the bottom end, linear extrapolation at the top end
    itp(0.0) ≈ 0.0
    itp(1.0) ≈ 0.0
    itp(1.5) ≈ 0.05
    itp(2.0) ≈ 0.1
    itp(3.0) ≈ 0.2
    @test itp isa ScalarInterpolation
end

@testitem "Q(h) validation" begin
    import SQLite
    using Logging

    toml_path = normpath(@__DIR__, "../../generated_testmodels/invalid_qh/ribasim.toml")
    @test ispath(toml_path)

    config = Ribasim.Config(toml_path)
    db_path = Ribasim.input_path(config, config.database)
    db = SQLite.DB(db_path)
    graph = Ribasim.create_graph(db, config, [1])

    logger = TestLogger()
    with_logger(logger) do
        @test_throws "Errors occurred when parsing TabulatedRatingCurve data." Ribasim.TabulatedRatingCurve(
            db,
            config,
            graph,
        )
    end
    close(db)

    @test length(logger.logs) == 3
    @test logger.logs[1].level == Error
    @test logger.logs[1].message == "The `flow_rate` must start at 0."
    @test logger.logs[2].level == Error
    @test logger.logs[2].message == "The `level` cannot be repeated."
    @test logger.logs[3].level == Error
    @test logger.logs[3].message ==
          "The `flow_rate` cannot decrease with increasing `level`."
end

@testitem "Neighbor count validation" begin
    using Graphs: DiGraph
    using Logging
    using MetaGraphsNext: MetaGraph
    using Ribasim: NodeID, NodeMetadata, EdgeMetadata, EdgeType

    graph = MetaGraph(
        DiGraph();
        label_type = NodeID,
        vertex_data_type = NodeMetadata,
        edge_data_type = EdgeMetadata,
        graph_data = nothing,
    )

    graph[NodeID(:Pump, 1, 1)] = NodeMetadata(:pump, 9)
    graph[NodeID(:Basin, 2, 1)] = NodeMetadata(:pump, 9)
    graph[NodeID(:Basin, 3, 1)] = NodeMetadata(:pump, 9)
    graph[NodeID(:Basin, 4, 1)] = NodeMetadata(:pump, 9)
    graph[NodeID(:FractionalFlow, 5, 1)] = NodeMetadata(:pump, 9)
    graph[NodeID(:Pump, 6, 1)] = NodeMetadata(:pump, 9)

    function set_edge_metadata!(id_1, id_2, edge_type)
        graph[id_1, id_2] = EdgeMetadata(0, 0, edge_type, 0, (id_1, id_2))
        return nothing
    end

    set_edge_metadata!(NodeID(:Basin, 2, 1), NodeID(:Pump, 1, 1), EdgeType.flow)
    set_edge_metadata!(NodeID(:Basin, 3, 1), NodeID(:Pump, 1, 1), EdgeType.flow)
    set_edge_metadata!(NodeID(:Pump, 6, 1), NodeID(:Basin, 2, 1), EdgeType.flow)
    set_edge_metadata!(NodeID(:FractionalFlow, 5, 1), NodeID(:Pump, 6, 1), EdgeType.control)

    logger = TestLogger()
    with_logger(logger) do
        @test !Ribasim.valid_n_neighbors(:Pump, graph)
    end

    @test length(logger.logs) == 3
    @test logger.logs[1].level == Error
    @test logger.logs[1].message == "Pump #1 can have at most 1 flow inneighbor(s) (got 2)."
    @test logger.logs[2].level == Error
    @test logger.logs[2].message ==
          "Pump #1 must have at least 1 flow outneighbor(s) (got 0)."
    @test logger.logs[3].level == Error
    @test logger.logs[3].message ==
          "Pump #6 must have at least 1 flow inneighbor(s) (got 0)."

    set_edge_metadata!(NodeID(:Basin, 2, 1), NodeID(:FractionalFlow, 5, 1), EdgeType.flow)
    set_edge_metadata!(NodeID(:FractionalFlow, 5, 1), NodeID(:Basin, 3, 1), EdgeType.flow)
    set_edge_metadata!(NodeID(:FractionalFlow, 5, 1), NodeID(:Basin, 4, 1), EdgeType.flow)

    logger = TestLogger(; min_level = Debug)
    with_logger(logger) do
        @test !Ribasim.valid_n_neighbors(:FractionalFlow, graph)
    end

    @test length(logger.logs) == 2
    @test logger.logs[1].level == Error
    @test logger.logs[1].message ==
          "FractionalFlow #5 can have at most 1 flow outneighbor(s) (got 2)."
    @test logger.logs[2].level == Error
    @test logger.logs[2].message ==
          "FractionalFlow #5 can have at most 0 control outneighbor(s) (got 1)."

    @test_throws "'n_neighbor_bounds_flow' not defined for Val{:foo}()." Ribasim.n_neighbor_bounds_flow(
        :foo,
    )
    @test_throws "'n_neighbor_bounds_control' not defined for Val{:bar}()." Ribasim.n_neighbor_bounds_control(
        :bar,
    )
end

@testitem "PidControl connectivity validation" begin
    using Graphs: DiGraph
    using Logging
    using MetaGraphsNext: MetaGraph
    using Ribasim: NodeID, NodeMetadata, EdgeMetadata, NodeID, EdgeType

    pid_control_node_id = NodeID.(:PidControl, [1, 6], 1)
    pid_control_listen_node_id = [NodeID(:Terminal, 3, 1), NodeID(:Basin, 5, 1)]

    graph = MetaGraph(
        DiGraph();
        label_type = NodeID,
        vertex_data_type = NodeMetadata,
        edge_data_type = EdgeMetadata,
        graph_data = nothing,
    )

    graph[NodeID(:PidControl, 1, 1)] = NodeMetadata(:pid_control, 0)
    graph[NodeID(:PidControl, 6, 1)] = NodeMetadata(:pid_control, 0)
    graph[NodeID(:Pump, 2, 1)] = NodeMetadata(:pump, 0)
    graph[NodeID(:Pump, 4, 1)] = NodeMetadata(:pump, 0)
    graph[NodeID(:Terminal, 3, 1)] = NodeMetadata(:something_else, 0)
    graph[NodeID(:Basin, 5, 1)] = NodeMetadata(:basin, 0)
    graph[NodeID(:Basin, 7, 1)] = NodeMetadata(:basin, 0)

    function set_edge_metadata!(id_1, id_2, edge_type)
        graph[id_1, id_2] = EdgeMetadata(0, 0, edge_type, 0, (id_1, id_2))
        return nothing
    end

    set_edge_metadata!(NodeID(:Terminal, 3, 1), NodeID(:Pump, 4, 1), EdgeType.flow)
    set_edge_metadata!(NodeID(:Basin, 7, 1), NodeID(:Pump, 2, 1), EdgeType.flow)
    set_edge_metadata!(NodeID(:Pump, 2, 1), NodeID(:Basin, 7, 1), EdgeType.flow)
    set_edge_metadata!(NodeID(:Pump, 4, 1), NodeID(:Basin, 7, 1), EdgeType.flow)

    set_edge_metadata!(NodeID(:PidControl, 1, 1), NodeID(:Pump, 4, 1), EdgeType.control)
    set_edge_metadata!(NodeID(:PidControl, 6, 1), NodeID(:Pump, 2, 1), EdgeType.control)

    logger = TestLogger()
    with_logger(logger) do
        @test !Ribasim.valid_pid_connectivity(
            pid_control_node_id,
            pid_control_listen_node_id,
            graph,
        )
    end

    @test length(logger.logs) == 2
    @test logger.logs[1].level == Error
    @test logger.logs[1].message ==
          "Listen node Terminal #3 of PidControl #1 is not a Basin"
    @test logger.logs[2].level == Error
    @test logger.logs[2].message ==
          "PID listened Basin #5 is not on either side of controlled Pump #2."
end

@testitem "FractionalFlow validation" begin
    import SQLite
    using Logging
    using Ribasim: NodeID

    toml_path = normpath(
        @__DIR__,
        "../../generated_testmodels/invalid_fractional_flow/ribasim.toml",
    )
    @test ispath(toml_path)

    config = Ribasim.Config(toml_path)
    db_path = Ribasim.input_path(config, config.database)
    db = SQLite.DB(db_path)
    graph = Ribasim.create_graph(db, config, [1, 1])
    fractional_flow = Ribasim.FractionalFlow(db, config, graph)

    logger = TestLogger()
    with_logger(logger) do
        @test !Ribasim.valid_fractional_flow(
            graph,
            fractional_flow.node_id,
            fractional_flow.control_mapping,
        )
        @test !Ribasim.valid_edges(graph)
    end

    @test length(logger.logs) == 4
    @test logger.logs[1].level == Error
    @test logger.logs[1].message ==
          "TabulatedRatingCurve #7 has outflow to FractionalFlow and other node types."
    @test logger.logs[2].level == Error
    @test logger.logs[2].message ==
          "Fractional flow nodes must have non-negative fractions."
    @test logger.logs[2].kwargs[:node_id] == NodeID(:FractionalFlow, 3, 1)
    @test logger.logs[2].kwargs[:fraction] ≈ -0.1
    @test logger.logs[2].kwargs[:control_state] == ""
    @test logger.logs[3].level == Error
    @test logger.logs[3].message ==
          "The sum of fractional flow fractions leaving a node must be ≈1."
    @test logger.logs[3].kwargs[:node_id] == NodeID(:TabulatedRatingCurve, 7, 1)
    @test logger.logs[3].kwargs[:fraction_sum] ≈ 0.4
    @test logger.logs[3].kwargs[:control_state] == ""
    @test logger.logs[4].level == Error
    @test logger.logs[4].message == "Cannot connect a basin to a fractional_flow."
    @test logger.logs[4].kwargs[:id_src] == NodeID(:Basin, 2, 1)
    @test logger.logs[4].kwargs[:id_dst] == NodeID(:FractionalFlow, 8, 1)
end

@testitem "DiscreteControl logic validation" begin
    import SQLite
    using Logging

    toml_path = normpath(
        @__DIR__,
        "../../generated_testmodels/invalid_discrete_control/ribasim.toml",
    )
    @test ispath(toml_path)

    cfg = Ribasim.Config(toml_path)
    db_path = Ribasim.input_path(cfg, cfg.database)
    db = SQLite.DB(db_path)
    p = Ribasim.Parameters(db, cfg)

    logger = TestLogger()
    with_logger(logger) do
        @test !Ribasim.valid_discrete_control(p, cfg)
    end

    @test length(logger.logs) == 5
    @test logger.logs[1].level == Error
    @test logger.logs[1].message ==
          "DiscreteControl #5 has 3 condition(s), which is inconsistent with these truth state(s): [\"FFFF\"]."
    @test logger.logs[2].level == Error
    @test logger.logs[2].message ==
          "These control states from DiscreteControl #5 are not defined for controlled Pump #2: [\"foo\"]."
    @test logger.logs[3].level == Error
    @test logger.logs[3].message ==
          "Look ahead supplied for non-timeseries listen variable 'level' from listen node Basin #1."
    @test logger.logs[4].level == Error
    @test logger.logs[4].message ==
          "Look ahead for listen variable 'flow_rate' from listen node FlowBoundary #4 goes past timeseries end during simulation."
    @test logger.logs[5].level == Error
    @test logger.logs[5].message ==
          "Negative look ahead supplied for listen variable 'flow_rate' from listen node FlowBoundary #4."
end

@testitem "Pump/outlet flow rate sign validation" begin
    using Logging
    using Ribasim: NodeID, NodeType, ControlStateUpdate, ParameterUpdate

    logger = TestLogger()

    with_logger(logger) do
        @test_throws "Invalid Outlet flow rate(s)." Ribasim.Outlet(
            [NodeID(:Outlet, 1, 1)],
            NodeID[],
            [NodeID[]],
            [true],
            [-1.0],
            [NaN],
            [NaN],
            [NaN],
            Dict{Tuple{NodeID, String}, ControlStateUpdate}(),
            [false],
        )
    end

    @test length(logger.logs) == 1
    @test logger.logs[1].level == Error
    @test logger.logs[1].message == "Outlet #1 flow rates must be non-negative, found -1.0."

    logger = TestLogger()

    with_logger(logger) do
        @test_throws "Invalid Pump flow rate(s)." Ribasim.Pump(
            [NodeID(:Pump, 1, 1)],
            NodeID[],
            [NodeID[]],
            [true],
            [-1.0],
            [NaN],
            [NaN],
            Dict(
                (NodeID(:Pump, 1, 1), "foo") => ControlStateUpdate(
                    ParameterUpdate(:active, true),
                    [ParameterUpdate(:flow_rate, -1.0)],
                    ParameterUpdate[],
                ),
            ),
            [false],
        )
    end

    # Only the invalid control state flow_rate yields an error
    @test length(logger.logs) == 1
    @test logger.logs[1].level == Error
    @test logger.logs[1].message ==
          "Pump #1 flow rates must be non-negative, found -1.0 for control state 'foo'."
end

@testitem "Edge type validation" begin
    import SQLite
    using Logging

    toml_path =
        normpath(@__DIR__, "../../generated_testmodels/invalid_edge_types/ribasim.toml")
    @test ispath(toml_path)

    cfg = Ribasim.Config(toml_path)
    db_path = Ribasim.input_path(cfg, cfg.database)
    db = SQLite.DB(db_path)
    logger = TestLogger()
    with_logger(logger) do
        @test !Ribasim.valid_edge_types(db)
    end

    @test length(logger.logs) == 2
    @test logger.logs[1].level == Error
    @test logger.logs[1].message ==
          "Invalid edge type 'foo' for edge #0 from node #1 to node #2."
    @test logger.logs[2].level == Error
    @test logger.logs[2].message ==
          "Invalid edge type 'bar' for edge #1 from node #2 to node #3."
end

@testitem "Subgrid validation" begin
    using Ribasim: valid_subgrid, NodeID
    using Logging

    node_to_basin = Dict(NodeID(:Basin, 9, 1) => 1)

    logger = TestLogger()
    with_logger(logger) do
        @test !valid_subgrid(
            Int32(1),
            NodeID(:Basin, 10, 1),
            node_to_basin,
            [-1.0, 0.0],
            [-1.0, 0.0],
        )
    end

    @test length(logger.logs) == 1
    @test logger.logs[1].level == Error
    @test logger.logs[1].message == "The node_id of the Basin / subgrid does not exist."
    @test logger.logs[1].kwargs[:node_id] == NodeID(:Basin, 10, 1)
    @test logger.logs[1].kwargs[:subgrid_id] == 1

    logger = TestLogger()
    with_logger(logger) do
        @test !valid_subgrid(
            Int32(1),
            NodeID(:Basin, 9, 1),
            node_to_basin,
            [-1.0, 0.0, 0.0],
            [-1.0, 0.0, 0.0],
        )
    end

    @test length(logger.logs) == 2
    @test logger.logs[1].level == Error
    @test logger.logs[1].message ==
          "Basin / subgrid subgrid_id 1 has repeated basin levels, this cannot be interpolated."
    @test logger.logs[2].level == Error
    @test logger.logs[2].message ==
          "Basin / subgrid subgrid_id 1 has repeated element levels, this cannot be interpolated."
end

@testitem "negative demand" begin
    using Logging
    using DataInterpolations: LinearInterpolation
    using Ribasim: NodeID

    logger = TestLogger()

    with_logger(logger) do
        @test_throws "Invalid demand" Ribasim.UserDemand(
            [NodeID(:UserDemand, 1, 1)],
            NodeID[],
            NodeID[],
            [true],
            [0.0],
            [0.0],
            [0.0],
            [[LinearInterpolation([-5.0, -5.0], [-1.8, 1.8])]],
            [true],
            [0.0, -0.0],
            [0.9],
            [0.9],
            Int32[1],
        )
    end

    @test length(logger.logs) == 1
    @test logger.logs[1].level == Error
    @test logger.logs[1].message ==
          "Demand of UserDemand #1 with priority 1 should be non-negative"
end

@testitem "negative storage" begin
    import BasicModelInterface as BMI
    toml_path =
        normpath(@__DIR__, "../../generated_testmodels/linear_resistance/ribasim.toml")
    @test ispath(toml_path)
    dt = 1e10

    config = Ribasim.Config(
        toml_path;
        solver_algorithm = "Euler",
        solver_dt = dt,
        solver_saveat = Inf,
    )
    model = Ribasim.Model(config)
    @test_throws "Negative storages found at 2021-01-01T00:00:00." BMI.update_until(
        model,
        dt,
    )
end

@testitem "Convergence bottleneck" begin
    using IOCapture: capture
    toml_path =
        normpath(@__DIR__, "../../generated_testmodels/invalid_unstable/ribasim.toml")
    @test ispath(toml_path)
    (; output) = capture() do
        Ribasim.main(toml_path)
    end
    output = split(output, "\n")[(end - 4):end]
    @test startswith(
        output[1],
        "The following basins were identified as convergence bottlenecks",
    )
    @test startswith(output[2], "Basin #11")
    @test startswith(output[3], "Basin #31")
    @test startswith(output[4], "Basin #51")
end
