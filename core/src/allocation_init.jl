"""Find the edges from the main network to a subnetwork."""
function find_subnetwork_connections!(p::Parameters)::Nothing
    (; allocation, graph, allocation) = p
    n_priorities = length(allocation.priorities)
    (; subnetwork_demands, subnetwork_allocateds) = allocation
    # Find edges where the source node has subnetwork id 1 and the
    # destination node subnetwork id ≠1
    for node_id in graph[].node_ids[1]
        for outflow_id in outflow_ids(graph, node_id)
            if (graph[outflow_id].subnetwork_id != 1)
                main_network_source_edges =
                    get_main_network_connections(p, graph[outflow_id].subnetwork_id)
                edge = (node_id, outflow_id)
                push!(main_network_source_edges, edge)
                # Allocate memory for the demands and priorities
                # from the subnetwork via this edge
                subnetwork_demands[edge] = zeros(n_priorities)
                subnetwork_allocateds[edge] = zeros(n_priorities)
            end
        end
    end
    return nothing
end

"""
Get the fixed capacity of the edges in the subnetwork
"""
function get_subnetwork_capacity(
    p::Parameters,
    subnetwork_id::Int32,
)::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}}
    (; graph) = p
    node_ids_subnetwork = graph[].node_ids[subnetwork_id]

    dict = Dict{Tuple{NodeID, NodeID}, Float64}()
    capacity = JuMP.Containers.SparseAxisArray(dict)

    for edge_metadata in values(graph.edge_data)
        # Only flow edges are used for allocation
        if edge_metadata.type != EdgeType.flow
            continue
        end

        # If this edge is part of this subnetwork
        # edges between the main network and a subnetwork are added in add_subnetwork_connections!
        if edge_metadata.edge ⊆ node_ids_subnetwork
            id_src, id_dst = edge_metadata.edge

            capacity_edge = Inf

            # Find flow constraints for this edge
            if is_flow_constraining(id_src.type)
                node_src = getfield(p, graph[id_src].type)

                capacity_node_src = node_src.max_flow_rate[id_src.idx]
                capacity_edge = min(capacity_edge, capacity_node_src)
            end
            if is_flow_constraining(id_dst.type)
                node_dst = getfield(p, graph[id_dst].type)
                capacity_node_dst = node_dst.max_flow_rate[id_dst.idx]
                capacity_edge = min(capacity_edge, capacity_node_dst)
            end

            capacity[edge_metadata.edge] = capacity_edge

            # If allowed by the nodes from this edge,
            # allow allocation flow in opposite direction of the edge
            if !(
                is_flow_direction_constraining(id_src.type) ||
                is_flow_direction_constraining(id_dst.type)
            )
                capacity[reverse(edge_metadata.edge)] = capacity_edge
            end
        end
    end

    return capacity
end

const allocation_source_nodetypes =
    Set{NodeType.T}([NodeType.LevelBoundary, NodeType.FlowBoundary])

"""
Add the edges connecting the main network work to a subnetwork to both the main network
and subnetwork allocation network.
"""
function add_subnetwork_connections!(
    capacity::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}},
    p::Parameters,
    subnetwork_id::Int32,
)::Nothing
    (; allocation) = p
    (; main_network_connections) = allocation

    # Add the connections to the main network
    if is_main_network(subnetwork_id)
        for connections in main_network_connections
            for connection in connections
                capacity[connection...] = Inf
            end
        end
    else
        # Add the connections to this subnetwork
        for connection in get_main_network_connections(p, subnetwork_id)
            capacity[connection...] = Inf
        end
    end
    return nothing
end

"""
Get the capacity of all edges in the subnetwork in a JuMP
dictionary wrapper. The keys of this dictionary define
the which edges are used in the allocation optimization problem.
"""
function get_capacity(
    p::Parameters,
    subnetwork_id::Int32,
)::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}}
    capacity = get_subnetwork_capacity(p, subnetwork_id)
    add_subnetwork_connections!(capacity, p, subnetwork_id)

    if !valid_sources(p, capacity, subnetwork_id)
        error("Errors in sources in allocation network.")
    end

    return capacity
end

"""
Add the flow variables F to the allocation problem.
The variable indices are (edge_source_id, edge_dst_id).
Non-negativivity constraints are also immediately added to the flow variables.
"""
function add_variables_flow!(
    problem::JuMP.Model,
    capacity::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}},
)::Nothing
    edges = keys(capacity.data)
    problem[:F] = JuMP.@variable(problem, F[edge = edges] >= 0.0)
    return nothing
end

"""
Add the variables for supply/demand of a basin to the problem.
The variable indices are the node IDs of the basins in the subnetwork.
"""
function add_variables_basin!(
    problem::JuMP.Model,
    p::Parameters,
    subnetwork_id::Int32,
)::Nothing
    (; graph) = p
    node_ids_basin = [
        node_id for
        node_id in graph[].node_ids[subnetwork_id] if graph[node_id].type == :basin &&
        has_external_demand(graph, node_id, :level_demand)[1]
    ]
    problem[:F_basin_in] =
        JuMP.@variable(problem, F_basin_in[node_id = node_ids_basin,] >= 0.0)
    problem[:F_basin_out] =
        JuMP.@variable(problem, F_basin_out[node_id = node_ids_basin,] >= 0.0)
    return nothing
end

"""
Add the variables for supply/demand of the buffer of a node with a flow demand to the problem.
The variable indices are the node IDs of the nodes with a buffer in the subnetwork.
"""
function add_variables_flow_buffer!(
    problem::JuMP.Model,
    p::Parameters,
    subnetwork_id::Int32,
)::Nothing
    (; graph) = p

    # Collect the nodes in the subnetwork that have a flow demand
    node_ids_flow_demand = NodeID[]
    for node_id in graph[].node_ids[subnetwork_id]
        if has_external_demand(graph, node_id, :flow_demand)[1]
            push!(node_ids_flow_demand, node_id)
        end
    end

    problem[:F_flow_buffer_in] =
        JuMP.@variable(problem, F_flow_buffer_in[node_id = node_ids_flow_demand,] >= 0.0)
    problem[:F_flow_buffer_out] =
        JuMP.@variable(problem, F_flow_buffer_out[node_id = node_ids_flow_demand,] >= 0.0)
    return nothing
end

"""
Add the flow capacity constraints to the allocation problem.
Only finite capacities get a constraint.
The constraint indices are (edge_source_id, edge_dst_id).

Constraint:
flow over edge <= edge capacity
"""
function add_constraints_capacity!(
    problem::JuMP.Model,
    capacity::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}},
    p::Parameters,
    subnetwork_id::Int32,
)::Nothing
    main_network_source_edges = get_main_network_connections(p, subnetwork_id)
    F = problem[:F]

    # Find the edges within the subnetwork with finite capacity
    edge_ids_finite_capacity = Tuple{NodeID, NodeID}[]
    for (edge, c) in capacity.data
        if !isinf(c) && edge ∉ main_network_source_edges
            push!(edge_ids_finite_capacity, edge)
        end
    end

    problem[:capacity] = JuMP.@constraint(
        problem,
        [edge = edge_ids_finite_capacity],
        F[edge] <= capacity[edge...],
        base_name = "capacity"
    )
    return nothing
end

"""
Add capacity constraints to the outflow edge of UserDemand nodes.
The constraint indices are the UserDemand node IDs.

Constraint:
flow over UserDemand edge outflow edge <= cumulative return flow from previous priorities
"""
function add_constraints_user_source!(
    problem::JuMP.Model,
    p::Parameters,
    subnetwork_id::Int32,
)::Nothing
    (; graph) = p
    F = problem[:F]
    node_ids = graph[].node_ids[subnetwork_id]

    # Find the UserDemand nodes in the subnetwork
    node_ids_user = [node_id for node_id in node_ids if node_id.type == NodeType.UserDemand]

    problem[:source_user] = JuMP.@constraint(
        problem,
        [node_id = node_ids_user],
        F[(node_id, outflow_id(graph, node_id))] <= 0.0,
        base_name = "source_user"
    )
    return nothing
end

"""
Add the source constraints to the allocation problem.
The actual threshold values will be set before each allocation solve.
The constraint indices are (edge_source_id, edge_dst_id).

Constraint:
flow over source edge <= source flow in subnetwork
"""
function add_constraints_source!(
    problem::JuMP.Model,
    p::Parameters,
    subnetwork_id::Int32,
)::Nothing
    (; graph) = p
    edges_source = Tuple{NodeID, NodeID}[]
    F = problem[:F]

    # Find the edges in the whole model which are a source for
    # this subnetwork
    for edge_metadata in values(graph.edge_data)
        (; edge) = edge_metadata
        if graph[edge...].subnetwork_id_source == subnetwork_id
            push!(edges_source, edge)
        end
    end

    problem[:source] = JuMP.@constraint(
        problem,
        [edge_id = edges_source],
        F[edge_id] <= 0.0,
        base_name = "source"
    )
    return nothing
end

"""
Add the basin flow conservation constraints to the allocation problem.
The constraint indices are Basin node IDs.

Constraint:
sum(flows out of basin) == sum(flows into basin) + flow from storage and vertical fluxes
"""
function add_constraints_conservation_node!(
    problem::JuMP.Model,
    p::Parameters,
    subnetwork_id::Int32,
)::Nothing
    (; graph) = p
    F = problem[:F]
    F_basin_in = problem[:F_basin_in]
    F_basin_out = problem[:F_basin_out]
    F_flow_buffer_in = problem[:F_flow_buffer_in]
    F_flow_buffer_out = problem[:F_flow_buffer_out]
    node_ids = graph[].node_ids[subnetwork_id]

    inflows = Dict{NodeID, Set{JuMP.VariableRef}}()
    outflows = Dict{NodeID, Set{JuMP.VariableRef}}()

    edges_allocation = only(F.axes)

    for node_id in node_ids

        # No flow conservation constraint on sources/sinks
        is_source_sink = node_id.type in
        [NodeType.FlowBoundary, NodeType.LevelBoundary, NodeType.UserDemand]

        if is_source_sink
            continue
        end

        inflows_node = Set{JuMP.VariableRef}()
        outflows_node = Set{JuMP.VariableRef}()
        inflows[node_id] = inflows_node
        outflows[node_id] = outflows_node

        # Find in- and outflow allocation edges of this node
        for neighbor_id in inoutflow_ids(graph, node_id)
            edge_in = (neighbor_id, node_id)
            if edge_in in edges_allocation
                push!(inflows_node, F[edge_in])
            end
            edge_out = (node_id, neighbor_id)
            if edge_out in edges_allocation
                push!(outflows_node, F[edge_out])
            end
        end

        # If the node is a Basin with a level demand, add basin in- and outflow
        if has_external_demand(graph, node_id, :level_demand)[1]
            push!(inflows_node, F_basin_out[node_id])
            push!(outflows_node, F_basin_in[node_id])
        end

        # If the node has a buffer
        if has_external_demand(graph, node_id, :flow_demand)[1]
            push!(inflows_node, F_flow_buffer_out[node_id])
            push!(outflows_node, F_flow_buffer_in[node_id])
        end
    end

    # Only the node IDs with conservation constraints on them
    # Discard constraints of the form 0 == 0
    node_ids = [
        node_id for node_id in keys(inflows) if
        !(isempty(inflows[node_id]) && isempty(outflows[node_id]))
    ]

    problem[:flow_conservation] = JuMP.@constraint(
        problem,
        [node_id = node_ids],
        sum(inflows[node_id]) == sum(outflows[node_id]);
        base_name = "flow_conservation"
    )

    return nothing
end

"""
Add the Basin flow constraints to the allocation problem.
The constraint indices are the Basin node IDs.

Constraint:
flow out of basin <= basin capacity
"""
function add_constraints_basin_flow!(problem::JuMP.Model)::Nothing
    F_basin_out = problem[:F_basin_out]
    problem[:basin_outflow] = JuMP.@constraint(
        problem,
        [node_id = only(F_basin_out.axes)],
        F_basin_out[node_id] <= 0.0,
        base_name = "basin_outflow"
    )
    return nothing
end

"""
Add the buffer outflow constraints to the allocation problem.
The constraint indices are the node IDs of the nodes that have a flow demand.

Constraint:
flow out of buffer <= flow buffer capacity
"""
function add_constraints_buffer!(problem::JuMP.Model)::Nothing
    F_flow_buffer_out = problem[:F_flow_buffer_out]
    problem[:flow_buffer_outflow] = JuMP.@constraint(
        problem,
        [node_id = only(F_flow_buffer_out.axes)],
        F_flow_buffer_out[node_id] <= 0.0,
        base_name = "flow_buffer_outflow"
    )
    return nothing
end

"""
Add the flow demand node outflow constraints to the allocation problem.
The constraint indices are the node IDs of the nodes that have a flow demand.

Constraint:
flow out of node with flow demand <= ∞ if not at flow demand priority, 0.0 otherwise
"""
function add_constraints_flow_demand_outflow!(
    problem::JuMP.Model,
    p::Parameters,
    subnetwork_id::Int32,
)::Nothing
    (; graph) = p
    F = problem[:F]
    node_ids = graph[].node_ids[subnetwork_id]

    # Collect the node IDs in the subnetwork which have a flow demand
    node_ids_flow_demand = [
        node_id for
        node_id in node_ids if has_external_demand(graph, node_id, :flow_demand)[1]
    ]

    problem[:flow_demand_outflow] = JuMP.@constraint(
        problem,
        [node_id = node_ids_flow_demand],
        F[(node_id, outflow_id(graph, node_id))] <= 0.0,
        base_name = "flow_demand_outflow"
    )
    return nothing
end

"""
Construct the allocation problem for the current subnetwork as a JuMP model.
"""
function allocation_problem(
    p::Parameters,
    capacity::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}},
    subnetwork_id::Int32,
)::JuMP.Model
    optimizer = JuMP.optimizer_with_attributes(
        HiGHS.Optimizer,
        "log_to_console" => false,
        "objective_bound" => 0.0,
        "time_limit" => 60.0,
        "random_seed" => 0,
        "primal_feasibility_tolerance" => 1e-5,
        "dual_feasibility_tolerance" => 1e-5,
    )
    problem = JuMP.direct_model(optimizer)

    # Add variables to problem
    add_variables_flow!(problem, capacity)
    add_variables_basin!(problem, p, subnetwork_id)
    add_variables_flow_buffer!(problem, p, subnetwork_id)

    # Add constraints to problem
    add_constraints_conservation_node!(problem, p, subnetwork_id)

    add_constraints_capacity!(problem, capacity, p, subnetwork_id)
    add_constraints_source!(problem, p, subnetwork_id)
    add_constraints_user_source!(problem, p, subnetwork_id)
    add_constraints_basin_flow!(problem)
    add_constraints_flow_demand_outflow!(problem, p, subnetwork_id)
    add_constraints_buffer!(problem)

    return problem
end

"""
Construct the JuMP.jl problem for allocation.

Inputs
------
subnetwork_id: the ID of this allocation network
p: Ribasim problem parameters
Δt_allocation: The timestep between successive allocation solves

Outputs
-------
An AllocationModel object.
"""
function AllocationModel(
    subnetwork_id::Int32,
    p::Parameters,
    Δt_allocation::Float64,
)::AllocationModel
    capacity = get_capacity(p, subnetwork_id)
    problem = allocation_problem(p, capacity, subnetwork_id)

    return AllocationModel(; subnetwork_id, capacity, problem, Δt_allocation)
end
