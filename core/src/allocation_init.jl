"""Find the edges from the main network to a subnetwork."""
function find_subnetwork_connections!(p::Parameters)::Nothing
    (; allocation, graph, allocation) = p
    n_priorities = length(allocation.priorities)
    (; subnetwork_demands, subnetwork_allocateds) = allocation
    for node_id in graph[].node_ids[1]
        for outflow_id in outflow_ids(graph, node_id)
            if graph[outflow_id].allocation_network_id != 1
                main_network_source_edges =
                    get_main_network_connections(p, graph[outflow_id].allocation_network_id)
                edge = (node_id, outflow_id)
                push!(main_network_source_edges, edge)
                subnetwork_demands[edge] = zeros(n_priorities)
                subnetwork_allocateds[edge] = zeros(n_priorities)
            end
        end
    end
    return nothing
end

"""
Find all nodes in the subnetwork which will be used in the allocation network.
Some nodes are skipped to optimize allocation optimization.
"""
function allocation_graph_used_nodes!(p::Parameters, allocation_network_id::Int32)::Nothing
    (; graph, basin, fractional_flow, allocation) = p
    (; main_network_connections) = allocation

    node_ids = graph[].node_ids[allocation_network_id]
    used_nodes = Set{NodeID}()
    for node_id in node_ids
        use_node = false
        has_fractional_flow_outneighbors =
            get_fractional_flow_connected_basins(node_id, basin, fractional_flow, graph)[3]
        if node_id.type in [NodeType.UserDemand, NodeType.Basin, NodeType.Terminal]
            use_node = true
        elseif has_fractional_flow_outneighbors
            use_node = true
        elseif has_external_demand(graph, node_id, :flow_demand)[1]
            use_node = true
        end

        if use_node
            push!(used_nodes, node_id)
        end
    end

    # Add nodes in the allocation network for nodes connected to the source edges
    # One of these nodes can be outside the subnetwork, as long as the edge
    # connects to the subnetwork
    edges_source = graph[].edges_source
    for edge_metadata in get(edges_source, allocation_network_id, Set{EdgeMetadata}())
        (; from_id, to_id) = edge_metadata
        push!(used_nodes, from_id)
        push!(used_nodes, to_id)
    end

    filter!(in(used_nodes), node_ids)

    # For the main network, include nodes that connect the main network to a subnetwork
    # (also includes nodes not in the main network in the input)
    if is_main_network(allocation_network_id)
        for connections_subnetwork in main_network_connections
            for connection in connections_subnetwork
                union!(node_ids, connection)
            end
        end
    end
    return nothing
end

"""
Find out whether the given edge is a source for an allocation network.
"""
function is_allocation_source(graph::MetaGraph, id_src::NodeID, id_dst::NodeID)::Bool
    return haskey(graph, id_src, id_dst) &&
           graph[id_src, id_dst].allocation_network_id_source != 0
end

"""
Add to the edge metadata that the given edge is used for allocation flow.
If the edge does not exist, it is created.
"""
function indicate_allocation_flow!(
    graph::MetaGraph,
    node_ids::AbstractVector{NodeID},
)::Nothing
    id_src = first(node_ids)
    id_dst = last(node_ids)

    if !haskey(graph, id_src, id_dst)
        edge_metadata = EdgeMetadata(0, EdgeType.none, 0, id_src, id_dst, true, node_ids)
    else
        edge_metadata = graph[id_src, id_dst]
        edge_metadata = @set edge_metadata.allocation_flow = true
        edge_metadata = @set edge_metadata.node_ids = node_ids
    end
    graph[id_src, id_dst] = edge_metadata
    return nothing
end

"""
This loop finds allocation network edges in several ways:
- Between allocation network nodes whose equivalent in the subnetwork are directly connected
- Between allocation network nodes whose equivalent in the subnetwork are connected
  with one or more allocation network nodes in between
"""
function find_allocation_graph_edges!(
    p::Parameters,
    allocation_network_id::Int32,
)::Tuple{
    Vector{Vector{NodeID}},
    JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}},
}
    (; graph) = p

    edges_composite = Vector{NodeID}[]
    dict = Dict{Tuple{NodeID, NodeID}, Float64}()
    capacity = JuMP.Containers.SparseAxisArray(dict)

    node_ids = graph[].node_ids[allocation_network_id]
    edge_ids = Set{Tuple{NodeID, NodeID}}()
    graph[].edge_ids[allocation_network_id] = edge_ids

    # Loop over all IDs in the model
    for node_id in labels(graph)
        inneighbor_ids = inflow_ids(graph, node_id)
        outneighbor_ids = outflow_ids(graph, node_id)
        neighbor_ids = inoutflow_ids(graph, node_id)

        # If the current node_id is in the current subnetwork
        if node_id in node_ids

            # Capacity for nodes that have both a flow demand and a max flow rate
            if has_external_demand(graph, node_id, :flow_demand)[1]
                node = getfield(p, graph[node_id].type)
                if is_flow_constraining(node)
                    node_idx = findsorted(node.node_id, node_id)
                    capacity[inflow_id(graph, node_id), node_id] =
                        node.max_flow_rate[node_idx]
                end
            end

            # Direct connections in the subnetwork between nodes that
            # are in the allocation network
            for inneighbor_id in inneighbor_ids
                if inneighbor_id in node_ids
                    # The opposite of source edges must not be made
                    if is_allocation_source(graph, node_id, inneighbor_id)
                        continue
                    end
                    indicate_allocation_flow!(graph, [inneighbor_id, node_id])
                    push!(edge_ids, (inneighbor_id, node_id))
                    # These direct connections cannot have capacity constraints
                    capacity[node_id, inneighbor_id] = Inf
                end
            end
            # Direct connections in the subnetwork between nodes that
            # are in the allocation network
            for outneighbor_id in outneighbor_ids
                if outneighbor_id in node_ids
                    # The opposite of source edges must not be made
                    if is_allocation_source(graph, outneighbor_id, node_id)
                        continue
                    end
                    indicate_allocation_flow!(graph, [node_id, outneighbor_id])
                    push!(edge_ids, (node_id, outneighbor_id))
                    # if subnetwork_outneighbor_id in user_demand.node_id: Capacity depends on user demand at a given priority
                    # else: These direct connections cannot have capacity constraints
                    capacity[node_id, outneighbor_id] = Inf
                end
            end

        elseif graph[node_id].allocation_network_id == allocation_network_id

            # Try to find an existing allocation network composite edge to add the current subnetwork_node_id to
            found_edge = false
            for edge_composite in edges_composite
                if edge_composite[1] in neighbor_ids
                    pushfirst!(edge_composite, node_id)
                    found_edge = true
                    break
                elseif edge_composite[end] in neighbor_ids
                    push!(edge_composite, node_id)
                    found_edge = true
                    break
                end
            end

            # Start a new allocation network composite edge if no existing edge to append to was found
            if !found_edge
                push!(edges_composite, [node_id])
            end
        end
    end
    return edges_composite, capacity
end

"""
For the composite allocation network edges:
- Find out whether they are connected to allocation network nodes on both ends
- Compute their capacity
- Find out their allowed flow direction(s)
"""
function process_allocation_graph_edges!(
    capacity::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}},
    edges_composite::Vector{Vector{NodeID}},
    p::Parameters,
    allocation_network_id::Int32,
)::Nothing
    (; graph) = p
    node_ids = graph[].node_ids[allocation_network_id]
    edge_ids = graph[].edge_ids[allocation_network_id]

    for edge_composite in edges_composite
        # Find allocation network node connected to this edge on the first end
        node_id_1 = nothing
        neighbors_side_1 = inoutflow_ids(graph, edge_composite[1])
        for neighbor_node_id in neighbors_side_1
            if neighbor_node_id in node_ids
                node_id_1 = neighbor_node_id
                pushfirst!(edge_composite, neighbor_node_id)
                break
            end
        end

        # No connection to an allocation node found on this side, so edge is discarded
        if isnothing(node_id_1)
            continue
        end

        # Find allocation network node connected to this edge on the second end
        node_id_2 = nothing
        neighbors_side_2 = inoutflow_ids(graph, edge_composite[end])
        for neighbor_node_id in neighbors_side_2
            if neighbor_node_id in node_ids
                node_id_2 = neighbor_node_id
                # Make sure this allocation network node is distinct from the other one
                if node_id_2 ≠ node_id_1
                    push!(edge_composite, neighbor_node_id)
                    break
                end
            end
        end

        # No connection to allocation network node found on this side, so edge is discarded
        if isnothing(node_id_2)
            continue
        end

        if node_id_1 == node_id_2
            continue
        end

        # Find capacity of this composite allocation network edge
        positive_flow = true
        negative_flow = true
        edge_capacity = Inf
        # The start and end subnetwork nodes of the composite allocation network
        # edge are now nodes that have an equivalent in the allocation network,
        # these do not constrain the composite edge capacity
        for (node_id_1, node_id_2, node_id_3) in IterTools.partition(edge_composite, 3, 1)
            node = getfield(p, graph[node_id_2].type)

            # Find flow constraints
            if is_flow_constraining(node)
                problem_node_idx = findsorted(node.node_id, node_id_2)
                edge_capacity = min(edge_capacity, node.max_flow_rate[problem_node_idx])
            end

            # Find flow direction constraints
            if is_flow_direction_constraining(node)
                inneighbor_node_id = inflow_id(graph, node_id_2)

                if inneighbor_node_id == node_id_1
                    negative_flow = false
                elseif inneighbor_node_id == node_id_3
                    positive_flow = false
                end
            end
        end

        # Add composite allocation network edge(s)
        if positive_flow
            indicate_allocation_flow!(graph, edge_composite)
            capacity[node_id_1, node_id_2] = edge_capacity
            push!(edge_ids, (node_id_1, node_id_2))
        end

        if negative_flow
            indicate_allocation_flow!(graph, reverse(edge_composite))
            capacity[node_id_2, node_id_1] = edge_capacity
            push!(edge_ids, (node_id_2, node_id_1))
        end
    end
    return nothing
end

const allocation_source_nodetypes =
    Set{NodeType.T}([NodeType.LevelBoundary, NodeType.FlowBoundary])

"""
Add the edges connecting the main network work to a subnetwork to both the main network
and subnetwork allocation network.
"""
function add_subnetwork_connections!(p::Parameters, allocation_network_id::Int32)::Nothing
    (; graph, allocation) = p
    (; main_network_connections) = allocation
    edge_ids = graph[].edge_ids[allocation_network_id]

    if is_main_network(allocation_network_id)
        for connections in main_network_connections
            union!(edge_ids, connections)
        end
    else
        union!(edge_ids, get_main_network_connections(p, allocation_network_id))
    end
    return nothing
end

"""
Build the graph used for the allocation problem.
"""
function allocation_graph(
    p::Parameters,
    allocation_network_id::Int32,
)::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}}
    # Find out which nodes in the subnetwork are used in the allocation network
    allocation_graph_used_nodes!(p, allocation_network_id)

    # Find the edges in the allocation network
    edges_composite, capacity = find_allocation_graph_edges!(p, allocation_network_id)

    # Process the edges in the allocation network
    process_allocation_graph_edges!(capacity, edges_composite, p, allocation_network_id)
    add_subnetwork_connections!(p, allocation_network_id)

    if !valid_sources(p, allocation_network_id)
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
    p::Parameters,
    allocation_network_id::Int32,
)::Nothing
    (; graph) = p
    edge_ids = graph[].edge_ids[allocation_network_id]
    problem[:F] = JuMP.@variable(problem, F[edge_id = edge_ids,] >= 0.0)
    return nothing
end

"""
Add the variables for supply/demand of a basin to the problem.
The variable indices are the node_ids of the basins with a level demand in the subnetwork.
"""
function add_variables_basin!(
    problem::JuMP.Model,
    p::Parameters,
    allocation_network_id::Int32,
)::Nothing
    (; graph) = p
    node_ids_basin = [
        node_id for node_id in graph[].node_ids[allocation_network_id] if
        graph[node_id].type == :basin
    ]
    problem[:F_basin_in] =
        JuMP.@variable(problem, F_basin_in[node_id = node_ids_basin,] >= 0.0)
    problem[:F_basin_out] =
        JuMP.@variable(problem, F_basin_out[node_id = node_ids_basin,] >= 0.0)
    return nothing
end

"""
Add the variables for supply/demand of a node with a flow demand to the problem.
The variable indices are the node_ids of the nodes with a flow demand in the subnetwork.
"""
function add_variables_flow_buffer!(
    problem::JuMP.Model,
    p::Parameters,
    allocation_network_id::Int32,
)::Nothing
    (; graph) = p

    node_ids_flow_demand = NodeID[]

    for node_id in graph[].node_ids[allocation_network_id]
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
Certain allocation distribution types use absolute values in the objective function.
Since most optimization packages do not support the absolute value function directly,
New variables are introduced that act as the absolute value of an expression by
posing the appropriate constraints.
"""
function add_variables_absolute_value!(
    problem::JuMP.Model,
    p::Parameters,
    allocation_network_id::Int32,
)::Nothing
    (; graph, allocation) = p
    (; main_network_connections) = allocation

    node_ids = graph[].node_ids[allocation_network_id]
    node_ids_user_demand = NodeID[]
    node_ids_level_demand = NodeID[]
    node_ids_flow_demand = NodeID[]

    for node_id in node_ids
        type = node_id.type
        if type == NodeType.UserDemand
            push!(node_ids_user_demand, node_id)
        elseif type == NodeType.Basin
            push!(node_ids_level_demand, node_id)
        elseif has_external_demand(graph, node_id, :flow_demand)[1]
            push!(node_ids_flow_demand, node_id)
        end
    end

    # For the main network, connections to subnetworks are treated as UserDemands
    if is_main_network(allocation_network_id)
        for connections_subnetwork in main_network_connections
            for connection in connections_subnetwork
                push!(node_ids_user_demand, connection[2])
            end
        end
    end

    problem[:F_abs_user_demand] =
        JuMP.@variable(problem, F_abs_user_demand[node_id = node_ids_user_demand])
    problem[:F_abs_level_demand] =
        JuMP.@variable(problem, F_abs_level_demand[node_id = node_ids_level_demand])
    problem[:F_abs_flow_demand] =
        JuMP.@variable(problem, F_abs_flow_demand[node_id = node_ids_flow_demand])

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
    allocation_network_id::Int32,
)::Nothing
    (; graph) = p
    main_network_source_edges = get_main_network_connections(p, allocation_network_id)
    F = problem[:F]
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
    allocation_network_id::Int32,
)::Nothing
    (; graph) = p
    F = problem[:F]
    node_ids = graph[].node_ids[allocation_network_id]
    node_ids_user = [node_id for node_id in node_ids if node_id.type == NodeType.UserDemand]

    problem[:source_user] = JuMP.@constraint(
        problem,
        [node_id = node_ids_user],
        F[(node_id, outflow_id(graph, node_id))] <= 0.0
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
    allocation_network_id::Int32,
)::Nothing
    (; graph) = p
    edge_ids = graph[].edge_ids[allocation_network_id]
    edge_ids_source = [
        edge_id for edge_id in edge_ids if
        graph[edge_id...].allocation_network_id_source == allocation_network_id
    ]
    F = problem[:F]
    problem[:source] = JuMP.@constraint(
        problem,
        [edge_id = edge_ids_source],
        F[edge_id] <= 0.0,
        base_name = "source"
    )
    return nothing
end

"""
Get the inneighbors of the given ID such that the connecting edge
is an allocation flow edge.
"""
function inflow_ids_allocation(graph::MetaGraph, node_id::NodeID)
    inflow_ids = NodeID[]
    for inneighbor_id in inneighbor_labels(graph, node_id)
        if graph[inneighbor_id, node_id].allocation_flow
            push!(inflow_ids, inneighbor_id)
        end
    end
    return inflow_ids
end

"""
Get the outneighbors of the given ID such that the connecting edge
is an allocation flow edge.
"""
function outflow_ids_allocation(graph::MetaGraph, node_id::NodeID)
    outflow_ids = NodeID[]
    for outneighbor_id in outneighbor_labels(graph, node_id)
        if graph[node_id, outneighbor_id].allocation_flow
            push!(outflow_ids, outneighbor_id)
        end
    end
    return outflow_ids
end

function get_basin_inflow(
    problem::JuMP.Model,
    node_id::NodeID,
)::Union{JuMP.VariableRef, Float64}
    F_basin_in = problem[:F_basin_in]
    return if node_id in only(F_basin_in.axes)
        F_basin_in[node_id]
    else
        0.0
    end
end

function get_basin_outflow(
    problem::JuMP.Model,
    node_id::NodeID,
)::Union{JuMP.VariableRef, Float64}
    F_basin_out = problem[:F_basin_out]
    return if node_id in only(F_basin_out.axes)
        F_basin_out[node_id]
    else
        0.0
    end
end

"""
Add the subnetwork inlet flow conservation constraints to the allocation problem.
The constraint indices are node IDs subnetwork inlet edge dst IDs.

Constraint:
sum(flows into node) == sum(flows out of node)
"""
function add_constraints_conservation_subnetwork!(
    problem::JuMP.Model,
    p::Parameters,
    allocation_network_id::Int32,
)::Nothing
    (; graph) = p
    F = problem[:F]
    node_ids_inlets = [
        edge[2] for edge in get_main_network_connections(p, allocation_network_id) if
        edge[2].type != NodeType.Basin
    ]
    problem[:flow_conservation_inlets] = JuMP.@constraint(
        problem,
        [node_id = node_ids_inlets],
        sum([
            F[(node_id, outneighbor_id)] for
            outneighbor_id in outflow_ids_allocation(graph, node_id)
        ]) == sum([
            F[(inneighbor_id, node_id)] for
            inneighbor_id in inflow_ids_allocation(graph, node_id)
        ]),
        base_name = "flow_conservation_inlet"
    )
    return nothing
end

"""
Add the conservation constraints for connector nodes with a flow demand to the allocation problem.
The constraint indices are node IDs of the nodes with the flow demand
(so not the IDs of the FlowDemand nodes).

Constraint:
flow into node + flow out of buffer = flow out of node + flow into buffer
"""
function add_constraints_conservation_flow_demand!(
    problem::JuMP.Model,
    p::Parameters,
    allocation_network_id::Int32,
)::Nothing
    F = problem[:F]
    F_flow_buffer_in = problem[:F_flow_buffer_in]
    F_flow_buffer_out = problem[:F_flow_buffer_out]
    (; graph) = p
    node_ids = graph[].node_ids[allocation_network_id]
    node_ids_flow_demand = [
        node_id for
        node_id in node_ids if has_external_demand(graph, node_id, :flow_demand)[1]
    ]
    problem[:flow_conservation_flow_demand] = JuMP.@constraint(
        problem,
        [node_id = node_ids_flow_demand],
        F[(node_id, only(outflow_ids_allocation(graph, node_id)))] +
        F_flow_buffer_in[node_id] ==
        F[(only(inflow_ids_allocation(graph, node_id)), node_id)] +
        F_flow_buffer_out[node_id],
        base_name = "flow_conservation_flow_demand"
    )
    return nothing
end

"""
Add the basin flow conservation constraints to the allocation problem.
The constraint indices are Basin node IDs.

Constraint:
sum(flows out of basin) == sum(flows into basin) + flow from storage and vertical fluxes
"""
function add_constraints_conservation_basin!(
    problem::JuMP.Model,
    p::Parameters,
    allocation_network_id::Int32,
)::Nothing
    (; graph) = p
    F = problem[:F]
    node_ids = graph[].node_ids[allocation_network_id]

    node_ids_basin = [node_id for node_id in node_ids if node_id.type == NodeType.Basin]
    problem[:flow_conservation_basin] = JuMP.@constraint(
        problem,
        [node_id = node_ids_basin],
        get_basin_inflow(problem, node_id) + sum([
            F[(node_id, outneighbor_id)] for
            outneighbor_id in outflow_ids_allocation(graph, node_id)
        ]) ==
        get_basin_outflow(problem, node_id) + sum([
            F[(inneighbor_id, node_id)] for
            inneighbor_id in inflow_ids_allocation(graph, node_id)
        ]),
        base_name = "flow_conservation_basin"
    )
    return nothing
end

"""
Minimizing |expr| can be achieved by introducing a new variable expr_abs
and posing the following constraints:
expr_abs >= expr
expr_abs >= -expr
"""
function add_constraints_absolute_value!(
    problem::JuMP.Model,
    flow_per_node::Dict{NodeID, JuMP.VariableRef},
    F_abs::JuMP.Containers.DenseAxisArray,
    variable_type::String,
)::Nothing
    # Example demand
    d = 2.0

    node_ids = only(F_abs.axes)

    # These constraints together make sure that F_abs_* acts as the absolute
    # value F_abs_* = |x| where x = F-d (here for example d = 2)
    base_name = "abs_positive_$variable_type"
    problem[Symbol(base_name)] = JuMP.@constraint(
        problem,
        [node_id = node_ids],
        F_abs[node_id] >= (flow_per_node[node_id] - d),
        base_name = base_name
    )
    base_name = "abs_negative_$variable_type"
    problem[Symbol(base_name)] = JuMP.@constraint(
        problem,
        [node_id = node_ids],
        F_abs[node_id] >= -(flow_per_node[node_id] - d),
        base_name = base_name
    )

    return nothing
end

"""
Add constraints so that variables F_abs_user_demand act as the
absolute value of the expression comparing flow to a UserDemand to its demand.
"""
function add_constraints_absolute_value_user_demand!(
    problem::JuMP.Model,
    p::Parameters,
)::Nothing
    (; graph) = p

    F = problem[:F]
    F_abs_user_demand = problem[:F_abs_user_demand]

    flow_per_node = Dict(
        node_id => F[(only(inflow_ids_allocation(graph, node_id)), node_id)] for
        node_id in only(F_abs_user_demand.axes)
    )

    add_constraints_absolute_value!(
        problem,
        flow_per_node,
        F_abs_user_demand,
        "user_demand",
    )

    return nothing
end

"""
Add constraints so that variables F_abs_level_demand act as the
absolute value of the expression comparing flow to a basin to its demand.
"""
function add_constraints_absolute_value_level_demand!(problem::JuMP.Model)::Nothing
    F_basin_in = problem[:F_basin_in]
    F_abs_level_demand = problem[:F_abs_level_demand]
    flow_per_node =
        Dict(node_id => F_basin_in[node_id] for node_id in only(F_abs_level_demand.axes))

    add_constraints_absolute_value!(problem, flow_per_node, F_abs_level_demand, "basin")

    return nothing
end

"""
Add constraints so that variables F_abs_flow_demand act as the
absolute value of the expression comparing flow to a flow buffer to the flow demand.
"""
function add_constraints_absolute_value_flow_demand!(problem::JuMP.Model)::Nothing
    F_flow_buffer_in = problem[:F_flow_buffer_in]
    F_abs_flow_demand = problem[:F_abs_flow_demand]
    flow_per_node = Dict(
        node_id => F_flow_buffer_in[node_id] for node_id in only(F_abs_flow_demand.axes)
    )

    add_constraints_absolute_value!(
        problem,
        flow_per_node,
        F_abs_flow_demand,
        "flow_demand",
    )
    return nothing
end

"""
Add the fractional flow constraints to the allocation problem.
The constraint indices are allocation edges over a fractional flow node.

Constraint:
flow after fractional_flow node <= fraction * inflow
"""
function add_constraints_fractional_flow!(
    problem::JuMP.Model,
    p::Parameters,
    allocation_network_id::Int32,
)::Nothing
    (; graph, fractional_flow) = p
    F = problem[:F]
    node_ids = graph[].node_ids[allocation_network_id]

    edges_to_fractional_flow = Tuple{NodeID, NodeID}[]
    fractions = Dict{Tuple{NodeID, NodeID}, Float64}()
    inflows = Dict{NodeID, JuMP.AffExpr}()
    for node_id in node_ids
        for outflow_id_ in outflow_ids(graph, node_id)
            if outflow_id_.type == NodeType.FractionalFlow
                # The fractional flow nodes themselves are not represented in
                # the allocation network
                dst_id = outflow_id(graph, outflow_id_)
                # For now only consider fractional flow nodes which end in a basin
                if haskey(graph, node_id, dst_id) && dst_id.type == NodeType.Basin
                    edge = (node_id, dst_id)
                    push!(edges_to_fractional_flow, edge)
                    node_idx = findsorted(fractional_flow.node_id, outflow_id_)
                    fractions[edge] = fractional_flow.fraction[node_idx]
                    inflows[node_id] = sum([
                        F[(inflow_id_, node_id)] for
                        inflow_id_ in inflow_ids(graph, node_id)
                    ])
                end
            end
        end
    end

    if !isempty(edges_to_fractional_flow)
        problem[:fractional_flow] = JuMP.@constraint(
            problem,
            [edge = edges_to_fractional_flow],
            F[edge] <= fractions[edge] * inflows[edge[1]],
            base_name = "fractional_flow"
        )
    end
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
    allocation_network_id::Int32,
)::Nothing
    (; graph) = p
    F = problem[:F]
    node_ids = graph[].node_ids[allocation_network_id]
    node_ids_flow_demand = [
        node_id for
        node_id in node_ids if has_external_demand(graph, node_id, :flow_demand)[1]
    ]
    problem[:flow_demand_outflow] = JuMP.@constraint(
        problem,
        [node_id = node_ids_flow_demand],
        F[(node_id, only(outflow_ids_allocation(graph, node_id)))] <= 0.0,
        base_name = "flow_demand_outflow"
    )
    return nothing
end

"""
Construct the allocation problem for the current subnetwork as a JuMP.jl model.
"""
function allocation_problem(
    p::Parameters,
    capacity::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}},
    allocation_network_id::Int32,
)::JuMP.Model
    optimizer = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "log_to_console" => false)
    problem = JuMP.direct_model(optimizer)

    # Add variables to problem
    add_variables_flow!(problem, p, allocation_network_id)
    add_variables_basin!(problem, p, allocation_network_id)
    add_variables_absolute_value!(problem, p, allocation_network_id)
    add_variables_flow_buffer!(problem, p, allocation_network_id)

    # Add constraints to problem
    add_constraints_conservation_basin!(problem, p, allocation_network_id)
    add_constraints_conservation_flow_demand!(problem, p, allocation_network_id)
    add_constraints_conservation_subnetwork!(problem, p, allocation_network_id)

    add_constraints_absolute_value_user_demand!(problem, p)
    add_constraints_absolute_value_flow_demand!(problem)
    add_constraints_absolute_value_level_demand!(problem)

    add_constraints_capacity!(problem, capacity, p, allocation_network_id)
    add_constraints_source!(problem, p, allocation_network_id)
    add_constraints_user_source!(problem, p, allocation_network_id)
    add_constraints_fractional_flow!(problem, p, allocation_network_id)
    add_constraints_basin_flow!(problem)
    add_constraints_flow_demand_outflow!(problem, p, allocation_network_id)
    add_constraints_buffer!(problem)

    return problem
end

"""
Construct the JuMP.jl problem for allocation.

Inputs
------
allocation_network_id: the ID of this allocation network
p: Ribasim problem parameters
Δt_allocation: The timestep between successive allocation solves

Outputs
-------
An AllocationModel object.
"""
function AllocationModel(
    allocation_network_id::Int32,
    p::Parameters,
    Δt_allocation::Float64,
)::AllocationModel
    # Add allocation network data to the model MetaGraph
    capacity = allocation_graph(p, allocation_network_id)

    # The JuMP.jl allocation problem
    problem = allocation_problem(p, capacity, allocation_network_id)

    return AllocationModel(allocation_network_id, capacity, problem, Δt_allocation)
end
