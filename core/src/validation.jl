# Allowed types for downstream (to_node_id) nodes given the type of the upstream (from_node_id) node
neighbortypes(nodetype::Symbol) = neighbortypes(Val(config.snake_case(nodetype)))
neighbortypes(::Val{:pump}) = Set((:basin, :terminal, :level_boundary))
neighbortypes(::Val{:outlet}) = Set((:basin, :terminal, :level_boundary))
neighbortypes(::Val{:user_demand}) = Set((:basin, :terminal, :level_boundary))
neighbortypes(::Val{:level_demand}) = Set((:basin,))
neighbortypes(::Val{:basin}) = Set((
    :linear_resistance,
    :tabulated_rating_curve,
    :manning_resistance,
    :pump,
    :outlet,
    :user_demand,
))
neighbortypes(::Val{:terminal}) = Set{Symbol}() # only endnode
neighbortypes(::Val{:flow_boundary}) = Set((:basin, :terminal, :level_boundary))
neighbortypes(::Val{:level_boundary}) =
    Set((:linear_resistance, :pump, :outlet, :tabulated_rating_curve))
neighbortypes(::Val{:linear_resistance}) = Set((:basin, :level_boundary))
neighbortypes(::Val{:manning_resistance}) = Set((:basin,))
neighbortypes(::Val{:continuous_control}) = Set((:pump, :outlet))
neighbortypes(::Val{:discrete_control}) = Set((
    :pump,
    :outlet,
    :tabulated_rating_curve,
    :linear_resistance,
    :manning_resistance,
    :pid_control,
))
neighbortypes(::Val{:pid_control}) = Set((:pump, :outlet))
neighbortypes(::Val{:tabulated_rating_curve}) = Set((:basin, :terminal, :level_boundary))
neighbortypes(::Val{:flow_demand}) =
    Set((:linear_resistance, :manning_resistance, :tabulated_rating_curve, :pump, :outlet))
neighbortypes(::Any) = Set{Symbol}()

# Allowed number of inneighbors and outneighbors per node type
struct n_neighbor_bounds
    in_min::Int
    in_max::Int
    out_min::Int
    out_max::Int
end

n_neighbor_bounds_flow(nodetype::Symbol) = n_neighbor_bounds_flow(Val(nodetype))
n_neighbor_bounds_flow(::Val{:Basin}) = n_neighbor_bounds(0, typemax(Int), 0, typemax(Int))
n_neighbor_bounds_flow(::Val{:LinearResistance}) = n_neighbor_bounds(1, 1, 1, 1)
n_neighbor_bounds_flow(::Val{:ManningResistance}) = n_neighbor_bounds(1, 1, 1, 1)
n_neighbor_bounds_flow(::Val{:TabulatedRatingCurve}) = n_neighbor_bounds(1, 1, 1, 1)
n_neighbor_bounds_flow(::Val{:LevelBoundary}) =
    n_neighbor_bounds(0, typemax(Int), 0, typemax(Int))
n_neighbor_bounds_flow(::Val{:FlowBoundary}) = n_neighbor_bounds(0, 0, 1, typemax(Int))
n_neighbor_bounds_flow(::Val{:Pump}) = n_neighbor_bounds(1, 1, 1, 1)
n_neighbor_bounds_flow(::Val{:Outlet}) = n_neighbor_bounds(1, 1, 1, 1)
n_neighbor_bounds_flow(::Val{:Terminal}) = n_neighbor_bounds(1, typemax(Int), 0, 0)
n_neighbor_bounds_flow(::Val{:PidControl}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_flow(::Val{:ContinuousControl}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_flow(::Val{:DiscreteControl}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_flow(::Val{:UserDemand}) = n_neighbor_bounds(1, 1, 1, 1)
n_neighbor_bounds_flow(::Val{:LevelDemand}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_flow(::Val{:FlowDemand}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_flow(nodetype) =
    error("'n_neighbor_bounds_flow' not defined for $nodetype.")

n_neighbor_bounds_control(nodetype::Symbol) = n_neighbor_bounds_control(Val(nodetype))
n_neighbor_bounds_control(::Val{:Basin}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:LinearResistance}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:ManningResistance}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:TabulatedRatingCurve}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:LevelBoundary}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_control(::Val{:FlowBoundary}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_control(::Val{:Pump}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:Outlet}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:Terminal}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_control(::Val{:PidControl}) = n_neighbor_bounds(0, 1, 1, 1)
n_neighbor_bounds_control(::Val{:ContinuousControl}) =
    n_neighbor_bounds(0, 0, 1, typemax(Int))
n_neighbor_bounds_control(::Val{:DiscreteControl}) =
    n_neighbor_bounds(0, 0, 1, typemax(Int))
n_neighbor_bounds_control(::Val{:UserDemand}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_control(::Val{:LevelDemand}) = n_neighbor_bounds(0, 0, 1, typemax(Int))
n_neighbor_bounds_control(::Val{:FlowDemand}) = n_neighbor_bounds(0, 0, 1, 1)
n_neighbor_bounds_control(nodetype) =
    error("'n_neighbor_bounds_control' not defined for $nodetype.")

controllablefields(nodetype::Symbol) = controllablefields(Val(nodetype))
controllablefields(::Val{:LinearResistance}) = Set((:active, :resistance))
controllablefields(::Val{:ManningResistance}) = Set((:active, :manning_n))
controllablefields(::Val{:TabulatedRatingCurve}) = Set((:active, :table))
controllablefields(::Val{:Pump}) = Set((:active, :flow_rate))
controllablefields(::Val{:Outlet}) = Set((:active, :flow_rate))
controllablefields(::Val{:PidControl}) =
    Set((:active, :target, :proportional, :integral, :derivative))
controllablefields(nodetype) = Set{Symbol}()

function variable_names(s::Any)
    filter(x -> !(x in (:node_id, :control_state)), fieldnames(s))
end
function variable_nt(s::Any)
    names = variable_names(typeof(s))
    NamedTuple{names}((getfield(s, x) for x in names))
end

"Get the right sort by function (by in `sort(x; by)`) given the Schema"
function sort_by end
# Not using any fallbacks to avoid forgetting to add the correct sorting.

sort_by(::StructVector{BasinConcentrationV1}) = x -> (x.node_id, x.substance, x.time)
sort_by(::StructVector{BasinConcentrationExternalV1}) =
    x -> (x.node_id, x.substance, x.time)
sort_by(::StructVector{BasinConcentrationStateV1}) = x -> (x.node_id, x.substance)
sort_by(::StructVector{BasinProfileV1}) = x -> (x.node_id, x.level)
sort_by(::StructVector{BasinStateV1}) = x -> (x.node_id)
sort_by(::StructVector{BasinStaticV1}) = x -> (x.node_id)
sort_by(::StructVector{BasinSubgridV1}) = x -> (x.subgrid_id, x.basin_level)
sort_by(::StructVector{BasinSubgridTimeV1}) = x -> (x.subgrid_id, x.time, x.basin_level)
sort_by(::StructVector{BasinTimeV1}) = x -> (x.node_id, x.time)

sort_by(::StructVector{ContinuousControlFunctionV1}) = x -> (x.node_id, x.input)
sort_by(::StructVector{ContinuousControlVariableV1}) =
    x -> (x.node_id, x.listen_node_id, x.variable)

sort_by(::StructVector{DiscreteControlConditionV1}) =
    x -> (x.node_id, x.compound_variable_id, x.greater_than)
sort_by(::StructVector{DiscreteControlLogicV1}) = x -> (x.node_id, x.truth_state)
sort_by(::StructVector{DiscreteControlVariableV1}) =
    x -> (x.node_id, x.compound_variable_id, x.listen_node_id, x.variable)

sort_by(::StructVector{FlowBoundaryConcentrationV1}) = x -> (x.node_id, x.substance, x.time)
sort_by(::StructVector{FlowBoundaryStaticV1}) = x -> (x.node_id)
sort_by(::StructVector{FlowBoundaryTimeV1}) = x -> (x.node_id, x.time)

sort_by(::StructVector{FlowDemandStaticV1}) = x -> (x.node_id, x.priority)
sort_by(::StructVector{FlowDemandTimeV1}) = x -> (x.node_id, x.priority, x.time)

sort_by(::StructVector{LevelBoundaryConcentrationV1}) =
    x -> (x.node_id, x.substance, x.time)
sort_by(::StructVector{LevelBoundaryStaticV1}) = x -> (x.node_id)
sort_by(::StructVector{LevelBoundaryTimeV1}) = x -> (x.node_id, x.time)

sort_by(::StructVector{LevelDemandStaticV1}) = x -> (x.node_id, x.priority)
sort_by(::StructVector{LevelDemandTimeV1}) = x -> (x.node_id, x.priority, x.time)

sort_by(::StructVector{LinearResistanceStaticV1}) = x -> (x.node_id, x.control_state)

sort_by(::StructVector{ManningResistanceStaticV1}) = x -> (x.node_id, x.control_state)

sort_by(::StructVector{OutletStaticV1}) = x -> (x.node_id, x.control_state)

sort_by(::StructVector{PidControlStaticV1}) = x -> (x.node_id, x.control_state)
sort_by(::StructVector{PidControlTimeV1}) = x -> (x.node_id, x.time)

sort_by(::StructVector{PumpStaticV1}) = x -> (x.node_id, x.control_state)

sort_by(::StructVector{TabulatedRatingCurveStaticV1}) =
    x -> (x.node_id, x.control_state, x.level)
sort_by(::StructVector{TabulatedRatingCurveTimeV1}) = x -> (x.node_id, x.time, x.level)

sort_by(::StructVector{UserDemandConcentrationV1}) = x -> (x.node_id, x.substance, x.time)
sort_by(::StructVector{UserDemandStaticV1}) = x -> (x.node_id, x.priority)
sort_by(::StructVector{UserDemandTimeV1}) = x -> (x.node_id, x.priority, x.time)

"""
Depending on if a table can be sorted, either sort it or assert that it is sorted.

Tables loaded from the database into memory can be sorted.
Tables loaded from Arrow files are memory mapped and can therefore not be sorted.
"""
function sorted_table!(
    table::StructVector{<:Legolas.AbstractRecord},
)::StructVector{<:Legolas.AbstractRecord}
    by = sort_by(table)
    if any((typeof(col) <: Arrow.Primitive for col in Tables.columns(table)))
        et = eltype(table)
        if !issorted(table; by)
            error("Arrow table for $et not sorted as required.")
        end
    else
        sort!(table; by)
    end
    return table
end

function valid_config(config::Config)::Bool
    errors = false

    if config.starttime >= config.endtime
        errors = true
        @error "The model starttime must be before the endtime."
    end

    return !errors
end

function valid_nodes(db::DB)::Bool
    errors = false

    sql = "SELECT node_id FROM Node GROUP BY node_id HAVING COUNT(*) > 1"
    node_ids = only(execute(columntable, db, sql))
    for node_id in node_ids
        errors = true
        @error "Multiple occurrences of node_id $node_id found in Node table."
    end

    return !errors
end

function database_warning(db::DB)::Nothing
    cols = SQLite.columns(db, "Edge")
    if "subnetwork_id" in cols.name
        @warn "The 'subnetwork_id' column in the 'Edge' table is deprecated since ribasim v2025.1."
    end
    return nothing
end

"""
Test for each node given its node type whether the nodes that
# are downstream ('down-edge') of this node are of an allowed type
"""
function valid_edges(graph::MetaGraph)::Bool
    errors = false
    for e in edges(graph)
        id_src = label_for(graph, e.src)
        id_dst = label_for(graph, e.dst)
        type_src = graph[id_src].type
        type_dst = graph[id_dst].type

        if !(type_dst in neighbortypes(type_src))
            errors = true
            @error "Cannot connect a $type_src to a $type_dst." id_src id_dst
        end
    end
    return !errors
end

"""
Check whether the profile data has no repeats in the levels and the areas start positive.
"""
function valid_profiles(
    node_id::Vector{NodeID},
    level::Vector{Vector{Float64}},
    area::Vector{Vector{Float64}},
)::Bool
    errors = false
    for (id, levels, areas) in zip(node_id, level, area)
        n = length(levels)
        if n < 2
            errors = true
            @error "$id profile must have at least two data points, got $n."
        end
        if !allunique(levels)
            errors = true
            @error "$id profile has repeated levels, this cannot be interpolated."
        end

        if areas[1] <= 0
            errors = true
            @error(
                "$id profile cannot start with area <= 0 at the bottom for numerical reasons.",
                area = areas[1],
            )
        end

        if any(diff(areas) .< 0.0)
            errors = true
            @error "$id profile cannot have decreasing areas."
        end
    end
    return !errors
end

"""
Test whether static or discrete controlled flow rates are indeed non-negative.
"""
function valid_flow_rates(
    node_id::Vector{NodeID},
    flow_rate::Vector,
    control_mapping::Dict,
)::Bool
    errors = false

    # Collect ids of discrete controlled nodes so that they do not give another error
    # if their initial value is also invalid.
    ids_controlled = NodeID[]

    for (key, control_state_update) in pairs(control_mapping)
        id_controlled = key[1]
        push!(ids_controlled, id_controlled)
        flow_rate_update = only(control_state_update.scalar_update)
        @assert flow_rate_update.name == :flow_rate
        flow_rate_ = flow_rate_update.value

        if flow_rate_ < 0.0
            errors = true
            control_state = key[2]
            @error "$id_controlled flow rates must be non-negative, found $flow_rate_ for control state '$control_state'."
        end
    end

    for (id, flow_rate_) in zip(node_id, flow_rate)
        if id in ids_controlled
            continue
        end
        if flow_rate_ < 0.0
            errors = true
            @error "$id flow rates must be non-negative, found $flow_rate_."
        end
    end

    return !errors
end

function valid_pid_connectivity(
    pid_control_node_id::Vector{NodeID},
    pid_control_listen_node_id::Vector{NodeID},
    graph::MetaGraph,
)::Bool
    errors = false

    for (pid_control_id, listen_id) in zip(pid_control_node_id, pid_control_listen_node_id)
        if listen_id.type !== NodeType.Basin
            @error "Listen node $listen_id of $pid_control_id is not a Basin"
            errors = true
        end

        controlled_id =
            only(outneighbor_labels_type(graph, pid_control_id, EdgeType.control))
        @assert controlled_id.type in [NodeType.Pump, NodeType.Outlet]

        id_inflow = inflow_id(graph, controlled_id)
        id_outflow = outflow_id(graph, controlled_id)

        if listen_id ∉ [id_inflow, id_outflow]
            errors = true
            @error "PID listened $listen_id is not on either side of controlled $controlled_id."
        end
    end

    return !errors
end

"""
Validate the entries for a single subgrid element.
"""
function valid_subgrid(
    subgrid_id::Int32,
    node_id::Int32,
    node_to_basin::Dict{Int32, Int},
    basin_level::Vector{Float64},
    subgrid_level::Vector{Float64},
)::Bool
    errors = false

    if !(node_id in keys(node_to_basin))
        errors = true
        @error "The node_id of the Basin / subgrid does not exist." node_id subgrid_id
    end

    if !allunique(basin_level)
        errors = true
        @error "Basin / subgrid subgrid_id $(subgrid_id) has repeated basin levels, this cannot be interpolated."
    end

    if !allunique(subgrid_level)
        errors = true
        @error "Basin / subgrid subgrid_id $(subgrid_id) has repeated element levels, this cannot be interpolated."
    end

    return !errors
end

function valid_demand(
    node_id::Vector{NodeID},
    demand_itp::Vector{Vector{ScalarInterpolation}},
    priorities::Vector{Int32},
)::Bool
    errors = false

    for (col, id) in zip(demand_itp, node_id)
        for (demand_p_itp, p_itp) in zip(col, priorities)
            if any(demand_p_itp.u .< 0.0)
                @error "Demand of $id with priority $p_itp should be non-negative"
                errors = true
            end
        end
    end
    return !errors
end

"""
Validate Outlet or Pump `min_upstream_level` and fill in default values
"""
function valid_min_upstream_level!(
    graph::MetaGraph,
    node::Union{Outlet, Pump},
    basin::Basin,
)::Bool
    errors = false
    for (id, min_upstream_level) in zip(node.node_id, node.min_upstream_level)
        id_in = inflow_id(graph, id)
        if id_in.type == NodeType.Basin
            basin_bottom_level = basin_bottom(basin, id_in)[2]
            if min_upstream_level == -Inf
                node.min_upstream_level[id.idx] = basin_bottom_level
            elseif min_upstream_level < basin_bottom_level
                @error "Minimum upstream level of $id is lower than bottom of upstream $id_in" min_upstream_level basin_bottom_level
                errors = true
            end
        end
    end
    return !errors
end

function valid_tabulated_curve_level(
    graph::MetaGraph,
    tabulated_rating_curve::TabulatedRatingCurve,
    basin::Basin,
)::Bool
    errors = false
    for (id, index_lookup) in zip(
        tabulated_rating_curve.node_id,
        tabulated_rating_curve.current_interpolation_index,
    )
        id_in = inflow_id(graph, id)
        if id_in.type == NodeType.Basin
            basin_bottom_level = basin_bottom(basin, id_in)[2]
            # for the complete timeseries this needs to hold
            for interpolation_index in index_lookup.u
                qh = tabulated_rating_curve.interpolations[interpolation_index]
                h_min = qh.t[1]
                if h_min < basin_bottom_level
                    @error "Lowest level of $id is lower than bottom of upstream $id_in" h_min basin_bottom_level
                    errors = true
                end
            end
        end
    end
    return !errors
end

function incomplete_subnetwork(graph::MetaGraph, node_ids::Dict{Int32, Set{NodeID}})::Bool
    errors = false
    for (subnetwork_id, subnetwork_node_ids) in node_ids
        subnetwork, _ = induced_subgraph(graph, code_for.(Ref(graph), subnetwork_node_ids))
        if !is_connected(subnetwork)
            @error "All nodes in subnetwork $subnetwork_id should be connected"
            errors = true
        end
    end
    return errors
end

function non_positive_subnetwork_id(graph::MetaGraph)::Bool
    errors = false
    for subnetwork_id in keys(graph[].node_ids)
        if (subnetwork_id <= 0)
            @error "Allocation network id $subnetwork_id needs to be a positive integer."
            errors = true
        end
    end
    return errors
end

"""
Test for each node given its node type whether it has an allowed
number of flow/control inneighbors and outneighbors
"""
function valid_n_neighbors(graph::MetaGraph)::Bool
    errors = false

    for nodetype in nodetypes
        errors |= !valid_n_neighbors(nodetype, graph)
    end

    return !errors
end

function valid_n_neighbors(node_name::Symbol, graph::MetaGraph)::Bool
    node_type = NodeType.T(node_name)
    bounds_flow = n_neighbor_bounds_flow(node_name)
    bounds_control = n_neighbor_bounds_control(node_name)

    errors = false
    # return !errors
    for node_id in labels(graph)
        node_id.type == node_type || continue
        for (bounds, edge_type) in
            zip((bounds_flow, bounds_control), (EdgeType.flow, EdgeType.control))
            n_inneighbors =
                count(x -> true, inneighbor_labels_type(graph, node_id, edge_type))
            n_outneighbors =
                count(x -> true, outneighbor_labels_type(graph, node_id, edge_type))

            if n_inneighbors < bounds.in_min
                @error "$node_id must have at least $(bounds.in_min) $edge_type inneighbor(s) (got $n_inneighbors)."
                errors = true
            end

            if n_inneighbors > bounds.in_max
                @error "$node_id can have at most $(bounds.in_max) $edge_type inneighbor(s) (got $n_inneighbors)."
                errors = true
            end

            if n_outneighbors < bounds.out_min
                @error "$node_id must have at least $(bounds.out_min) $edge_type outneighbor(s) (got $n_outneighbors)."
                errors = true
            end

            if n_outneighbors > bounds.out_max
                @error "$node_id can have at most $(bounds.out_max) $edge_type outneighbor(s) (got $n_outneighbors)."
                errors = true
            end
        end
    end
    return !errors
end

"Check that only supported edge types are declared."
function valid_edge_types(db::DB)::Bool
    edge_rows = execute(
        db,
        "SELECT edge_id, from_node_id, to_node_id, edge_type FROM Edge ORDER BY edge_id",
    )
    errors = false

    for (; edge_id, from_node_id, to_node_id, edge_type) in edge_rows
        if edge_type ∉ ["flow", "control"]
            errors = true
            @error "Invalid edge type '$edge_type' for edge #$edge_id from node #$from_node_id to node #$to_node_id."
        end
    end
    return !errors
end

"""
Check:
- whether control states are defined for discrete controlled nodes;
- Whether the supplied truth states have the proper length;
- Whether look_ahead is only supplied for condition variables given by a time-series.
"""
function valid_discrete_control(p::Parameters, config::Config)::Bool
    (; discrete_control, graph) = p
    (; node_id, logic_mapping) = discrete_control

    t_end = seconds_since(config.endtime, config.starttime)
    errors = false

    for (id, compound_variables) in zip(node_id, discrete_control.compound_variables)

        # The number of conditions of this DiscreteControl node
        n_conditions = sum(
            length(compound_variable.greater_than) for
            compound_variable in compound_variables
        )

        # The control states of this DiscreteControl node
        control_states_discrete_control = Set{String}()

        # The truth states of this DiscreteControl node with the wrong length
        truth_states_wrong_length = Vector{Bool}[]

        for (truth_state, control_state) in logic_mapping[id.idx]
            push!(control_states_discrete_control, control_state)

            if length(truth_state) != n_conditions
                push!(truth_states_wrong_length, truth_state)
            end
        end

        if !isempty(truth_states_wrong_length)
            errors = true
            @error "$id has $n_conditions condition(s), which is inconsistent with these truth state(s): $(convert_truth_state.(truth_states_wrong_length))."
        end

        # Check whether these control states are defined for the
        # control outneighbors
        for id_outneighbor in outneighbor_labels_type(graph, id, EdgeType.control)

            # Node object for the outneighbor node type
            node = getfield(p, graph[id_outneighbor].type)

            # Get control states of the controlled node
            control_states_controlled = Set{String}()

            # It is known that this node type has a control mapping, otherwise
            # connectivity validation would have failed.
            for (controlled_id, control_state) in keys(node.control_mapping)
                if controlled_id == id_outneighbor
                    push!(control_states_controlled, control_state)
                end
            end

            undefined_control_states =
                setdiff(control_states_discrete_control, control_states_controlled)

            if !isempty(undefined_control_states)
                undefined_list = collect(undefined_control_states)
                @error "These control states from $id are not defined for controlled $id_outneighbor: $undefined_list."
                errors = true
            end
        end

        # Validate look_ahead
        for compound_variable in compound_variables
            for subvariable in compound_variable.subvariables
                if !iszero(subvariable.look_ahead)
                    node_type = subvariable.listen_node_id.type
                    if node_type ∉ [NodeType.FlowBoundary, NodeType.LevelBoundary]
                        errors = true
                        @error "Look ahead supplied for non-timeseries listen variable '$(subvariable.variable)' from listen node $(subvariable.listen_node_id)."
                    else
                        if subvariable.look_ahead < 0
                            errors = true
                            @error "Negative look ahead supplied for listen variable '$(subvariable.variable)' from listen node $(subvariable.listen_node_id)."
                        else
                            node = getfield(p, graph[subvariable.listen_node_id].type)
                            interpolation =
                                getfield(node, Symbol(subvariable.variable))[subvariable.listen_node_id.idx]
                            if t_end + subvariable.look_ahead > interpolation.t[end]
                                errors = true
                                @error "Look ahead for listen variable '$(subvariable.variable)' from listen node $(subvariable.listen_node_id) goes past timeseries end during simulation."
                            end
                        end
                    end
                end
            end
        end
    end
    return !errors
end

function valid_priorities(priorities::Vector{Int32}, use_allocation::Bool)::Bool
    if use_allocation && any(iszero, priorities)
        return false
    else
        return true
    end
end
