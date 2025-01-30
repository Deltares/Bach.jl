"Get the package version of a given module"
function pkgversion(m::Module)::VersionNumber
    version = Base.pkgversion(Ribasim)
    !isnothing(version) && return version

    # Base.pkgversion doesn't work with compiled binaries
    # If it returns `nothing`, we try a different way
    rootmodule = Base.moduleroot(m)
    pkg = Base.PkgId(rootmodule)
    pkgorigin = Base.pkgorigins[pkg]
    return pkgorigin.version
end

"""Get the storage of a basin from its level."""
function get_storage_from_level(basin::Basin, state_idx::Int, level::Float64)::Float64
    level_to_area = basin.level_to_area[state_idx]
    if level < level_to_area.t[1]
        0.0
    else
        integral(level_to_area, level)
    end
end

"""Compute the storages of the basins based on the water level of the basins."""
function get_storages_from_levels(basin::Basin, levels::AbstractVector)::Vector{Float64}
    errors = false
    state_length = length(levels)
    basin_length = length(basin.storage_to_level)
    if state_length != basin_length
        @error "Unexpected 'Basin / state' length." state_length basin_length
        errors = true
    end
    storages = zeros(state_length)

    for (i, level) in enumerate(levels)
        storage = get_storage_from_level(basin, i, level)
        bottom = first(basin_levels(basin, i))
        if level < bottom
            node_id = basin.node_id[i]
            @error "The initial level ($level) of $node_id is below the bottom ($bottom)."
            errors = true
        end
        storages[i] = storage
    end
    if errors
        error("Encountered errors while parsing the initial levels of basins.")
    end

    return storages
end

"""
Compute the level of a basin given its storage.
"""
function get_level_from_storage(basin::Basin, state_idx::Int, storage)
    storage_to_level = basin.storage_to_level[state_idx]
    if storage >= 0
        return storage_to_level(storage)
    else
        # Negative storage is not feasible and this yields a level
        # below the basin bottom, but this does yield usable gradients
        # for the non-linear solver
        bottom = first(storage_to_level.u)
        return bottom + derivative(storage_to_level, 0.0) * storage
    end
end

"Linear interpolation of a scalar with constant extrapolation."
function get_scalar_interpolation(
    starttime::DateTime,
    t_end::Float64,
    time::AbstractVector,
    node_id::NodeID,
    param::Symbol;
    default_value::Float64 = 0.0,
    interpolation_type::Type{<:AbstractInterpolation},
)::interpolation_type
    rows = searchsorted(time.node_id, node_id)
    parameter = getfield.(time, param)[rows]
    parameter = coalesce.(parameter, default_value)
    times = seconds_since.(time.time[rows], starttime)
    # Add extra timestep at start for constant extrapolation
    if times[1] > 0
        pushfirst!(times, nextfloat(-Inf))
        pushfirst!(parameter, parameter[1])
    end
    # Add extra timestep at end for constant extrapolation
    if times[end] < t_end
        push!(times, t_end)
        push!(parameter, parameter[end])
    end

    if !allunique(times)
        @error "The time series for $node_id has repeated times, this can not be interpolated."
        error("Invalid time series.")
    end
    return interpolation_type(parameter, times; extrapolate = true, cache_parameters = true)
end

"""
Create a valid Qh ScalarInterpolation.
Takes a node_id for validation logging, and a vector of level (h) and flow_rate (Q).
"""
function qh_interpolation(
    node_id::NodeID,
    level::Vector{Float64},
    flow_rate::Vector{Float64},
)::ScalarInterpolation
    errors = false
    n = length(level)
    if n < 2
        @error "At least two datapoints are needed." node_id n
        errors = true
    end
    Q0 = first(flow_rate)
    if Q0 != 0.0
        @error "The `flow_rate` must start at 0." node_id flow_rate = Q0
        errors = true
    end

    if !allunique(level)
        @error "The `level` cannot be repeated." node_id
        errors = true
    end

    if any(diff(flow_rate) .< 0.0)
        @error "The `flow_rate` cannot decrease with increasing `level`." node_id
        errors = true
    end

    errors && error("Errors occurred when parsing $node_id.")

    # Ensure that that Q stays 0 below the first level
    pushfirst!(level, first(level) - 1)
    pushfirst!(flow_rate, first(flow_rate))

    return LinearInterpolation(
        flow_rate,
        level;
        extrapolate = true,
        cache_parameters = true,
    )
end

"""
Find the index of element x in a sorted collection a.
Returns the index of x if it exists, or nothing if it doesn't.
If x occurs more than once, throw an error.
"""
function findsorted(a, x)::Union{Int, Nothing}
    r = searchsorted(a, x)
    return if isempty(r)
        nothing
    elseif length(r) == 1
        only(r)
    else
        error("Multiple occurrences of $x found.")
    end
end

"From an iterable of DateTimes, find the times the solver needs to stop"
function get_tstops(time, starttime::DateTime)::Vector{Float64}
    unique_times = unique(time)
    return seconds_since.(unique_times, starttime)
end

"""
Get the current water level of a node ID.
The ID can belong to either a Basin or a LevelBoundary.
du: tells ForwardDiff whether this call is for differentiation or not
"""
function get_level(p::Parameters, node_id::NodeID, t::Number, current_level::Vector)::Number
    if node_id.type == NodeType.Basin
        current_level[node_id.idx]
    elseif node_id.type == NodeType.LevelBoundary
        p.level_boundary.level[node_id.idx](t)
    elseif node_id.type == NodeType.Terminal
        # Terminal is like a bottomless pit.
        # A level at -Inf ensures we don't hit `max_downstream_level` reduction factors.
        -Inf
    else
        error("Node ID $node_id is not a Basin, LevelBoundary or Terminal.")
    end
end

"Return the bottom elevation of the basin with index i, or nothing if it doesn't exist"
function basin_bottom(basin::Basin, node_id::NodeID)::Tuple{Bool, Float64}
    return if node_id.type == NodeType.Basin
        # get level(storage) interpolation function
        level_discrete = basin_levels(basin, node_id.idx)
        # and return the first level in this vector, representing the bottom
        return true, first(level_discrete)
    else
        return false, 0.0
    end
end

"""
Replace the truth states in the logic mapping which contain wildcards with
all possible explicit truth states.
"""
function expand_logic_mapping(
    logic_mapping::Vector{Dict{String, String}},
    node_ids::Vector{NodeID},
)::Vector{Dict{Vector{Bool}, String}}
    logic_mapping_expanded = [Dict{Vector{Bool}, String}() for _ in eachindex(node_ids)]
    pattern = r"^[TF\*]+$"

    for node_id in node_ids
        for truth_state in keys(logic_mapping[node_id.idx])
            if !occursin(pattern, truth_state)
                error(
                    "Truth state \'$truth_state\' contains illegal characters or is empty.",
                )
            end

            control_state = logic_mapping[node_id.idx][truth_state]
            n_wildcards = count(==('*'), truth_state)

            substitutions = if n_wildcards > 0
                substitutions = Iterators.product(fill([true, false], n_wildcards)...)
            else
                [nothing]
            end

            # Loop over all substitution sets for the wildcards
            for substitution in substitutions
                truth_state_new = Bool[]
                s_index = 0

                # If a wildcard is found replace it, otherwise take the old truth value
                for truth_value in truth_state
                    if truth_value == '*'
                        s_index += 1
                        push!(truth_state_new, substitution[s_index])
                    else
                        push!(truth_state_new, truth_value == 'T')
                    end
                end

                if haskey(logic_mapping_expanded[node_id.idx], truth_state_new)
                    control_state_existing =
                        logic_mapping_expanded[node_id.idx][truth_state_new]
                    control_states = sort([control_state, control_state_existing])
                    msg = "Multiple control states found for $node_id for truth state `$(convert_truth_state(truth_state_new))`: $control_states."
                    @assert control_state_existing == control_state msg
                else
                    logic_mapping_expanded[node_id.idx][truth_state_new] = control_state
                end
            end
        end
    end
    return logic_mapping_expanded
end

"""
    struct FlatVector{T} <: AbstractVector{T}

A FlatVector is an AbstractVector that iterates the T of a `Vector{Vector{T}}`.

Each inner vector is assumed to be of equal length.

It is similar to `Iterators.flatten`, though that doesn't work with the `Tables.Column`
interface, which needs `length` and `getindex` support.
"""
struct FlatVector{T} <: AbstractVector{T}
    v::Vector{Vector{T}}
end

function Base.length(fv::FlatVector)
    return if isempty(fv.v)
        0
    else
        length(fv.v) * length(first(fv.v))
    end
end

Base.size(fv::FlatVector) = (length(fv),)

function Base.getindex(fv::FlatVector, i::Int)
    veclen = length(first(fv.v))
    d, r = divrem(i - 1, veclen)
    v = fv.v[d + 1]
    return v[r + 1]
end

"Construct a FlatVector from one of the fields of SavedFlow."
function FlatVector(saveval::Vector{<:SavedFlow}, sym::Symbol)
    v = isempty(saveval) ? Vector{Float64}[] : getfield.(saveval, sym)
    FlatVector(v)
end
FlatVector(v::Vector{Matrix{Float64}}) = FlatVector(vec.(v))

"""
Function that goes smoothly from 0 to 1 in the interval [0,threshold],
and is constant outside this interval.
"""
function reduction_factor(x::T, threshold::Real)::T where {T <: Real}
    return if x < 0
        zero(T)
    elseif x < threshold
        x_scaled = x / threshold
        (-2 * x_scaled + 3) * x_scaled^2
    else
        one(T)
    end
end

function get_low_storage_factor(
    current_low_storage_factor::Vector{T},
    id::NodeID,
)::T where {T}
    return id.type == NodeType.Basin ? current_low_storage_factor[id.idx] : one(T)
end

"""
For resistance nodes, give a reduction factor based on the upstream node
as defined by the flow direction.
"""
function low_storage_factor_resistance_node(
    current_low_storage_factor,
    q,
    inflow_id,
    outflow_id,
)
    if q > 0
        get_low_storage_factor(current_low_storage_factor, inflow_id)
    else
        get_low_storage_factor(current_low_storage_factor, outflow_id)
    end
end

"""Whether the given node node is flow constraining by having a maximum flow rate."""
function is_flow_constraining(type::NodeType.T)::Bool
    type in (NodeType.LinearResistance, NodeType.Pump, NodeType.Outlet)
end

"""Whether the given node is flow direction constraining (only in direction of edges)."""
function is_flow_direction_constraining(type::NodeType.T)::Bool
    type in (
        NodeType.Pump,
        NodeType.Outlet,
        NodeType.TabulatedRatingCurve,
        NodeType.UserDemand,
        NodeType.FlowBoundary,
    )
end

function has_main_network(allocation::Allocation)::Bool
    if !is_active(allocation)
        false
    else
        first(allocation.subnetwork_ids) == 1
    end
end

function is_main_network(subnetwork_id::Int32)::Bool
    return subnetwork_id == 1
end

function get_all_demand_priorities(db::DB, config::Config)::Vector{Int32}
    demand_priorities = Set{Int32}()
    is_valid = true
    # TODO: Is there a way to automatically grab all tables with a demand priority column?
    for (type, name) in [
        (UserDemandStaticV1, "UserDemand / static"),
        (UserDemandTimeV1, "UserDemand / time"),
        (LevelDemandStaticV1, "LevelDemand / static"),
        (LevelDemandTimeV1, "LevelDemand / time"),
        (FlowDemandStaticV1, "FlowDemand / static"),
        (FlowDemandTimeV1, "FlowDemand / time"),
    ]
        demand_priority_col = load_structvector(db, config, type).demand_priority
        demand_priority_col = Int32.(coalesce.(demand_priority_col, Int32(0)))
        if valid_demand_priorities(demand_priority_col, config.allocation.use_allocation)
            union!(demand_priorities, demand_priority_col)
        else
            is_valid = false
            @error "Missing demand_priority parameter(s) for a $name node in the allocation problem."
        end
    end
    if is_valid
        return sort(collect(demand_priorities))
    else
        error("Priority parameter is missing")
    end
end

function get_external_demand_priority_idx(p::Parameters, node_id::NodeID)::Int
    (; graph, level_demand, flow_demand, allocation) = p
    inneighbor_control_ids = inneighbor_labels_type(graph, node_id, EdgeType.control)
    if isempty(inneighbor_control_ids)
        return 0
    end
    inneighbor_control_id = only(inneighbor_control_ids)
    type = inneighbor_control_id.type
    if type == NodeType.LevelDemand
        demand_priority = level_demand.demand_priority[inneighbor_control_id.idx]
    elseif type == NodeType.FlowDemand
        demand_priority = flow_demand.demand_priority[inneighbor_control_id.idx]
    else
        error("Nodes of type $type have no demand_priority.")
    end

    return findsorted(allocation.demand_priorities, demand_priority)
end

"""
Set continuous_control_type for those pumps and outlets that are controlled by either
PidControl or ContinuousControl
"""
function set_continuous_control_type!(p::Parameters)::Nothing
    (; continuous_control, pid_control) = p
    errors = false

    errors = set_continuous_control_type!(
        p,
        continuous_control.node_id,
        ContinuousControlType.Continuous,
    )
    errors |=
        set_continuous_control_type!(p, pid_control.node_id, ContinuousControlType.PID)

    if errors
        error("Errors occurred when parsing ContinuousControl and PidControl connectivity")
    end
    return nothing
end

function set_continuous_control_type!(
    p::Parameters,
    node_id::Vector{NodeID},
    continuous_control_type::ContinuousControlType.T,
)::Bool
    (; graph, pump, outlet) = p
    errors = false

    for id in node_id
        id_controlled = only(outneighbor_labels_type(graph, id, EdgeType.control))
        if id_controlled.type == NodeType.Pump
            pump.continuous_control_type[id_controlled.idx] = continuous_control_type
        elseif id_controlled.type == NodeType.Outlet
            outlet.continuous_control_type[id_controlled.idx] = continuous_control_type
        else
            errors = true
            @error "Only Pump and Outlet can be controlled by PidController, got $id_controlled"
        end
    end
    return errors
end

function has_external_demand(
    graph::MetaGraph,
    node_id::NodeID,
    node_type::Symbol,
)::Tuple{Bool, Union{NodeID, Nothing}}
    control_inneighbors = inneighbor_labels_type(graph, node_id, EdgeType.control)
    for id in control_inneighbors
        if graph[id].type == node_type
            return true, id
        end
    end
    return false, nothing
end

function Base.get(
    constraints::JuMP.Containers.DenseAxisArray,
    node_id::NodeID,
)::Union{JuMP.ConstraintRef, Nothing}
    if node_id in only(constraints.axes)
        constraints[node_id]
    else
        nothing
    end
end

"""
Get the time interval between (flow) saves
"""
function get_Δt(integrator)::Float64
    (; p, t, dt) = integrator
    (; saveat) = p.graph[]
    if iszero(saveat)
        dt
    elseif isinf(saveat)
        t
    else
        t_end = integrator.sol.prob.tspan[end]
        if t_end - t > saveat
            saveat
        else
            # The last interval might be shorter than saveat
            rem = t % saveat
            iszero(rem) ? saveat : rem
        end
    end
end

inflow_edge(graph, node_id)::EdgeMetadata = graph[inflow_id(graph, node_id), node_id]
outflow_edge(graph, node_id)::EdgeMetadata = graph[node_id, outflow_id(graph, node_id)]
outflow_edges(graph, node_id)::Vector{EdgeMetadata} =
    [graph[node_id, outflow_id] for outflow_id in outflow_ids(graph, node_id)]

"""
We want to perform allocation at t = 0 but there are no mean flows available
as input. Therefore we set the instantaneous flows as the mean flows as allocation input.
"""
function set_initial_allocation_mean_flows!(integrator)::Nothing
    (; u, p, t) = integrator
    (; allocation, graph) = p
    (; mean_input_flows, mean_realized_flows, allocation_models) = allocation
    (; Δt_allocation) = allocation_models[1]

    # At the time of writing water_balance! already
    # gets called once at the problem initialization, this
    # one is just to make sure.
    du = get_du(integrator)
    water_balance!(du, u, p, t)

    for mean_input_flows_subnetwork in values(mean_input_flows)
        for edge in keys(mean_input_flows_subnetwork)
            if edge[1] == edge[2]
                q = get_influx(du, edge[1], p)
            else
                q = get_flow(du, p, t, edge)
            end
            # Multiply by Δt_allocation as averaging divides by this factor
            # in update_allocation!
            mean_input_flows_subnetwork[edge] = q * Δt_allocation
        end
    end

    # Mean realized demands for basins are calculated as Δstorage/Δt
    # This sets the realized demands as -storage_old
    for edge in keys(mean_realized_flows)
        if edge[1] == edge[2]
            mean_realized_flows[edge] = -u[edge[1].idx]
        else
            q = get_flow(du, p, t, edge)
            mean_realized_flows[edge] = q * Δt_allocation
        end
    end

    return nothing
end

"""
Convert a truth state in terms of a BitVector or Vector{Bool} into a string of 'T' and 'F'
"""
function convert_truth_state(boolean_vector)::String
    String(UInt8.(ifelse.(boolean_vector, 'T', 'F')))
end

function NodeID(type::Symbol, value::Integer, p::Parameters)::NodeID
    node_type = NodeType.T(type)
    node = getfield(p, snake_case(type))
    idx = searchsortedfirst(node.node_id, NodeID(node_type, value, 0))
    return NodeID(node_type, value, idx)
end

"""
Get the reference to a parameter
"""
function get_variable_ref(
    p::Parameters,
    node_id::NodeID,
    variable::String;
    listen::Bool = true,
)::Tuple{PreallocationRef, Bool}
    (; basin) = p
    errors = false

    # Only built here because it is needed to obtain indices
    u = build_state_vector(p)

    ref = if node_id.type == NodeType.Basin && variable == "level"
        PreallocationRef(basin.current_properties.current_level, node_id.idx)
    elseif variable == "flow_rate" && node_id.type != NodeType.FlowBoundary
        if listen
            if node_id.type ∉ conservative_nodetypes
                errors = true
                @error "Cannot listen to flow_rate of $node_id, the node type must be one of $conservative_node_types"
                Ref(Float64[], 0)
            else
                # Index in the state vector (inflow)
                flow_idx = get_state_index(node_id, u)
                PreallocationRef(cache(1), flow_idx; from_du = true)
            end
        else
            node = getfield(p, snake_case(node_id))
            PreallocationRef(node.flow_rate, node_id.idx)
        end
    else
        # Placeholder to obtain correct type
        PreallocationRef(cache(1), 0)
    end
    return ref, errors
end

"""
Set references to all variables that are listened to by discrete/continuous control
"""
function set_listen_variable_refs!(p::Parameters)::Nothing
    (; discrete_control, continuous_control) = p
    compound_variable_sets =
        [discrete_control.compound_variables..., continuous_control.compound_variable]
    errors = false

    for compound_variables in compound_variable_sets
        for compound_variable in compound_variables
            (; subvariables) = compound_variable
            for (j, subvariable) in enumerate(subvariables)
                ref, error =
                    get_variable_ref(p, subvariable.listen_node_id, subvariable.variable)
                if !error
                    subvariables[j] = @set subvariable.variable_ref = ref
                end
                errors |= error
            end
        end
    end

    if errors
        error("Error(s) occurred when parsing listen variables.")
    end
    return nothing
end

"""
Set references to all variables that are controlled by discrete control
"""
function set_discrete_controlled_variable_refs!(p::Parameters)::Nothing
    for nodetype in propertynames(p)
        node = getfield(p, nodetype)
        if node isa AbstractParameterNode && hasfield(typeof(node), :control_mapping)
            control_mapping::Dict{Tuple{NodeID, String}, ControlStateUpdate} =
                node.control_mapping

            for ((node_id, control_state), control_state_update) in control_mapping
                (; scalar_update, itp_update) = control_state_update

                # References to scalar parameters
                for (i, parameter_update) in enumerate(scalar_update)
                    field = getfield(node, parameter_update.name)
                    if field isa Cache
                        field = field[Float64[]]
                    end
                    scalar_update[i] = @set parameter_update.ref = Ref(field, node_id.idx)
                end

                # References to interpolation parameters
                for (i, parameter_update) in enumerate(itp_update)
                    field = getfield(node, parameter_update.name)
                    itp_update[i] = @set parameter_update.ref = Ref(field, node_id.idx)
                end

                # Reference to 'active' parameter if it exists
                if hasfield(typeof(node), :active)
                    control_mapping[(node_id, control_state)] =
                        @set control_state_update.active.ref = Ref(node.active, node_id.idx)
                end
            end
        end
    end
    return nothing
end

function set_continuously_controlled_variable_refs!(p::Parameters)::Nothing
    (; continuous_control, pid_control, graph) = p
    errors = false
    for (node, controlled_variable) in (
        (continuous_control, continuous_control.controlled_variable),
        (pid_control, fill("flow_rate", length(pid_control.node_id))),
    )
        for (id, controlled_variable) in zip(node.node_id, controlled_variable)
            controlled_node_id = only(outneighbor_labels_type(graph, id, EdgeType.control))
            ref, error =
                get_variable_ref(p, controlled_node_id, controlled_variable; listen = false)
            push!(node.target_ref, ref)
            errors |= error
        end
    end

    if errors
        error("Errors encountered when setting continuously controlled variable refs.")
    end
    return nothing
end

"""
Add a control state to a logic mapping. The references to the targets in memory
for the parameter values are added later when these references are known
"""
function add_control_state!(
    control_mapping,
    time_interpolatables,
    parameter_names,
    parameter_values,
    node_type,
    control_state,
    node_id,
)::Nothing
    control_state_key = coalesce(control_state, "")

    # Control state is only added if a control state update can be defined
    add_control_state = false

    # Create 'active' parameter update if it exists, otherwise this gets
    # ignored
    active_idx = findfirst(==(:active), parameter_names)
    active = if isnothing(active_idx)
        ParameterUpdate(:active, true)
    else
        add_control_state = true
        ParameterUpdate(:active, parameter_values[active_idx])
    end

    itp_update = []
    scalar_update = ParameterUpdate{Float64}[]
    for (parameter_name, parameter_value) in zip(parameter_names, parameter_values)
        if parameter_name in controllablefields(Symbol(node_type)) &&
           parameter_name !== :active
            add_control_state = true
            parameter_update = ParameterUpdate(parameter_name, parameter_value)

            # Differentiate between scalar parameters and interpolation parameters
            if parameter_name in time_interpolatables
                push!(itp_update, parameter_update)
            else
                push!(scalar_update, parameter_update)
            end
        end
    end
    # This is a not so great way to get a concrete type,
    # which is used as a ControlStateUpdate type parameter.
    itp_update = if isempty(itp_update)
        ParameterUpdate{ScalarInterpolation}[]
    else
        [x for x in itp_update]
    end
    control_state_update = ControlStateUpdate(; active, scalar_update, itp_update)

    if add_control_state
        control_mapping[(node_id, control_state_key)] = control_state_update
    end
    return nothing
end

"""
Collect the control mappings of all controllable nodes in
the DiscreteControl object for easy access
"""
function collect_control_mappings!(p)::Nothing
    (; control_mappings) = p.discrete_control

    for node_type in instances(NodeType.T)
        node_type == NodeType.Terminal && continue
        node = getfield(p, snake_case(node_type))
        if hasfield(typeof(node), :control_mapping)
            control_mappings[node_type] = node.control_mapping
        end
    end
end

function basin_levels(basin::Basin, state_idx::Int)
    return basin.level_to_area[state_idx].t
end

function basin_areas(basin::Basin, state_idx::Int)
    return basin.level_to_area[state_idx].u
end

"""
The function f(x) = sign(x)*√(|x|) where for |x|<threshold a
polynomial is used so that the function is still differentiable
but the derivative is bounded at x = 0.
"""
function relaxed_root(x, threshold)
    if abs(x) < threshold
        x_scaled = x / threshold
        sqrt(threshold) * x_scaled^3 * (9 - 5x_scaled^2) / 4
    else
        sign(x) * sqrt(abs(x))
    end
end

function get_jac_prototype(du0, u0, p, t0)
    p.all_nodes_active = true
    jac_prototype = jacobian_sparsity(
        (du, u) -> water_balance!(du, u, p, t0),
        du0,
        u0,
        TracerSparsityDetector(),
    )
    p.all_nodes_active = false
    jac_prototype
end

# Custom overloads
reduction_factor(x::GradientTracer, threshold::Real) = x
low_storage_factor_resistance_node(storage, q::GradientTracer, inflow_id, outflow_id) = q
relaxed_root(x::GradientTracer, threshold::Real) = x
get_level_from_storage(basin::Basin, state_idx::Int, storage::GradientTracer) = storage
stop_declining_negative_storage!(du, u::ComponentVector{<:GradientTracer}) = nothing

@kwdef struct MonitoredBackTracking{B, V}
    linesearch::B = BackTracking()
    dz_tmp::V = []
    z_tmp::V = []
end

"""
Compute the residual of the non-linear solver, i.e. a measure of the
error in the solution to the implicit equation defined by the solver algorithm
"""
function residual(z, integrator, nlsolver, f)
    (; uprev, t, p, dt, opts, isdae) = integrator
    (; tmp, ztmp, γ, α, cache, method) = nlsolver
    (; ustep, atmp, tstep, k, invγdt, tstep, k, invγdt) = cache
    if isdae
        _uprev = get_dae_uprev(integrator, uprev)
        b, ustep2 =
            _compute_rhs!(tmp, ztmp, ustep, α, tstep, k, invγdt, p, _uprev, f::TF, z)
    else
        b, ustep2 =
            _compute_rhs!(tmp, ztmp, ustep, γ, α, tstep, k, invγdt, method, p, dt, f, z)
    end
    calculate_residuals!(
        atmp,
        b,
        uprev,
        ustep2,
        opts.abstol,
        opts.reltol,
        opts.internalnorm,
        t,
    )
    ndz = opts.internalnorm(atmp, t)
    return ndz
end

"""
MonitoredBackTracing is a thin wrapper of BackTracking, making sure that
the BackTracking relaxation is rejected if it results in a residual increase
"""
function OrdinaryDiffEqNonlinearSolve.relax!(
    dz,
    nlsolver::AbstractNLSolver,
    integrator::DEIntegrator,
    f,
    linesearch::MonitoredBackTracking,
)
    (; linesearch, dz_tmp, z_tmp) = linesearch

    # Store step before relaxation
    @. dz_tmp = dz

    # Apply relaxation and measure the residual change
    @. z_tmp = nlsolver.z + dz
    resid_before = residual(z_tmp, integrator, nlsolver, f)
    relax!(dz, nlsolver, integrator, f, linesearch)
    @. z_tmp = nlsolver.z + dz
    resid_after = residual(z_tmp, integrator, nlsolver, f)

    # If the residual increased due to the relaxation, reject it
    if resid_after > resid_before
        @. dz = dz_tmp
    end
end

function build_state_vector(p::Parameters)
    # It is assumed that the horizontal flow states come first in
    # p.state_inflow_edge and p.state_outflow_edge
    return ComponentVector{Float64}(;
        tabulated_rating_curve = zeros(length(p.tabulated_rating_curve.node_id)),
        pump = zeros(length(p.pump.node_id)),
        outlet = zeros(length(p.outlet.node_id)),
        user_demand_inflow = zeros(length(p.user_demand.node_id)),
        user_demand_outflow = zeros(length(p.user_demand.node_id)),
        linear_resistance = zeros(length(p.linear_resistance.node_id)),
        manning_resistance = zeros(length(p.manning_resistance.node_id)),
        evaporation = zeros(length(p.basin.node_id)),
        infiltration = zeros(length(p.basin.node_id)),
        integral = zeros(length(p.pid_control.node_id)),
    )
end

function build_flow_to_storage(p::Parameters, u::ComponentVector)::Parameters
    n_basins = length(p.basin.node_id)
    n_states = length(u)
    flow_to_storage = ComponentArray(
        spzeros(n_basins, n_states),
        (Axis(; basins = 1:n_basins), only(getaxes(u))),
    )

    for node_name in (
        :tabulated_rating_curve,
        :pump,
        :outlet,
        :linear_resistance,
        :manning_resistance,
        :user_demand,
    )
        node = getfield(p, node_name)

        if node_name == :user_demand
            flow_to_storage_node_inflow = view(flow_to_storage, :, :user_demand_inflow)
            flow_to_storage_node_outflow = view(flow_to_storage, :, :user_demand_outflow)
        else
            flow_to_storage_node_inflow = view(flow_to_storage, :, node_name)
            flow_to_storage_node_outflow = flow_to_storage_node_inflow
        end

        for (inflow_edge, outflow_edge) in zip(node.inflow_edge, node.outflow_edge)
            inflow_id, node_id = inflow_edge.edge
            if inflow_id.type == NodeType.Basin
                flow_to_storage_node_inflow[inflow_id.idx, node_id.idx] = -1.0
            end

            outflow_id = outflow_edge.edge[2]
            if outflow_id.type == NodeType.Basin
                flow_to_storage_node_outflow[outflow_id.idx, node_id.idx] = 1.0
            end
        end
    end

    flow_to_storage_evaporation = view(flow_to_storage, :, :evaporation)
    flow_to_storage_infiltration = view(flow_to_storage, :, :infiltration)

    for i in 1:n_basins
        flow_to_storage_evaporation[i, i] = -1.0
        flow_to_storage_infiltration[i, i] = -1.0
    end

    @set p.flow_to_storage = parent(flow_to_storage)
end

"""
Create vectors state_inflow_edge and state_outflow_edge which give for each state
in the state vector in order the metadata of the edge that is associated with that state.
Only for horizontal flows, which are assumed to come first in the state vector.
"""
function set_state_flow_edges(p::Parameters, u0::ComponentVector)::Parameters
    (; user_demand, graph) = p

    components = Symbol[]
    state_inflow_edges = Vector{EdgeMetadata}[]
    state_outflow_edges = Vector{EdgeMetadata}[]

    placeholder_edge =
        EdgeMetadata(0, EdgeType.flow, (NodeID(:Terminal, 0, 0), NodeID(:Terminal, 0, 0)))

    for node_name in keys(u0)
        if hasfield(Parameters, node_name)
            node::AbstractParameterNode = getfield(p, node_name)
            push!(components, node_name)
            state_inflow_edges_component = EdgeMetadata[]
            state_outflow_edges_component = EdgeMetadata[]
            for id in node.node_id
                inflow_ids_ = collect(inflow_ids(p.graph, id))
                outflow_ids_ = collect(outflow_ids(p.graph, id))

                inflow_edge = if length(inflow_ids_) == 0
                    placeholder_edge
                elseif length(inflow_ids_) == 1
                    inflow_id = only(inflow_ids_)
                    graph[inflow_id, id]
                else
                    error("Multiple inflows not supported")
                end
                push!(state_inflow_edges_component, inflow_edge)

                outflow_edge = if length(outflow_ids_) == 0
                    placeholder_edge
                elseif length(outflow_ids_) == 1
                    outflow_id = only(outflow_ids_)
                    graph[id, outflow_id]
                else
                    error("Multiple outflows not supported")
                end
                push!(state_outflow_edges_component, outflow_edge)
            end
            push!(state_inflow_edges, state_inflow_edges_component)
            push!(state_outflow_edges, state_outflow_edges_component)
        elseif startswith(String(node_name), "user_demand")
            push!(components, node_name)
            placeholder_edges = fill(placeholder_edge, length(user_demand.node_id))
            if node_name == :user_demand_inflow
                push!(state_inflow_edges, user_demand.inflow_edge)
                push!(state_outflow_edges, placeholder_edges)
            elseif node_name == :user_demand_outflow
                push!(state_inflow_edges, placeholder_edges)
                push!(state_outflow_edges, user_demand.outflow_edge)
            end
        end
    end

    state_inflow_edge = ComponentVector(NamedTuple(zip(components, state_inflow_edges)))
    state_outflow_edge = ComponentVector(NamedTuple(zip(components, state_outflow_edges)))

    @reset p.state_inflow_edge = state_inflow_edge
    @reset p.state_outflow_edge = state_outflow_edge
    return p
end

function id_from_state_index(
    p::Parameters,
    ::ComponentVector{Float64, Vector{Float64}, <:Tuple{<:Axis{NT}}},
    global_idx::Int,
)::NodeID where {NT}
    local_idx = 0
    component = Symbol()
    for (comp, range) in pairs(NT)
        if global_idx in range
            component = comp
            local_idx = global_idx - first(range) + 1
            break
        end
    end
    component_string = String(component)
    if endswith(component_string, "_inflow") || endswith(component_string, "_outflow")
        component = :user_demand
    elseif component == :integral
        component = :pid_control
    elseif component in [:infiltration, :evaporation]
        component = :basin
    end

    getfield(p, component).node_id[local_idx]
end

function get_state_index(
    id::NodeID,
    ::ComponentVector{A, B, <:Tuple{<:Axis{NT}}};
    inflow::Bool = true,
) where {A, B, NT}
    component_name = if id.type == NodeType.UserDemand
        inflow ? :user_demand_inflow : :user_demand_outflow
    else
        snake_case(id)
    end
    for (comp, range) in pairs(NT)
        if comp == component_name
            return range[id.idx]
        end
    end
    return nothing
end

function get_state_index(u::ComponentVector, edge::Tuple{NodeID, NodeID})::Int
    idx = get_state_index(edge[2], u)
    isnothing(idx) ? get_state_index(edge[1], u; inflow = false) : idx
end

"""
Check whether any storages are negative given the state u.
"""
function isoutofdomain(u, p, t)
    (; current_storage) = p.basin.current_properties
    current_storage = current_storage[parent(u)]
    formulate_storages!(current_storage, u, u, p, t)
    any(<(0), current_storage)
end

function get_demand(user_demand, id, demand_priority_idx, t)::Float64
    (; demand_from_timeseries, demand_itp, demand) = user_demand
    if demand_from_timeseries[id.idx]
        demand_itp[id.idx][demand_priority_idx](t)
    else
        demand[id.idx, demand_priority_idx]
    end
end

"""
Estimate the minimum reduction factor achieved over the last time step by
estimating the lowest storage achieved over the last time step. To make sure
it is an underestimate of the minimum, 2LOW_STORAGE_THRESHOLD is subtracted from this lowest storage.
This is done to not be too strict in clamping the flow in the limiter
"""
function min_low_storage_factor(storage_now::Vector{T}, storage_prev, id) where {T}
    if id.type == NodeType.Basin
        reduction_factor(
            min(storage_now[id.idx], storage_prev[id.idx]) - 2LOW_STORAGE_THRESHOLD,
            LOW_STORAGE_THRESHOLD,
        )
    else
        one(T)
    end
end

"""
Estimate the minimum level reduction factor achieved over the last time step by
estimating the lowest level achieved over the last time step. To make sure
it is an underestimate of the minimum, 2USER_DEMAND_MIN_LEVEL_THRESHOLD is subtracted from this lowest level.
This is done to not be too strict in clamping the flow in the limiter
"""
function min_low_user_demand_level_factor(
    level_now::Vector{T},
    level_prev,
    min_level,
    id_user_demand,
    id_inflow,
) where {T}
    if id_inflow.type == NodeType.Basin
        reduction_factor(
            min(level_now[id_inflow.idx], level_prev[id_inflow.idx]) -
            min_level[id_user_demand.idx] - 2USER_DEMAND_MIN_LEVEL_THRESHOLD,
            USER_DEMAND_MIN_LEVEL_THRESHOLD,
        )
    else
        one(T)
    end
end

function mean_input_flows_subnetwork(p::Parameters, subnetwork_id::Int32)
    (; mean_input_flows, subnetwork_ids) = p.allocation
    subnetwork_idx = searchsortedfirst(subnetwork_ids, subnetwork_id)
    return mean_input_flows[subnetwork_idx]
end

source_edges_subnetwork(p::Parameters, subnetwork_id::Int32) =
    keys(mean_input_flows_subnetwork(p, subnetwork_id))

"""
Wrap the data of a SubArray into a Vector.

This function is labeled unsafe because it will crash if pointer is not a valid memory
address to data of the requested length, and it will not prevent the input array A from
being freed.
"""
function unsafe_array(
    A::SubArray{Float64, 1, Vector{Float64}, Tuple{UnitRange{Int64}}, true},
)::Vector{Float64}
    GC.@preserve A unsafe_wrap(Array, pointer(A), length(A))
end
