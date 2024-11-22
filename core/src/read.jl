"""
Process the data in the static and time tables for a given node type.
The 'defaults' named tuple dictates how missing data is filled in.
'time_interpolatables' is a vector of Symbols of parameter names
for which a time interpolation (linear) object must be constructed.
The control mapping for DiscreteControl is also constructed in this function.
This function currently does not support node states that are defined by more
than one row in a table, as is the case for TabulatedRatingCurve.
"""
function parse_static_and_time(
    db::DB,
    config::Config,
    node_type::Type;
    static::Union{StructVector, Nothing} = nothing,
    time::Union{StructVector, Nothing} = nothing,
    defaults::NamedTuple = (; active = true),
    time_interpolatables::Vector{Symbol} = Symbol[],
)::Tuple{NamedTuple, Bool}
    # E.g. `PumpStatic`
    static_type = eltype(static)
    columnnames_static = collect(fieldnames(static_type))
    # Mask out columns that do not denote parameters
    mask = [symb ∉ [:node_id, :control_state] for symb in columnnames_static]

    # The names of the parameters that can define a control state
    parameter_names = columnnames_static[mask]

    # The types of the variables that can define a control state
    parameter_types = collect(fieldtypes(static_type))[mask]

    # A vector of vectors, for each parameter the (initial) values for all nodes
    # of the current type
    vals_out = []

    node_type_string = split(string(node_type), '.')[end]
    ids = get_ids(db, node_type_string)
    node_ids = NodeID.(node_type_string, ids, eachindex(ids))
    n_nodes = length(node_ids)

    # Initialize the vectors for the output
    for (parameter_name, parameter_type) in zip(parameter_names, parameter_types)
        # If the type is a union, then the associated parameter is optional and
        # the type is of the form Union{Missing,ActualType}
        parameter_type = if parameter_name in time_interpolatables
            ScalarInterpolation
        elseif isa(parameter_type, Union)
            nonmissingtype(parameter_type)
        else
            parameter_type
        end

        push!(vals_out, Vector{parameter_type}(undef, n_nodes))
    end

    # The keys of the output NamedTuple
    keys_out = copy(parameter_names)

    # The names of the parameters associated with a node of the current type
    parameter_names = Tuple(parameter_names)

    push!(keys_out, :node_id)
    push!(vals_out, node_ids)

    # The control mapping is a dictionary with keys (node_id, control_state) to a named tuple of parameter values
    # parameter values to be assigned to the node with this node_id in the case of this control_state
    control_mapping = Dict{Tuple{NodeID, String}, ControlStateUpdate}()

    push!(keys_out, :control_mapping)
    push!(vals_out, control_mapping)

    # The output namedtuple
    out = NamedTuple{Tuple(keys_out)}(Tuple(vals_out))

    if n_nodes == 0
        return out, true
    end

    # Get node IDs of static nodes if the static table exists
    if static === nothing
        static_node_id_vec = NodeID[]
        static_node_ids = Set{NodeID}()
    else
        idx = searchsortedfirst.(Ref(ids), static.node_id)
        static_node_id_vec = NodeID.(node_type_string, static.node_id, idx)
        static_node_ids = Set(static_node_id_vec)
    end

    # Get node IDs of transient nodes if the time table exists
    time_node_ids = if time === nothing
        time_node_id_vec = NodeID[]
        time_node_ids = Set{NodeID}()
    else
        idx = searchsortedfirst.(Ref(ids), time.node_id)
        time_node_id_vec = NodeID.(Ref(node_type_string), time.node_id, idx)
        time_node_ids = Set(time_node_id_vec)
    end

    errors = false
    t_end = seconds_since(config.endtime, config.starttime)
    trivial_timespan = [0.0, prevfloat(Inf)]

    for node_id in node_ids
        if node_id in static_node_ids
            # The interval of rows of the static table that have the current node_id
            rows = searchsorted(static_node_id_vec, node_id)
            # The rows of the static table that have the current node_id
            static_id = view(static, rows)
            # Here it is assumed that the parameters of a node are given by a single
            # row in the static table, which is not true for TabulatedRatingCurve
            for row in static_id
                control_state =
                    hasproperty(row, :control_state) ? row.control_state : missing
                # Get the parameter values, and turn them into trivial interpolation objects
                # if this parameter can be transient
                parameter_values = Any[]
                for parameter_name in parameter_names
                    val = getfield(row, parameter_name)
                    # Set default parameter value if no value was given
                    if ismissing(val)
                        val = defaults[parameter_name]
                    end
                    if parameter_name in time_interpolatables
                        val = LinearInterpolation(
                            [val, val],
                            trivial_timespan;
                            cache_parameters = true,
                        )
                    end
                    # Collect the parameter values in the parameter_values vector
                    push!(parameter_values, val)
                    # The initial parameter value is overwritten here each time until the last row,
                    # but in the case of control the proper initial parameter values are set later on
                    # in the code
                    getfield(out, parameter_name)[node_id.idx] = val
                end
                # Add the parameter values to the control mapping
                add_control_state!(
                    control_mapping,
                    time_interpolatables,
                    parameter_names,
                    parameter_values,
                    node_type_string,
                    control_state,
                    node_id,
                )
            end
        elseif node_id in time_node_ids
            # TODO replace (time, node_id) order by (node_id, time)
            # this fits our access pattern better, so we can use views
            idx = findall(==(node_id), time_node_id_vec)
            time_subset = time[idx]

            time_first_idx = searchsortedfirst(time_node_id_vec[idx], node_id)

            for parameter_name in parameter_names
                # If the parameter is interpolatable, create an interpolation object
                if parameter_name in time_interpolatables
                    val, is_valid = get_scalar_interpolation(
                        config.starttime,
                        t_end,
                        time_subset,
                        node_id,
                        parameter_name;
                        default_value = hasproperty(defaults, parameter_name) ?
                                        defaults[parameter_name] : NaN,
                    )
                    if !is_valid
                        errors = true
                        @error "A $parameter_name time series for $node_id has repeated times, this can not be interpolated."
                    end
                else
                    # Activity of transient nodes is assumed to be true
                    if parameter_name == :active
                        val = true
                    else
                        # If the parameter is not interpolatable, get the instance in the first row
                        val = getfield(time_subset[time_first_idx], parameter_name)
                    end
                end
                getfield(out, parameter_name)[node_id.idx] = val
            end
        else
            @error "$node_id data not in any table."
            errors = true
        end
    end
    return out, !errors
end

function static_and_time_node_ids(
    db::DB,
    static::StructVector,
    time::StructVector,
    node_type::String,
)::Tuple{Set{NodeID}, Set{NodeID}, Vector{NodeID}, Bool}
    ids = get_ids(db, node_type)
    idx = searchsortedfirst.(Ref(ids), static.node_id)
    static_node_ids = Set(NodeID.(Ref(node_type), static.node_id, idx))
    idx = searchsortedfirst.(Ref(ids), time.node_id)
    time_node_ids = Set(NodeID.(Ref(node_type), time.node_id, idx))
    node_ids = NodeID.(Ref(node_type), ids, eachindex(ids))
    doubles = intersect(static_node_ids, time_node_ids)
    errors = false
    if !isempty(doubles)
        errors = true
        @error "$node_type cannot be in both static and time tables, found these node IDs in both: $doubles."
    end
    if !issetequal(node_ids, union(static_node_ids, time_node_ids))
        errors = true
        @error "$node_type node IDs don't match."
    end
    return static_node_ids, time_node_ids, node_ids, !errors
end

const conservative_nodetypes = Set{NodeType.T}([
    NodeType.Pump,
    NodeType.Outlet,
    NodeType.TabulatedRatingCurve,
    NodeType.LinearResistance,
    NodeType.ManningResistance,
])

function initialize_allocation!(p::Parameters, config::Config)::Nothing
    (; graph, allocation) = p
    (; subnetwork_ids, allocation_models, main_network_connections) = allocation
    subnetwork_ids_ = sort(collect(keys(graph[].node_ids)))

    if isempty(subnetwork_ids_)
        return nothing
    end

    errors = non_positive_subnetwork_id(graph)
    if errors
        error("Allocation network initialization failed.")
    end

    for subnetwork_id in subnetwork_ids_
        push!(subnetwork_ids, subnetwork_id)
        push!(main_network_connections, Tuple{NodeID, NodeID}[])
    end

    if first(subnetwork_ids_) == 1
        find_subnetwork_connections!(p)
    end

    for subnetwork_id in subnetwork_ids_
        push!(
            allocation_models,
            AllocationModel(subnetwork_id, p, config.allocation.timestep),
        )
    end
    return nothing
end

function LinearResistance(db::DB, config::Config, graph::MetaGraph)::LinearResistance
    static = load_structvector(db, config, LinearResistanceStaticV1)
    defaults = (; max_flow_rate = Inf, active = true)
    parsed_parameters, valid =
        parse_static_and_time(db, config, LinearResistance; static, defaults)

    if !valid
        error(
            "Problems encountered when parsing LinearResistance static and time node IDs.",
        )
    end

    (; node_id) = parsed_parameters
    node_id = NodeID.(NodeType.LinearResistance, node_id, eachindex(node_id))

    return LinearResistance(;
        node_id,
        inflow_edge = inflow_edge.(Ref(graph), node_id),
        outflow_edge = outflow_edge.(Ref(graph), node_id),
        parsed_parameters.active,
        parsed_parameters.resistance,
        parsed_parameters.max_flow_rate,
        parsed_parameters.control_mapping,
    )
end

function TabulatedRatingCurve(
    db::DB,
    config::Config,
    graph::MetaGraph,
)::TabulatedRatingCurve
    static = load_structvector(db, config, TabulatedRatingCurveStaticV1)
    time = load_structvector(db, config, TabulatedRatingCurveTimeV1)

    static_node_ids, time_node_ids, node_ids, valid =
        static_and_time_node_ids(db, static, time, "TabulatedRatingCurve")

    if !valid
        error(
            "Problems encountered when parsing TabulatedRatingcurve static and time node IDs.",
        )
    end

    interpolation_type = interpolation_method(config.interpolation.tabulated_rating_curve)
    if isnothing(interpolation_type)
        error(
            "Unsupported interpolation type $(config.interpolation.tabulated_rating_curve) for tabulated_rating_curve.",
        )
    end
    interpolations = interpolation_type.type[]
    control_mapping = Dict{Tuple{NodeID, String}, ControlStateUpdate}()
    active = Bool[]
    max_downstream_level = Float64[]
    errors = false

    for node_id in node_ids
        if node_id in static_node_ids
            # Loop over all static rating curves (groups) with this node_id.
            # If it has a control_state add it to control_mapping.
            # The last rating curve forms the initial condition and activity.
            source = "static"
            rows = searchsorted(
                NodeID.(NodeType.TabulatedRatingCurve, static.node_id, node_id.idx),
                node_id,
            )
            static_id = view(static, rows)
            local is_active, interpolation, max_level
            # coalesce control_state to nothing to avoid boolean groupby logic on missing
            for group in
                IterTools.groupby(row -> coalesce(row.control_state, nothing), static_id)
                control_state = first(group).control_state
                is_active = coalesce(first(group).active, true)
                max_level = coalesce(first(group).max_downstream_level, Inf)
                table = StructVector(group)
                rowrange =
                    findlastgroup(node_id, NodeID.(node_id.type, table.node_id, Ref(0)))
                if !valid_tabulated_rating_curve(node_id, table, rowrange)
                    errors = true
                end
                interpolation = try
                    qh_interpolation(table, rowrange, interpolation_type)
                catch
                    errors = true
                    interpolation_type(Float64[], Float64[])
                end
                if !ismissing(control_state)
                    control_mapping[(
                        NodeID(NodeType.TabulatedRatingCurve, node_id, node_id.idx),
                        control_state,
                    )] = ControlStateUpdate(
                        ParameterUpdate(:active, is_active),
                        ParameterUpdate{Float64}[],
                        [ParameterUpdate(:table, interpolation)],
                    )
                end
            end
            push!(interpolations, interpolation)
            push!(active, is_active)
            push!(max_downstream_level, max_level)
        elseif node_id in time_node_ids
            source = "time"
            # get the timestamp that applies to the model starttime
            idx_starttime = searchsortedlast(time.time, config.starttime)
            pre_table = view(time, 1:idx_starttime)
            rowrange =
                findlastgroup(node_id, NodeID.(node_id.type, pre_table.node_id, Ref(0)))

            if !valid_tabulated_rating_curve(node_id, pre_table, rowrange)
                errors = true
            end
            interpolation = qh_interpolation(pre_table, rowrange, interpolation_type)
            max_level = coalesce(pre_table.max_downstream_level[rowrange][begin], Inf)
            push!(interpolations, interpolation)
            push!(active, true)
            push!(max_downstream_level, max_level)
        else
            @error "$node_id data not in any table."
            errors = true
        end
    end

    if errors
        error("Errors occurred when parsing TabulatedRatingCurve data.")
    end
    return TabulatedRatingCurve(;
        node_id = node_ids,
        inflow_edge = inflow_edge.(Ref(graph), node_ids),
        outflow_edge = outflow_edge.(Ref(graph), node_ids),
        active,
        max_downstream_level,
        table = interpolations,
        time,
        control_mapping,
    )
end

function ManningResistance(
    db::DB,
    config::Config,
    graph::MetaGraph,
    basin::Basin,
)::ManningResistance
    static = load_structvector(db, config, ManningResistanceStaticV1)
    parsed_parameters, valid = parse_static_and_time(db, config, ManningResistance; static)

    if !valid
        error("Errors occurred when parsing ManningResistance data.")
    end

    (; node_id) = parsed_parameters
    upstream_bottom = basin_bottom.(Ref(basin), inflow_id.(Ref(graph), node_id))
    downstream_bottom = basin_bottom.(Ref(basin), outflow_id.(Ref(graph), node_id))

    return ManningResistance(;
        node_id,
        inflow_edge = inflow_edge.(Ref(graph), node_id),
        outflow_edge = outflow_edge.(Ref(graph), node_id),
        parsed_parameters.active,
        parsed_parameters.length,
        parsed_parameters.manning_n,
        parsed_parameters.profile_width,
        parsed_parameters.profile_slope,
        upstream_bottom = [bottom[2] for bottom in upstream_bottom],
        downstream_bottom = [bottom[2] for bottom in downstream_bottom],
        parsed_parameters.control_mapping,
    )
end

function LevelBoundary(db::DB, config::Config)::LevelBoundary
    static = load_structvector(db, config, LevelBoundaryStaticV1)
    time = load_structvector(db, config, LevelBoundaryTimeV1)
    concentration_time = load_structvector(db, config, LevelBoundaryConcentrationV1)

    _, _, node_ids, valid = static_and_time_node_ids(db, static, time, "LevelBoundary")

    if !valid
        error("Problems encountered when parsing LevelBoundary static and time node IDs.")
    end

    time_interpolatables = [:level]
    parsed_parameters, valid =
        parse_static_and_time(db, config, LevelBoundary; static, time, time_interpolatables)

    substances = get_substances(db, config)
    concentration = zeros(length(node_ids), length(substances))
    concentration[:, Substance.Continuity] .= 1.0
    concentration[:, Substance.LevelBoundary] .= 1.0
    set_concentrations!(concentration, concentration_time, substances, Int32.(node_ids))

    if !valid
        error("Errors occurred when parsing LevelBoundary data.")
    end

    return LevelBoundary(;
        node_id = node_ids,
        parsed_parameters.active,
        parsed_parameters.level,
        concentration,
        concentration_time,
    )
end

function FlowBoundary(db::DB, config::Config, graph::MetaGraph)::FlowBoundary
    static = load_structvector(db, config, FlowBoundaryStaticV1)
    time = load_structvector(db, config, FlowBoundaryTimeV1)
    concentration_time = load_structvector(db, config, FlowBoundaryConcentrationV1)

    _, _, node_ids, valid = static_and_time_node_ids(db, static, time, "FlowBoundary")

    if !valid
        error("Problems encountered when parsing FlowBoundary static and time node IDs.")
    end

    time_interpolatables = [:flow_rate]
    parsed_parameters, valid =
        parse_static_and_time(db, config, FlowBoundary; static, time, time_interpolatables)

    for itp in parsed_parameters.flow_rate
        if any(itp.u .< 0.0)
            @error(
                "Currently negative flow rates are not supported, found some in dynamic flow boundary."
            )
            valid = false
        end
    end

    substances = get_substances(db, config)
    concentration = zeros(length(node_ids), length(substances))
    concentration[:, Substance.Continuity] .= 1.0
    concentration[:, Substance.FlowBoundary] .= 1.0
    set_concentrations!(concentration, concentration_time, substances, Int32.(node_ids))

    if !valid
        error("Errors occurred when parsing FlowBoundary data.")
    end

    return FlowBoundary(;
        node_id = node_ids,
        outflow_edges = outflow_edges.(Ref(graph), node_ids),
        parsed_parameters.active,
        parsed_parameters.flow_rate,
        concentration,
        concentration_time,
    )
end

function Pump(db::DB, config::Config, graph::MetaGraph)::Pump
    static = load_structvector(db, config, PumpStaticV1)
    defaults = (;
        min_flow_rate = 0.0,
        max_flow_rate = Inf,
        min_upstream_level = -Inf,
        max_downstream_level = Inf,
        active = true,
    )
    parsed_parameters, valid = parse_static_and_time(db, config, Pump; static, defaults)

    if !valid
        error("Errors occurred when parsing Pump data.")
    end

    (; node_id) = parsed_parameters

    # If flow rate is set by PID control, it is part of the AD Jacobian computations
    flow_rate = cache(length(node_id))
    flow_rate[Float64[]] .= parsed_parameters.flow_rate

    return Pump(;
        node_id,
        inflow_edge = inflow_edge.(Ref(graph), node_id),
        outflow_edge = outflow_edge.(Ref(graph), node_id),
        parsed_parameters.active,
        flow_rate,
        parsed_parameters.min_flow_rate,
        parsed_parameters.max_flow_rate,
        parsed_parameters.min_upstream_level,
        parsed_parameters.max_downstream_level,
        parsed_parameters.control_mapping,
    )
end

function Outlet(db::DB, config::Config, graph::MetaGraph)::Outlet
    static = load_structvector(db, config, OutletStaticV1)
    defaults = (;
        min_flow_rate = 0.0,
        max_flow_rate = Inf,
        min_upstream_level = -Inf,
        max_downstream_level = Inf,
        active = true,
    )
    parsed_parameters, valid = parse_static_and_time(db, config, Outlet; static, defaults)

    if !valid
        error("Errors occurred when parsing Outlet data.")
    end

    node_id =
        NodeID.(
            NodeType.Outlet,
            parsed_parameters.node_id,
            eachindex(parsed_parameters.node_id),
        )

    # If flow rate is set by PID control, it is part of the AD Jacobian computations
    flow_rate = cache(length(node_id))
    flow_rate[Float64[], length(node_id)] .= parsed_parameters.flow_rate

    return Outlet(;
        node_id,
        inflow_edge = inflow_edge.(Ref(graph), node_id),
        outflow_edge = outflow_edge.(Ref(graph), node_id),
        parsed_parameters.active,
        flow_rate,
        parsed_parameters.min_flow_rate,
        parsed_parameters.max_flow_rate,
        parsed_parameters.control_mapping,
        parsed_parameters.min_upstream_level,
        parsed_parameters.max_downstream_level,
    )
end

function Terminal(db::DB, config::Config)::Terminal
    node_id = get_ids(db, "Terminal")
    return Terminal(NodeID.(NodeType.Terminal, node_id, eachindex(node_id)))
end

function Basin(db::DB, config::Config, graph::MetaGraph)::Basin
    node_id = get_ids(db, "Basin")
    n = length(node_id)

    evaporate_mass = config.solver.evaporate_mass
    precipitation = zeros(n)
    potential_evaporation = zeros(n)
    drainage = zeros(n)
    infiltration = zeros(n)
    table = (; precipitation, potential_evaporation, drainage, infiltration)

    area, level = create_storage_tables(db, config)

    # both static and time are optional, but we need fallback defaults
    static = load_structvector(db, config, BasinStaticV1)
    time = load_structvector(db, config, BasinTimeV1)
    state = load_structvector(db, config, BasinStateV1)
    concentration_state_data = load_structvector(db, config, BasinConcentrationStateV1)
    concentration_time = load_structvector(db, config, BasinConcentrationV1)

    # TODO Move into a function
    substances = get_substances(db, config)
    concentration_state = zeros(n, length(substances))
    concentration_state[:, Substance.Continuity] .= 1.0
    concentration_state[:, Substance.Initial] .= 1.0
    set_concentrations!(concentration_state, concentration_state_data, substances, node_id)
    mass = copy(concentration_state)

    concentration = zeros(2, n, length(substances))
    concentration[1, :, Substance.Continuity] .= 1.0
    concentration[1, :, Substance.Drainage] .= 1.0
    concentration[2, :, Substance.Continuity] .= 1.0
    concentration[2, :, Substance.Precipitation] .= 1.0
    set_concentrations!(
        view(concentration, 1, :, :),
        concentration_time,
        substances,
        node_id;
        concentration_column = :drainage,
    )
    set_concentrations!(
        view(concentration, 1, :, :),
        concentration_time,
        substances,
        node_id;
        concentration_column = :precipitation,
    )

    set_static_value!(table, node_id, static)
    set_current_value!(table, node_id, time, config.starttime)
    check_no_nans(table, "Basin")

    vertical_flux =
        ComponentVector(; precipitation, potential_evaporation, drainage, infiltration)

    demand = zeros(length(node_id))

    node_id = NodeID.(NodeType.Basin, node_id, eachindex(node_id))

    is_valid = valid_profiles(node_id, level, area)
    if !is_valid
        error("Invalid Basin / profile table.")
    end

    level_to_area =
        LinearInterpolation.(area, level; extrapolate = true, cache_parameters = true)
    storage_to_level = invert_integral.(level_to_area)

    t_end = seconds_since(config.endtime, config.starttime)

    errors = false

    concentration_external_data =
        load_structvector(db, config, BasinConcentrationExternalV1)
    concentration_external = Dict{String, ScalarInterpolation}[]
    for id in node_id
        concentration_external_id = Dict{String, ScalarInterpolation}()
        data_id = filter(row -> row.node_id == id.value, concentration_external_data)
        for group in IterTools.groupby(row -> row.substance, data_id)
            first_row = first(group)
            substance = first_row.substance
            itp, no_duplication = get_scalar_interpolation(
                config.starttime,
                t_end,
                StructVector(group),
                NodeID(:Basin, first_row.node_id, 0),
                :concentration,
            )
            concentration_external_id["concentration_external.$substance"] = itp
            if any(itp.u .< 0)
                errors = true
                @error "Found negative concentration(s) in `Basin / concentration_external`." node_id =
                    id, substance
            end
            if !no_duplication
                errors = true
                @error "There are repeated time values for in `Basin / concentration_external`." node_id =
                    id substance
            end
        end
        push!(concentration_external, concentration_external_id)
    end

    if errors
        error("Errors encountered when parsing Basin concentration data.")
    end

    basin = Basin(;
        node_id,
        inflow_ids = [collect(inflow_ids(graph, id)) for id in node_id],
        outflow_ids = [collect(outflow_ids(graph, id)) for id in node_id],
        vertical_flux,
        storage_to_level,
        level_to_area,
        demand,
        time,
        concentration_time,
        evaporate_mass,
        concentration_state,
        concentration,
        mass,
        concentration_external,
        substances,
    )

    storage0 = get_storages_from_levels(basin, state.level)
    @assert length(storage0) == n "Basin / state length differs from number of Basins"
    basin.storage0 .= storage0
    basin.storage_prev .= storage0
    basin.mass .*= storage0  # was initialized by concentration_state, resulting in mass

    return basin
end

"""
Get a CompoundVariable object given its definition in the input data.
References to listened parameters are added later.
"""
function CompoundVariable(
    compound_variable_data,
    node_type::NodeType.T,
    db::DB;
    greater_than = Float64[],
    placeholder_vector = Float64[],
)::CompoundVariable
    subvariables = @NamedTuple{
        listen_node_id::NodeID,
        variable_ref::PreallocationRef,
        variable::String,
        weight::Float64,
        look_ahead::Float64,
    }[]
    # Each row defines a subvariable
    for row in compound_variable_data
        listen_node_id = NodeID(row.listen_node_id, db)
        # Placeholder until actual ref is known
        variable_ref = PreallocationRef(placeholder_vector, 0)
        variable = row.variable
        # Default to weight = 1.0 if not specified
        weight = coalesce(row.weight, 1.0)
        # Default to look_ahead = 0.0 if not specified
        look_ahead = coalesce(row.look_ahead, 0.0)
        subvariable = (; listen_node_id, variable_ref, variable, weight, look_ahead)
        push!(subvariables, subvariable)
    end

    # The ID of the node listening to this CompoundVariable
    node_id = NodeID(node_type, only(unique(compound_variable_data.node_id)), db)
    return CompoundVariable(node_id, subvariables, greater_than)
end

function parse_variables_and_conditions(compound_variable, condition, ids, db, graph)
    placeholder_vector = cache(1)
    compound_variables = Vector{CompoundVariable}[]
    errors = false

    # Loop over unique discrete_control node IDs
    for (i, id) in enumerate(ids)
        discrete_control_id = NodeID(NodeType.DiscreteControl, id, i)

        condition_group_id = filter(row -> row.node_id == id, condition)
        variable_group_id = filter(row -> row.node_id == id, compound_variable)

        compound_variables_node = CompoundVariable[]

        # Loop over compound variables for this node ID
        for compound_variable_id in unique(condition_group_id.compound_variable_id)
            condition_group_variable = filter(
                row -> row.compound_variable_id == compound_variable_id,
                condition_group_id,
            )
            variable_group_variable = filter(
                row -> row.compound_variable_id == compound_variable_id,
                variable_group_id,
            )
            if isempty(variable_group_variable)
                errors = true
                @error "compound_variable_id $compound_variable_id for $discrete_control_id in condition table but not in variable table"
            else
                greater_than = condition_group_variable.greater_than
                push!(
                    compound_variables_node,
                    CompoundVariable(
                        variable_group_variable,
                        NodeType.DiscreteControl,
                        db;
                        greater_than,
                        placeholder_vector,
                    ),
                )
            end
        end
        push!(compound_variables, compound_variables_node)
    end
    return compound_variables, !errors
end

function DiscreteControl(db::DB, config::Config, graph::MetaGraph)::DiscreteControl
    condition = load_structvector(db, config, DiscreteControlConditionV1)
    compound_variable = load_structvector(db, config, DiscreteControlVariableV1)

    ids = get_ids(db, "DiscreteControl")
    node_id = NodeID.(:DiscreteControl, ids, eachindex(ids))
    compound_variables, valid =
        parse_variables_and_conditions(compound_variable, condition, ids, db, graph)

    if !valid
        error("Problems encountered when parsing DiscreteControl variables and conditions.")
    end

    # Initialize the logic mappings
    logic = load_structvector(db, config, DiscreteControlLogicV1)
    logic_mapping = [Dict{String, String}() for _ in eachindex(node_id)]

    for (node_id, truth_state, control_state_) in
        zip(logic.node_id, logic.truth_state, logic.control_state)
        logic_mapping[findsorted(ids, node_id)][truth_state] = control_state_
    end

    logic_mapping = expand_logic_mapping(logic_mapping, node_id)

    # Initialize the truth state per DiscreteControl node
    truth_state = Vector{Bool}[]
    for i in eachindex(node_id)
        truth_state_length = sum(length(var.greater_than) for var in compound_variables[i])
        push!(truth_state, fill(false, truth_state_length))
    end

    controlled_nodes =
        collect.(outneighbor_labels_type.(Ref(graph), node_id, EdgeType.control))

    return DiscreteControl(;
        node_id,
        controlled_nodes,
        compound_variables,
        truth_state,
        logic_mapping,
    )
end

function continuous_control_functions(db, config, ids)
    # Avoid using the variable name `function` as that is recognized as a keyword
    func = load_structvector(db, config, ContinuousControlFunctionV1)
    errors = false
    # Parse the function table
    # Create linear interpolation objects out of the provided functions
    functions = ScalarInterpolation[]
    controlled_variables = String[]

    # Loop over the IDs of the ContinuousControl nodes
    for id in ids
        # Get the function data for this node
        function_rows = filter(row -> row.node_id == id, func)
        unique_controlled_variable = unique(function_rows.controlled_variable)

        # Error handling
        if length(function_rows) < 2
            @error "There must be at least 2 data points in a ContinuousControl function."
            errors = true
        elseif length(unique_controlled_variable) !== 1
            @error "There must be a unique 'controlled_variable' in a ContinuousControl function."
            errors = true
        else
            push!(controlled_variables, only(unique_controlled_variable))
        end
        function_itp = LinearInterpolation(
            function_rows.output,
            function_rows.input;
            extrapolate = true,
            cache_parameters = true,
        )

        push!(functions, function_itp)
    end

    return functions, controlled_variables, errors
end

function continuous_control_compound_variables(db::DB, config::Config, ids)
    placeholder_vector = cache(1)

    data = load_structvector(db, config, ContinuousControlVariableV1)
    compound_variables = CompoundVariable[]

    # Loop over the ContinuousControl node IDs
    for id in ids
        variable_data = filter(row -> row.node_id == id, data)
        push!(
            compound_variables,
            CompoundVariable(
                variable_data,
                NodeType.ContinuousControl,
                db;
                placeholder_vector,
            ),
        )
    end
    compound_variables
end

function ContinuousControl(db::DB, config::Config, graph::MetaGraph)::ContinuousControl
    compound_variable = load_structvector(db, config, ContinuousControlVariableV1)

    ids = get_ids(db, "ContinuousControl")
    node_id = NodeID.(:ContinuousControl, ids, eachindex(ids))

    # Avoid using `function` as a variable name as that is recognized as a keyword
    func, controlled_variable, errors = continuous_control_functions(db, config, ids)
    compound_variable = continuous_control_compound_variables(db, config, ids)

    # References to the controlled parameters, filled in later when they are known
    target_refs = PreallocationRef[]

    if errors
        error("Errors encountered when parsing ContinuousControl data.")
    end

    return ContinuousControl(
        node_id,
        compound_variable,
        controlled_variable,
        target_refs,
        func,
    )
end

function PidControl(db::DB, config::Config, graph::MetaGraph)::PidControl
    static = load_structvector(db, config, PidControlStaticV1)
    time = load_structvector(db, config, PidControlTimeV1)

    _, _, node_ids, valid = static_and_time_node_ids(db, static, time, "PidControl")

    if !valid
        error("Problems encountered when parsing PidControl static and time node IDs.")
    end

    time_interpolatables = [:target, :proportional, :integral, :derivative]
    parsed_parameters, valid =
        parse_static_and_time(db, config, PidControl; static, time, time_interpolatables)

    if !valid
        error("Errors occurred when parsing PidControl data.")
    end

    pid_error = cache(length(node_ids))
    target_ref = PreallocationRef[]

    controlled_basins = Set{NodeID}()
    for id in node_ids
        controlled_node = only(outneighbor_labels_type(graph, id, EdgeType.control))
        for id_inout in inoutflow_ids(graph, controlled_node)
            if id_inout.type == NodeType.Basin
                push!(controlled_basins, id_inout)
            end
        end
    end
    controlled_basins = collect(controlled_basins)

    listen_node_id = NodeID.(parsed_parameters.listen_node_id, Ref(db))

    return PidControl(;
        node_id = node_ids,
        parsed_parameters.active,
        listen_node_id,
        parsed_parameters.target,
        target_ref,
        parsed_parameters.proportional,
        parsed_parameters.integral,
        parsed_parameters.derivative,
        error = pid_error,
        controlled_basins,
        parsed_parameters.control_mapping,
    )
end

function user_demand_static!(
    active::Vector{Bool},
    demand::Matrix{Float64},
    demand_itp::Vector{Vector{ScalarInterpolation}},
    return_factor::Vector{ScalarInterpolation},
    min_level::Vector{Float64},
    static::StructVector{UserDemandStaticV1},
    ids::Vector{Int32},
    priorities::Vector{Int32},
)::Nothing
    for group in IterTools.groupby(row -> row.node_id, static)
        first_row = first(group)
        user_demand_idx = searchsortedfirst(ids, first_row.node_id)

        active[user_demand_idx] = coalesce(first_row.active, true)
        return_factor_old = return_factor[user_demand_idx]
        return_factor[user_demand_idx] = LinearInterpolation(
            fill(first_row.return_factor, 2),
            return_factor_old.t;
            extrapolate = true,
            cache_parameters = true,
        )
        min_level[user_demand_idx] = first_row.min_level

        for row in group
            priority_idx = findsorted(priorities, row.priority)
            demand_row = coalesce(row.demand, 0.0)
            demand_itp_old = demand_itp[user_demand_idx][priority_idx]
            demand_itp[user_demand_idx][priority_idx] = LinearInterpolation(
                fill(demand_row, 2),
                demand_itp_old.t;
                extrapolate = true,
                cache_parameters = true,
            )
            demand[user_demand_idx, priority_idx] = demand_row
        end
    end
    return nothing
end

function user_demand_time!(
    active::Vector{Bool},
    demand::Matrix{Float64},
    demand_itp::Vector{Vector{ScalarInterpolation}},
    demand_from_timeseries::Vector{Bool},
    return_factor::Vector{ScalarInterpolation},
    min_level::Vector{Float64},
    time::StructVector{UserDemandTimeV1},
    ids::Vector{Int32},
    priorities::Vector{Int32},
    config::Config,
)::Bool
    errors = false
    t_end = seconds_since(config.endtime, config.starttime)

    for group in IterTools.groupby(row -> (row.node_id, row.priority), time)
        first_row = first(group)
        user_demand_idx = findsorted(ids, first_row.node_id)

        active[user_demand_idx] = true
        demand_from_timeseries[user_demand_idx] = true
        return_factor_itp, is_valid_return = get_scalar_interpolation(
            config.starttime,
            t_end,
            StructVector(group),
            NodeID(:UserDemand, first_row.node_id, 0),
            :return_factor;
        )
        if is_valid_return
            return_factor[user_demand_idx] = return_factor_itp
        else
            @error "The return_factor(t) relationship for UserDemand $(first_row.node_id) from the time table has repeated timestamps, this can not be interpolated."
            errors = true
        end

        min_level[user_demand_idx] = first_row.min_level

        priority_idx = findsorted(priorities, first_row.priority)
        demand_p_itp, is_valid_demand = get_scalar_interpolation(
            config.starttime,
            t_end,
            StructVector(group),
            NodeID(:UserDemand, first_row.node_id, 0),
            :demand;
            default_value = 0.0,
        )
        demand[user_demand_idx, priority_idx] = demand_p_itp(0.0)

        if is_valid_demand
            demand_itp[user_demand_idx][priority_idx] = demand_p_itp
        else
            @error "The demand(t) relationship for UserDemand $(first_row.node_id) of priority $(first_row.priority_idx) from the time table has repeated timestamps, this can not be interpolated."
            errors = true
        end
    end
    return errors
end

function UserDemand(db::DB, config::Config, graph::MetaGraph)::UserDemand
    static = load_structvector(db, config, UserDemandStaticV1)
    time = load_structvector(db, config, UserDemandTimeV1)
    concentration_time = load_structvector(db, config, UserDemandConcentrationV1)
    ids = get_ids(db, "UserDemand")

    _, _, node_ids, valid = static_and_time_node_ids(db, static, time, "UserDemand")

    if !valid
        error("Problems encountered when parsing UserDemand static and time node IDs.")
    end

    # Initialize vectors for UserDemand fields
    priorities = get_all_priorities(db, config)
    n_user = length(node_ids)
    n_priority = length(priorities)
    active = fill(true, n_user)
    demand = zeros(n_user, n_priority)
    demand_reduced = zeros(n_user, n_priority)
    trivial_timespan = [0.0, prevfloat(Inf)]
    demand_itp = [
        ScalarInterpolation[
            LinearInterpolation(zeros(2), trivial_timespan; cache_parameters = true) for
            i in eachindex(priorities)
        ] for j in eachindex(node_ids)
    ]
    demand_from_timeseries = fill(false, n_user)
    allocated = fill(Inf, n_user, n_priority)
    return_factor = [
        LinearInterpolation(zeros(2), trivial_timespan; cache_parameters = true) for
        i in eachindex(node_ids)
    ]
    min_level = zeros(n_user)

    # Process static table
    user_demand_static!(
        active,
        demand,
        demand_itp,
        return_factor,
        min_level,
        static,
        ids,
        priorities,
    )

    # Process time table
    errors = user_demand_time!(
        active,
        demand,
        demand_itp,
        demand_from_timeseries,
        return_factor,
        min_level,
        time,
        ids,
        priorities,
        config,
    )

    substances = get_substances(db, config)
    concentration = zeros(length(node_ids), length(substances))
    # Continuity concentration is zero, as the return flow (from a Basin) already includes it
    concentration[:, Substance.UserDemand] .= 1.0
    set_concentrations!(concentration, concentration_time, substances, ids)

    if errors || !valid_demand(node_ids, demand_itp, priorities)
        error("Errors occurred when parsing UserDemand data.")
    end

    return UserDemand(;
        node_id = node_ids,
        inflow_edge = inflow_edge.(Ref(graph), node_ids),
        outflow_edge = outflow_edge.(Ref(graph), node_ids),
        active,
        demand,
        demand_reduced,
        demand_itp,
        demand_from_timeseries,
        allocated,
        return_factor,
        min_level,
        concentration,
        concentration_time,
    )
end

function LevelDemand(db::DB, config::Config)::LevelDemand
    static = load_structvector(db, config, LevelDemandStaticV1)
    time = load_structvector(db, config, LevelDemandTimeV1)

    parsed_parameters, valid = parse_static_and_time(
        db,
        config,
        LevelDemand;
        static,
        time,
        time_interpolatables = [:min_level, :max_level],
        defaults = (; min_level = -Inf, max_level = Inf),
    )

    if !valid
        error("Errors occurred when parsing LevelDemand data.")
    end

    (; node_id) = parsed_parameters

    return LevelDemand(
        NodeID.(NodeType.LevelDemand, node_id, eachindex(node_id)),
        parsed_parameters.min_level,
        parsed_parameters.max_level,
        parsed_parameters.priority,
    )
end

function FlowDemand(db::DB, config::Config)::FlowDemand
    static = load_structvector(db, config, FlowDemandStaticV1)
    time = load_structvector(db, config, FlowDemandTimeV1)

    parsed_parameters, valid = parse_static_and_time(
        db,
        config,
        FlowDemand;
        static,
        time,
        time_interpolatables = [:demand],
    )

    if !valid
        error("Errors occurred when parsing FlowDemand data.")
    end

    demand = zeros(length(parsed_parameters.node_id))
    (; node_id) = parsed_parameters

    return FlowDemand(;
        node_id = NodeID.(NodeType.FlowDemand, node_id, eachindex(node_id)),
        demand_itp = parsed_parameters.demand,
        demand,
        parsed_parameters.priority,
    )
end

function Subgrid(db::DB, config::Config, basin::Basin)::Subgrid
    node_to_basin = Dict(node_id => index for (index, node_id) in enumerate(basin.node_id))
    tables = load_structvector(db, config, BasinSubgridV1)

    subgrid_ids = Int32[]
    basin_index = Int32[]
    interpolations = ScalarInterpolation[]
    has_error = false
    for group in IterTools.groupby(row -> row.subgrid_id, tables)
        subgrid_id = first(getproperty.(group, :subgrid_id))
        node_id = NodeID(NodeType.Basin, first(getproperty.(group, :node_id)), db)
        basin_level = getproperty.(group, :basin_level)
        subgrid_level = getproperty.(group, :subgrid_level)

        is_valid =
            valid_subgrid(subgrid_id, node_id, node_to_basin, basin_level, subgrid_level)

        if is_valid
            # Ensure it doesn't extrapolate before the first value.
            pushfirst!(subgrid_level, first(subgrid_level))
            pushfirst!(basin_level, nextfloat(-Inf))
            new_interp = LinearInterpolation(
                subgrid_level,
                basin_level;
                extrapolate = true,
                cache_parameters = true,
            )
            push!(subgrid_ids, subgrid_id)
            push!(basin_index, node_to_basin[node_id])
            push!(interpolations, new_interp)
        else
            has_error = true
        end
    end

    has_error && error("Invalid Basin / subgrid table.")
    level = fill(NaN, length(subgrid_ids))

    return Subgrid(; subgrid_id = subgrid_ids, basin_index, interpolations, level)
end

function Allocation(db::DB, config::Config, graph::MetaGraph)::Allocation
    mean_input_flows = Dict{Tuple{NodeID, NodeID}, Float64}()

    # Find edges which serve as sources in allocation
    for edge_metadata in values(graph.edge_data)
        (; subnetwork_id_source, edge) = edge_metadata
        if subnetwork_id_source != 0
            mean_input_flows[edge] = 0.0
        end
    end

    # Find basins with a level demand
    for node_id in values(graph.vertex_labels)
        if has_external_demand(graph, node_id, :level_demand)[1]
            mean_input_flows[(node_id, node_id)] = 0.0
        end
    end

    mean_realized_flows = Dict{Tuple{NodeID, NodeID}, Float64}()

    # Find edges that realize a demand
    for edge_metadata in values(graph.edge_data)
        (; type, edge) = edge_metadata

        src_id, dst_id = edge
        user_demand_inflow = (type == EdgeType.flow) && (dst_id.type == NodeType.UserDemand)
        level_demand_inflow =
            (type == EdgeType.control) && (src_id.type == NodeType.LevelDemand)
        flow_demand_inflow =
            (type == EdgeType.flow) && has_external_demand(graph, dst_id, :flow_demand)[1]

        if user_demand_inflow || flow_demand_inflow
            mean_realized_flows[edge] = 0.0
        elseif level_demand_inflow
            mean_realized_flows[(dst_id, dst_id)] = 0.0
        end
    end

    return Allocation(;
        priorities = get_all_priorities(db, config),
        mean_input_flows,
        mean_realized_flows,
    )
end

function Parameters(db::DB, config::Config)::Parameters
    graph = create_graph(db, config)
    allocation = Allocation(db, config, graph)

    if !valid_edges(graph)
        error("Invalid edge(s) found.")
    end
    if !valid_n_neighbors(graph)
        error("Invalid number of connections for certain node types.")
    end

    basin = Basin(db, config, graph)

    linear_resistance = LinearResistance(db, config, graph)
    manning_resistance = ManningResistance(db, config, graph, basin)
    tabulated_rating_curve = TabulatedRatingCurve(db, config, graph)
    level_boundary = LevelBoundary(db, config)
    flow_boundary = FlowBoundary(db, config, graph)
    pump = Pump(db, config, graph)
    outlet = Outlet(db, config, graph)
    terminal = Terminal(db, config)
    discrete_control = DiscreteControl(db, config, graph)
    continuous_control = ContinuousControl(db, config, graph)
    pid_control = PidControl(db, config, graph)
    user_demand = UserDemand(db, config, graph)
    level_demand = LevelDemand(db, config)
    flow_demand = FlowDemand(db, config)

    subgrid = Subgrid(db, config, basin)

    p = Parameters(;
        config.starttime,
        graph,
        allocation,
        basin,
        linear_resistance,
        manning_resistance,
        tabulated_rating_curve,
        level_boundary,
        flow_boundary,
        pump,
        outlet,
        terminal,
        discrete_control,
        continuous_control,
        pid_control,
        user_demand,
        level_demand,
        flow_demand,
        subgrid,
        config.solver.water_balance_abstol,
        config.solver.water_balance_reltol,
    )

    collect_control_mappings!(p)
    set_continuous_control_type!(p)
    set_listen_variable_refs!(p)
    set_discrete_controlled_variable_refs!(p)
    set_continuously_controlled_variable_refs!(p)

    # Allocation data structures
    if config.allocation.use_allocation
        initialize_allocation!(p, config)
    end
    return p
end

function get_ids(db::DB, nodetype)::Vector{Int32}
    sql = "SELECT node_id FROM Node WHERE node_type = $(esc_id(nodetype)) ORDER BY node_id"
    return only(execute(columntable, db, sql))
end

function exists(db::DB, tablename::String)
    query = execute(
        db,
        "SELECT name FROM sqlite_master WHERE type='table' AND name=$(esc_id(tablename)) COLLATE NOCASE",
    )
    return !isempty(query)
end

"""
    seconds(period::Millisecond)::Float64

Convert a period of type Millisecond to a Float64 in seconds.
You get Millisecond objects when subtracting two DateTime objects.
Dates.value returns the number of milliseconds.
"""
seconds(period::Millisecond)::Float64 = 0.001 * Dates.value(period)

"""
    seconds_since(t::DateTime, t0::DateTime)::Float64

Convert a DateTime to a float that is the number of seconds since the start of the
simulation. This is used to convert between the solver's inner float time, and the calendar.
"""
seconds_since(t::DateTime, t0::DateTime)::Float64 = seconds(t - t0)

"""
    datetime_since(t::Real, t0::DateTime)::DateTime

Convert a Real that represents the seconds passed since the simulation start to the nearest
DateTime. This is used to convert between the solver's inner float time, and the calendar.
"""
datetime_since(t::Real, t0::DateTime)::DateTime = t0 + Millisecond(round(1000 * t))

"""
    load_data(db::DB, config::Config, nodetype::Symbol, kind::Symbol)::Union{Table, Query, Nothing}

Load data from Arrow files if available, otherwise the database.
Returns either an `Arrow.Table`, `SQLite.Query` or `nothing` if the data is not present.
"""
function load_data(
    db::DB,
    config::Config,
    record::Type{<:Legolas.AbstractRecord},
)::Union{Table, Query, Nothing}
    # TODO load_data doesn't need both config and db, use config to check which one is needed

    schema = Legolas._schema_version_from_record_type(record)

    node, kind = nodetype(schema)
    path = if isnothing(kind)
        nothing
    else
        toml = getfield(config, :toml)
        getfield(getfield(toml, snake_case(node)), kind)
    end
    sqltable = tablename(schema)

    table = if !isnothing(path)
        table_path = input_path(config, path)
        Table(read(table_path))
    elseif exists(db, sqltable)
        execute(db, "select * from $(esc_id(sqltable))")
    else
        nothing
    end

    return table
end

"""
    load_structvector(db::DB, config::Config, ::Type{T})::StructVector{T}

Load data from Arrow files if available, otherwise the database.
Always returns a StructVector of the given struct type T, which is empty if the table is
not found. This function validates the schema, and enforces the required sort order.
"""
function load_structvector(
    db::DB,
    config::Config,
    ::Type{T},
)::StructVector{T} where {T <: AbstractRow}
    table = load_data(db, config, T)

    if table === nothing
        return StructVector{T}(undef, 0)
    end

    nt = Tables.columntable(table)
    if table isa Query && haskey(nt, :time)
        # time has type timestamp and is stored as a String in the database
        # currently SQLite.jl does not automatically convert it to DateTime
        nt = merge(
            nt,
            (;
                time = DateTime.(
                    replace.(nt.time, r"(\.\d{3})\d+$" => s"\1"),  # remove sub ms precision
                    dateformat"yyyy-mm-dd HH:MM:SS.s",
                )
            ),
        )
    end

    table = StructVector{T}(nt)
    sv = Legolas._schema_version_from_record_type(T)
    tableschema = Tables.schema(table)
    if declared(sv) && tableschema !== nothing
        validate(tableschema, sv)
    else
        @warn "No (validation) schema declared for $T"
    end

    return sorted_table!(table)
end

"Read the Basin / profile table and return all area and level and computed storage values"
function create_storage_tables(
    db::DB,
    config::Config,
)::Tuple{Vector{Vector{Float64}}, Vector{Vector{Float64}}}
    profiles = load_structvector(db, config, BasinProfileV1)
    area = Vector{Vector{Float64}}()
    level = Vector{Vector{Float64}}()

    for group in IterTools.groupby(row -> row.node_id, profiles)
        group_area = getproperty.(group, :area)
        group_level = getproperty.(group, :level)
        push!(area, group_area)
        push!(level, group_level)
    end
    return area, level
end

"Determine all substances present in the input over multiple tables"
function get_substances(db::DB, config::Config)::OrderedSet{Symbol}
    # Hardcoded tracers
    substances = OrderedSet{Symbol}(Symbol.(instances(Substance.T)))
    for table in [
        BasinConcentrationStateV1,
        BasinConcentrationV1,
        FlowBoundaryConcentrationV1,
        LevelBoundaryConcentrationV1,
        UserDemandConcentrationV1,
    ]
        data = load_structvector(db, config, table)
        for row in data
            push!(substances, Symbol(row.substance))
        end
    end
    return substances
end

"Set values in wide concentration matrix from a long input table."
function set_concentrations!(
    concentration,
    concentration_data,
    substances,
    node_ids;
    concentration_column = :concentration,
)
    for substance in unique(concentration_data.substance)
        data_sub = filter(row -> row.substance == substance, concentration_data)
        sub_idx = findfirst(==(Symbol(substance)), substances)
        for group in IterTools.groupby(row -> row.node_id, data_sub)
            first_row = first(group)
            value = getproperty(first_row, concentration_column)
            ismissing(value) && continue
            node_idx = findfirst(==(first_row.node_id), node_ids)
            concentration[node_idx, sub_idx] = value
        end
    end
end
