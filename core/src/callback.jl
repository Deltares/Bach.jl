"""
Create the different callbacks that are used to store results
and feed the simulation with new data. The different callbacks
are combined to a CallbackSet that goes to the integrator.
Returns the CallbackSet and the SavedValues for flow.
"""
function create_callbacks(
    parameters::Parameters,
    config::Config,
    u0::ComponentVector,
    saveat,
)::Tuple{CallbackSet, SavedResults}
    (; starttime, basin, flow_boundary, level_boundary, user_demand) = parameters
    callbacks = SciMLBase.DECallback[]

    # Check for negative storage
    negative_storage_cb = FunctionCallingCallback(check_negative_storage)
    push!(callbacks, negative_storage_cb)

    # Save storages and levels
    saved_basin_states = SavedValues(Float64, SavedBasinState)
    save_basin_state_cb = SavingCallback(save_basin_state, saved_basin_states; saveat)
    push!(callbacks, save_basin_state_cb)

    # Update cumulative flows (exact integration and for allocation)
    cumulative_flows_cb =
        FunctionCallingCallback(update_cumulative_flows!; func_start = false)
    push!(callbacks, cumulative_flows_cb)

    if config.experimental.concentration
        # Update concentrations
        concentrations_cb =
            FunctionCallingCallback(update_concentrations!; func_start = false)
        push!(callbacks, concentrations_cb)
    end

    # Update Basin forcings
    # All variables are given at the same time, so just precipitation works
    times = [itp.t for itp in basin.forcing.precipitation]
    tstops = Float64[]
    for t in times
        append!(tstops, t)
    end
    unique!(sort!(tstops))
    basin_cb = PresetTimeCallback(tstops, update_basin!; save_positions = (false, false))
    push!(callbacks, basin_cb)

    if config.experimental.concentration
        # Update boundary concentrations
        for (boundary, func) in (
            (basin, update_basin_conc!),
            (flow_boundary, update_flowb_conc!),
            (level_boundary, update_levelb_conc!),
            (user_demand, update_userd_conc!),
        )
            tstops = get_tstops(boundary.concentration_time.time, starttime)
            conc_cb = PresetTimeCallback(tstops, func; save_positions = (false, false))
            push!(callbacks, conc_cb)
        end
    end

    # If saveat is a vector which contains 0.0 this callback will still be called
    # at t = 0.0 despite save_start = false
    saveat = saveat isa Vector ? filter(x -> x != 0.0, saveat) : saveat

    # save the flows averaged over the saveat intervals
    saved_flow = SavedValues(Float64, SavedFlow{typeof(u0)})
    save_flow_cb = SavingCallback(save_flow, saved_flow; saveat, save_start = false)
    push!(callbacks, save_flow_cb)

    # save solver stats
    saved_solver_stats = SavedValues(Float64, SolverStats)
    solver_stats_cb =
        SavingCallback(save_solver_stats, saved_solver_stats; saveat, save_start = true)
    push!(callbacks, solver_stats_cb)

    # interpolate the levels
    saved_subgrid_level = SavedValues(Float64, Vector{Float64})
    if config.results.subgrid
        export_cb = SavingCallback(
            save_subgrid_level,
            saved_subgrid_level;
            saveat,
            save_start = true,
        )
        push!(callbacks, export_cb)
    end

    discrete_control_cb = FunctionCallingCallback(apply_discrete_control!)
    push!(callbacks, discrete_control_cb)

    saved = SavedResults(
        saved_flow,
        saved_basin_states,
        saved_subgrid_level,
        saved_solver_stats,
    )
    callback = CallbackSet(callbacks...)

    return callback, saved
end

"""
Update with the latest timestep:
- Cumulative flows/forcings which are integrated exactly
- Cumulative flows/forcings which are input for the allocation algorithm
- Cumulative flows/forcings which are realized demands in the allocation context

During these cumulative flow updates, we can also update the mass balance of the system,
as each flow carries mass, based on the concentrations of the flow source.
Specifically, we first use all the inflows to update the mass of the Basins, recalculate
the Basin concentration(s) and then remove the mass that is being lost to the outflows.
"""
function update_cumulative_flows!(u, t, integrator)::Nothing
    (; p, tprev, dt) = integrator
    (; basin, flow_boundary, allocation) = p
    (; vertical_flux) = basin

    # Update tprev
    p.tprev = t

    # Update cumulative forcings which are integrated exactly
    @. basin.cumulative_drainage += vertical_flux.drainage * dt
    @. basin.cumulative_drainage_saveat += vertical_flux.drainage * dt

    # Precipitation depends on fixed area
    for node_id in basin.node_id
        fixed_area = basin_areas(basin, node_id.idx)[end]
        added_precipitation = fixed_area * vertical_flux.precipitation[node_id.idx] * dt

        basin.cumulative_precipitation[node_id.idx] += added_precipitation
        basin.cumulative_precipitation_saveat[node_id.idx] += added_precipitation
    end

    # Exact boundary flow over time step
    for (id, flow_rate, active, link) in zip(
        flow_boundary.node_id,
        flow_boundary.flow_rate,
        flow_boundary.active,
        flow_boundary.outflow_links,
    )
        if active
            outflow_id = link[1].link[2]
            volume = integral(flow_rate, tprev, t)
            flow_boundary.cumulative_flow[id.idx] += volume
            flow_boundary.cumulative_flow_saveat[id.idx] += volume
        end
    end

    # Update realized flows for allocation input
    for subnetwork_id in allocation.subnetwork_ids
        mean_input_flows_subnetwork_ = mean_input_flows_subnetwork(p, subnetwork_id)
        for link in keys(mean_input_flows_subnetwork_)
            mean_input_flows_subnetwork_[link] += flow_update_on_link(integrator, link)
        end
    end

    # Update realized flows for allocation output
    for link in keys(allocation.mean_realized_flows)
        allocation.mean_realized_flows[link] += flow_update_on_link(integrator, link)
        if link[1] == link[2]
            basin_id = link[1]
            @assert basin_id.type == NodeType.Basin
            for inflow_id in basin.inflow_ids[basin_id.idx]
                allocation.mean_realized_flows[link] +=
                    flow_update_on_link(integrator, (inflow_id, basin_id))
            end
            for outflow_id in basin.outflow_ids[basin_id.idx]
                allocation.mean_realized_flows[link] -=
                    flow_update_on_link(integrator, (basin_id, outflow_id))
            end
        end
    end
    return nothing
end

function update_concentrations!(u, t, integrator)::Nothing
    (; uprev, p, tprev, dt) = integrator
    (; basin, flow_boundary) = p
    (; vertical_flux, concentration_data) = basin
    (; evaporate_mass, cumulative_in, concentration_state, concentration, mass) =
        concentration_data

    # Reset cumulative flows, used to calculate the concentration
    # of the basins after processing inflows only
    cumulative_in .= 0.0

    @views mass .+= concentration[1, :, :] .* vertical_flux.drainage * dt
    basin.concentration_data.cumulative_in .= vertical_flux.drainage * dt

    # Precipitation depends on fixed area
    for node_id in basin.node_id
        fixed_area = basin_areas(basin, node_id.idx)[end]
        added_precipitation = fixed_area * vertical_flux.precipitation[node_id.idx] * dt
        @views mass[node_id.idx, :] .+=
            concentration[2, node_id.idx, :] .* added_precipitation
        cumulative_in[node_id.idx] += added_precipitation
    end

    # Exact boundary flow over time step
    for (id, flow_rate, active, link) in zip(
        flow_boundary.node_id,
        flow_boundary.flow_rate,
        flow_boundary.active,
        flow_boundary.outflow_links,
    )
        if active
            outflow_id = link[1].link[2]
            volume = integral(flow_rate, tprev, t)
            @views mass[outflow_id.idx, :] .+=
                flow_boundary.concentration[id.idx, :] .* volume
            cumulative_in[outflow_id.idx] += volume
        end
    end

    mass_updates_user_demand!(integrator)
    mass_inflows_basin!(integrator)

    # Update the Basin concentrations based on the added mass and flows
    concentration_state .= mass ./ (basin.storage_prev .+ cumulative_in)

    mass_outflows_basin!(integrator)

    # Evaporate mass to keep the mass balance, if enabled in model config
    if evaporate_mass
        mass .-= concentration_state .* (u.evaporation - uprev.evaporation)
    end
    mass .-= concentration_state .* (u.infiltration - uprev.infiltration)

    # Take care of infinitely small masses, possibly becoming negative due to truncation.
    for I in eachindex(basin.concentration_data.mass)
        if (-eps(Float64)) < mass[I] < (eps(Float64))
            mass[I] = 0.0
        end
    end

    # Check for negative masses
    if any(<(0), mass)
        R = CartesianIndices(mass)
        locations = findall(<(0), mass)
        for I in locations
            basin_idx, substance_idx = Tuple(R[I])
            @error "$(basin.node_id[basin_idx]) has negative mass $(basin.concentration_data.mass[I]) for substance $(basin.concentration_data.substances[substance_idx])"
        end
        error("Negative mass(es) detected")
    end

    # Update the Basin concentrations again based on the removed mass
    concentration_state .= mass ./ basin.current_properties.current_storage[parent(u)]
    basin.storage_prev .= basin.current_properties.current_storage[parent(u)]
    basin.level_prev .= basin.current_properties.current_level[parent(u)]
    return nothing
end

"""
Given an link (from_id, to_id), compute the cumulative flow over that
link over the latest timestep. If from_id and to_id are both the same Basin,
the function returns the sum of the Basin forcings.
"""
function flow_update_on_link(
    integrator::DEIntegrator,
    link_src::Tuple{NodeID, NodeID},
)::Float64
    (; u, uprev, p, t, tprev, dt) = integrator
    (; basin, flow_boundary) = p
    (; vertical_flux) = basin
    from_id, to_id = link_src
    if from_id == to_id
        @assert from_id.type == to_id.type == NodeType.Basin
        idx = from_id.idx
        fixed_area = basin_areas(basin, idx)[end]
        (fixed_area * vertical_flux.precipitation[idx] + vertical_flux.drainage[idx]) * dt -
        (u.evaporation[idx] - uprev.evaporation[idx]) -
        (u.infiltration[idx] - uprev.infiltration[idx])
    elseif from_id.type == NodeType.FlowBoundary
        if flow_boundary.active[from_id.idx]
            integral(flow_boundary.flow_rate[from_id.idx], tprev, t)
        else
            0.0
        end
    else
        flow_idx = get_state_index(u, link_src)
        u[flow_idx] - uprev[flow_idx]
    end
end

"""
Save the storages and levels at the latest t.
"""
function save_basin_state(u, t, integrator)
    (; p) = integrator
    (; basin) = p
    du = get_du(integrator)
    current_storage = basin.current_properties.current_storage[parent(du)]
    current_level = basin.current_properties.current_level[parent(du)]
    water_balance!(du, u, p, t)
    SavedBasinState(; storage = copy(current_storage), level = copy(current_level), t)
end

"""
Save all cumulative forcings and flows over links over the latest timestep,
Both computed by the solver and integrated exactly. Also computes the total horizontal
inflow and outflow per Basin.
"""
function save_flow(u, t, integrator)
    (; p) = integrator
    (; basin, state_inflow_link, state_outflow_link, flow_boundary, u_prev_saveat) = p
    Δt = get_Δt(integrator)
    flow_mean = (u - u_prev_saveat) / Δt

    # Current u is previous u in next computation
    u_prev_saveat .= u

    inflow_mean = zeros(length(basin.node_id))
    outflow_mean = zeros(length(basin.node_id))

    # Flow contributions from horizontal flow states
    for (flow, inflow_link, outflow_link) in
        zip(flow_mean, state_inflow_link, state_outflow_link)
        inflow_id = inflow_link.link[1]
        if inflow_id.type == NodeType.Basin
            if flow > 0
                outflow_mean[inflow_id.idx] += flow
            else
                inflow_mean[inflow_id.idx] -= flow
            end
        end

        outflow_id = outflow_link.link[2]
        if outflow_id.type == NodeType.Basin
            if flow > 0
                inflow_mean[outflow_id.idx] += flow
            else
                outflow_mean[outflow_id.idx] -= flow
            end
        end
    end

    # Flow contributions from flow boundaries
    flow_boundary_mean = copy(flow_boundary.cumulative_flow_saveat) ./ Δt
    flow_boundary.cumulative_flow_saveat .= 0.0

    for (outflow_links, id) in zip(flow_boundary.outflow_links, flow_boundary.node_id)
        flow = flow_boundary_mean[id.idx]
        for outflow_link in outflow_links
            outflow_id = outflow_link.link[2]
            if outflow_id.type == NodeType.Basin
                inflow_mean[outflow_id.idx] += flow
            end
        end
    end

    precipitation = copy(basin.cumulative_precipitation_saveat) ./ Δt
    drainage = copy(basin.cumulative_drainage_saveat) ./ Δt
    @. basin.cumulative_precipitation_saveat = 0.0
    @. basin.cumulative_drainage_saveat = 0.0

    concentration = copy(basin.concentration_data.concentration_state)
    saved_flow = SavedFlow(;
        flow = flow_mean,
        inflow = inflow_mean,
        outflow = outflow_mean,
        flow_boundary = flow_boundary_mean,
        precipitation,
        drainage,
        concentration,
        t,
    )
    check_water_balance_error!(saved_flow, integrator, Δt)
    return saved_flow
end

function check_water_balance_error!(
    saved_flow::SavedFlow,
    integrator::DEIntegrator,
    Δt::Float64,
)::Nothing
    (; u, p, t) = integrator
    (; basin, water_balance_abstol, water_balance_reltol) = p
    errors = false
    current_storage = basin.current_properties.current_storage[parent(u)]

    # The initial storage is irrelevant for the storage rate and can only cause
    # floating point truncation errors
    formulate_storages!(current_storage, u, u, p, t; add_initial_storage = false)

    for (
        inflow_rate,
        outflow_rate,
        precipitation,
        drainage,
        evaporation,
        infiltration,
        s_now,
        s_prev,
        id,
    ) in zip(
        saved_flow.inflow,
        saved_flow.outflow,
        saved_flow.precipitation,
        saved_flow.drainage,
        saved_flow.flow.evaporation,
        saved_flow.flow.infiltration,
        current_storage,
        basin.Δstorage_prev_saveat,
        basin.node_id,
    )
        storage_rate = (s_now - s_prev) / Δt
        total_in = inflow_rate + precipitation + drainage
        total_out = outflow_rate + evaporation + infiltration
        balance_error = storage_rate - (total_in - total_out)
        mean_flow_rate = (total_in + total_out) / 2
        relative_error = iszero(mean_flow_rate) ? 0.0 : balance_error / mean_flow_rate

        if abs(balance_error) > water_balance_abstol &&
           abs(relative_error) > water_balance_reltol
            errors = true
            @error "Too large water balance error" id balance_error relative_error
        end

        saved_flow.storage_rate[id.idx] = storage_rate
        saved_flow.balance_error[id.idx] = balance_error
        saved_flow.relative_error[id.idx] = relative_error
    end
    if errors
        t = datetime_since(t, p.starttime)
        error("Too large water balance error(s) detected at t = $t")
    end

    @. basin.Δstorage_prev_saveat = current_storage
    return nothing
end

function save_solver_stats(u, t, integrator)
    (; stats) = integrator.sol
    (;
        time = t,
        rhs_calls = stats.nf,
        linear_solves = stats.nsolve,
        accepted_timesteps = stats.naccept,
        rejected_timesteps = stats.nreject,
    )
end

function check_negative_storage(u, t, integrator)::Nothing
    (; basin) = integrator.p
    (; node_id, current_properties) = basin
    (; current_storage) = current_properties
    du = get_du(integrator)
    set_current_basin_properties!(du, u, integrator.p, t)
    current_storage = current_storage[parent(du)]

    errors = false
    for id in node_id
        if current_storage[id.idx] < 0
            @error "Negative storage detected in $id"
            errors = true
        end
    end

    if errors
        t_datetime = datetime_since(integrator.t, integrator.p.starttime)
        error("Negative storages found at $t_datetime.")
    end
    return nothing
end

"""
Apply the discrete control logic. There's somewhat of a complex structure:
- Each DiscreteControl node can have one or multiple compound variables it listens to
- A compound variable is defined as a linear combination of state/time derived parameters of the model
- Each compound variable has associated with it a sorted vector of greater_than values, which define an ordered
    list of conditions of the form (compound variable value) => greater_than
- Thus, to find out which conditions are true, we only need to find the largest index in the greater than values
    such that the above condition is true
- The truth value (true/false) of all these conditions for all variables of a DiscreteControl node are concatenated
    (in preallocated memory) into what is called the nodes truth state. This concatenation happens in the order in which
    the compound variables appear in discrete_control.compound_variables
- The DiscreteControl node maps this truth state via the logic mapping to a control state, which is a string
- The nodes that are controlled by this DiscreteControl node must have the same control state, for which they have
    parameter values associated with that control state defined in their control_mapping
"""
function apply_discrete_control!(u, t, integrator)::Nothing
    (; p) = integrator
    (; discrete_control) = p
    (; node_id) = discrete_control
    du = get_du(integrator)
    water_balance!(du, u, p, t)

    # Loop over the discrete control nodes to determine their truth state
    # and detect possible control state changes
    for i in eachindex(node_id)
        id = node_id[i]
        truth_state = discrete_control.truth_state[i]
        compound_variables = discrete_control.compound_variables[i]

        # Whether a change in truth state was detected, and thus whether
        # a change in control state is possible
        truth_state_change = false

        # As the truth state of this node is being updated for the different variables
        # it listens to, this is the first index of the truth values for the current variable
        truth_value_variable_idx = 1

        # Loop over the variables listened to by this discrete control node
        for compound_variable in compound_variables
            value = compound_variable_value(compound_variable, p, du, t)

            # The thresholds the value of this variable is being compared with
            greater_thans = compound_variable.greater_than
            n_greater_than = length(greater_thans)

            # Find the largest index i within the greater thans for this variable
            # such that value >= greater_than and shift towards the index in the truth state
            largest_true_index =
                truth_value_variable_idx - 1 + searchsortedlast(greater_thans, value)

            # Update the truth values in the truth states for the current discrete control node
            # corresponding to the conditions on the current variable
            for truth_value_idx in
                truth_value_variable_idx:(truth_value_variable_idx + n_greater_than - 1)
                new_truth_state = (truth_value_idx <= largest_true_index)
                # If no truth state change was detected yet, check whether there is a change
                # at this position
                if !truth_state_change
                    truth_state_change = (new_truth_state != truth_state[truth_value_idx])
                end
                truth_state[truth_value_idx] = new_truth_state
            end

            truth_value_variable_idx += n_greater_than
        end

        # If no truth state change whas detected for this node, no control
        # state change is possible either
        if !((t == 0) || truth_state_change)
            continue
        end

        set_new_control_state!(integrator, id, truth_state)
    end
    return nothing
end

function set_new_control_state!(
    integrator,
    discrete_control_id::NodeID,
    truth_state::Vector{Bool},
)::Nothing
    (; p) = integrator
    (; discrete_control) = p

    # Get the control state corresponding to the new truth state,
    # if one is defined
    control_state_new =
        get(discrete_control.logic_mapping[discrete_control_id.idx], truth_state, nothing)
    isnothing(control_state_new) && error(
        lazy"No control state specified for $discrete_control_id for truth state $truth_state.",
    )

    # Check the new control state against the current control state
    # If there is a change, update parameters and the discrete control record
    control_state_now = discrete_control.control_state[discrete_control_id.idx]
    if control_state_now != control_state_new
        record = discrete_control.record

        push!(record.time, integrator.t)
        push!(record.control_node_id, Int32(discrete_control_id))
        push!(record.truth_state, convert_truth_state(truth_state))
        push!(record.control_state, control_state_new)

        # Loop over nodes which are under control of this control node
        for target_node_id in discrete_control.controlled_nodes[discrete_control_id.idx]
            set_control_params!(p, target_node_id, control_state_new)
        end

        discrete_control.control_state[discrete_control_id.idx] = control_state_new
        discrete_control.control_state_start[discrete_control_id.idx] = integrator.t
    end
    return nothing
end

"""
Get a value for a condition. Currently supports getting levels from basins and flows
from flow boundaries.
"""
function get_value(subvariable::NamedTuple, p::Parameters, du::AbstractVector, t::Float64)
    (; flow_boundary, level_boundary, basin) = p
    (; listen_node_id, look_ahead, variable, variable_ref) = subvariable

    if !iszero(variable_ref.idx)
        return get_value(variable_ref, du)
    end

    if variable == "level"
        if listen_node_id.type == NodeType.LevelBoundary
            level = level_boundary.level[listen_node_id.idx](t + look_ahead)
        else
            error(
                "Level condition node '$node_id' is neither a basin nor a level boundary.",
            )
        end
        value = level

    elseif variable == "flow_rate"
        if listen_node_id.type == NodeType.FlowBoundary
            value = flow_boundary.flow_rate[listen_node_id.idx](t + look_ahead)
        else
            error("Flow condition node $listen_node_id is not a flow boundary.")
        end

    elseif startswith(variable, "concentration_external.")
        value =
            basin.concentration_data.concentration_external[listen_node_id.idx][variable](t)
    elseif startswith(variable, "concentration.")
        substance = Symbol(last(split(variable, ".")))
        var_idx = findfirst(==(substance), basin.concentration_data.substances)
        value = basin.concentration_data.concentration_state[listen_node_id.idx, var_idx]
    else
        error("Unsupported condition variable $variable.")
    end

    return value
end

function compound_variable_value(compound_variable::CompoundVariable, p, du, t)
    value = zero(eltype(du))
    for subvariable in compound_variable.subvariables
        value += subvariable.weight * get_value(subvariable, p, du, t)
    end
    return value
end

function get_allocation_model(p::Parameters, subnetwork_id::Int32)::AllocationModel
    (; allocation) = p
    (; subnetwork_ids, allocation_models) = allocation
    idx = findsorted(subnetwork_ids, subnetwork_id)
    if isnothing(idx)
        error("Invalid allocation network ID $subnetwork_id.")
    else
        return allocation_models[idx]
    end
end

function set_control_params!(p::Parameters, node_id::NodeID, control_state::String)::Nothing
    (; discrete_control, allocation) = p
    (; control_mappings) = discrete_control
    control_state_update = control_mappings[node_id.type][(node_id, control_state)]
    (; active, scalar_update, itp_update) = control_state_update
    apply_parameter_update!(active)
    apply_parameter_update!.(scalar_update)
    apply_parameter_update!.(itp_update)

    return nothing
end

function apply_parameter_update!(parameter_update)::Nothing
    (; name, value, ref) = parameter_update

    # Ignore this parameter update of the associated node does
    # not have an 'active' field
    if name == :active && ref.i == 0
        return nothing
    end
    ref[] = value
    return nothing
end

function update_subgrid_level!(integrator)::Nothing
    (; p, t) = integrator
    du = get_du(integrator)
    basin_level = p.basin.current_properties.current_level[parent(du)]
    subgrid = integrator.p.subgrid

    # First update the all the subgrids with static h(h) relations
    for (level_index, basin_index, hh_itp) in zip(
        subgrid.level_index_static,
        subgrid.basin_index_static,
        subgrid.interpolations_static,
    )
        subgrid.level[level_index] = hh_itp(basin_level[basin_index])
    end
    # Then update the subgrids with dynamic h(h) relations
    for (level_index, basin_index, lookup) in zip(
        subgrid.level_index_time,
        subgrid.basin_index_time,
        subgrid.current_interpolation_index,
    )
        itp_index = Int(lookup(t))
        hh_itp = subgrid.interpolations_time[itp_index]
        subgrid.level[level_index] = hh_itp(basin_level[basin_index])
    end
end

"Interpolate the levels and save them to SavedValues"
function save_subgrid_level(u, t, integrator)
    update_subgrid_level!(integrator)
    return copy(integrator.p.subgrid.level)
end

"Update one current vertical flux from an interpolation at time t."
function set_flux!(
    fluxes::AbstractVector{Float64},
    interpolations::Vector{ScalarConstantInterpolation},
    i::Int,
    t,
)::Nothing
    val = interpolations[i](t)
    # keep old value if new value is NaN
    if !isnan(val)
        fluxes[i] = val
    end
    return nothing
end

"""
Update all current vertical fluxes from an interpolation at time t.

This runs in a callback rather than the RHS since that gives issues with the discontinuities
in the ConstantInterpolations we use, failing the vertical_flux_means test.
"""
function update_basin!(integrator)::Nothing
    (; p, t) = integrator
    (; basin) = p

    update_basin!(basin, t)
    return nothing
end

function update_basin!(basin::Basin, t)::Nothing
    (; vertical_flux, forcing) = basin
    for id in basin.node_id
        i = id.idx
        set_flux!(vertical_flux.precipitation, forcing.precipitation, i, t)
        set_flux!(vertical_flux.potential_evaporation, forcing.potential_evaporation, i, t)
        set_flux!(vertical_flux.infiltration, forcing.infiltration, i, t)
        set_flux!(vertical_flux.drainage, forcing.drainage, i, t)
    end

    return nothing
end

"Load updates from 'Basin / concentration' into the parameters"
function update_basin_conc!(integrator)::Nothing
    (; p) = integrator
    (; basin) = p
    (; node_id, concentration_data, concentration_time) = basin
    (; concentration, substances) = concentration_data
    t = datetime_since(integrator.t, integrator.p.starttime)

    rows = searchsorted(concentration_time.time, t)
    timeblock = view(concentration_time, rows)

    for row in timeblock
        i = searchsortedfirst(node_id, NodeID(NodeType.Basin, row.node_id, 0))
        j = findfirst(==(Symbol(row.substance)), substances)
        ismissing(row.drainage) || (concentration[1, i, j] = row.drainage)
        ismissing(row.precipitation) || (concentration[2, i, j] = row.precipitation)
    end
    return nothing
end

"Load updates from 'concentration' tables into the parameters"
function update_conc!(integrator, parameter, nodetype)::Nothing
    (; p) = integrator
    node = getproperty(p, parameter)
    (; basin) = p
    (; node_id, concentration, concentration_time) = node
    (; substances) = basin.concentration_data
    t = datetime_since(integrator.t, integrator.p.starttime)

    rows = searchsorted(concentration_time.time, t)
    timeblock = view(concentration_time, rows)

    for row in timeblock
        i = searchsortedfirst(node_id, NodeID(nodetype, row.node_id, 0))
        j = findfirst(==(Symbol(row.substance)), substances)
        ismissing(row.concentration) || (concentration[i, j] = row.concentration)
    end
    return nothing
end
update_flowb_conc!(integrator)::Nothing =
    update_conc!(integrator, :flow_boundary, NodeType.FlowBoundary)
update_levelb_conc!(integrator)::Nothing =
    update_conc!(integrator, :level_boundary, NodeType.LevelBoundary)
update_userd_conc!(integrator)::Nothing =
    update_conc!(integrator, :user_demand, NodeType.UserDemand)

"Solve the allocation problem for all demands and assign allocated abstractions."
function update_allocation!(integrator)::Nothing
    (; p, t, u) = integrator
    (; allocation, basin) = p
    (; current_storage) = basin.current_properties
    (; allocation_models, mean_input_flows, mean_realized_flows) = allocation

    # Make sure current storages are up to date
    du = get_du(integrator)
    current_storage = current_storage[parent(du)]
    formulate_storages!(current_storage, du, u, p, t)

    # Don't run the allocation algorithm if allocation is not active
    # (Specifically for running Ribasim via the BMI)
    if !is_active(allocation)
        return nothing
    end

    # Divide by the allocation Δt to get the mean input flows from the cumulative flows
    (; Δt_allocation) = allocation_models[1]
    for mean_input_flows_subnetwork in values(mean_input_flows)
        for link in keys(mean_input_flows_subnetwork)
            mean_input_flows_subnetwork[link] /= Δt_allocation
        end
    end

    # Divide by the allocation Δt to get the mean realized flows from the cumulative flows
    for link in keys(mean_realized_flows)
        mean_realized_flows[link] /= Δt_allocation
    end

    # If a main network is present, collect demands of subnetworks
    if has_main_network(allocation)
        for allocation_model in Iterators.drop(allocation_models, 1)
            collect_demands!(p, allocation_model, t, u)
        end
    end

    # Solve the allocation problems
    # If a main network is present this is solved first,
    # which provides allocation to the subnetworks
    for allocation_model in allocation_models
        allocate_demands!(p, allocation_model, t, u)
    end

    # Reset the mean flows
    for mean_flows in mean_input_flows
        for link in keys(mean_flows)
            mean_flows[link] = 0.0
        end
    end
    for link in keys(mean_realized_flows)
        mean_realized_flows[link] = 0.0
    end
end

function update_subgrid_level(model::Model)::Model
    update_subgrid_level!(model.integrator)
    return model
end
