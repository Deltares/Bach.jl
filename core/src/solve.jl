"""
The right hand side function of the system of ODEs set up by Ribasim.
"""
function water_balance!(
    du::ComponentVector,
    u::ComponentVector,
    p::Parameters,
    t::Number,
)::Nothing
    (; basin, pid_control) = p
    (; current_storage, current_low_storage_factor, current_level) =
        basin.current_properties

    du .= 0.0

    # Ensures current_* vectors are current
    set_current_basin_properties!(du, u, p, t)

    current_storage = current_storage[parent(du)]
    current_low_storage_factor = current_low_storage_factor[parent(du)]
    current_level = current_level[parent(du)]

    # Notes on the ordering of these formulations:
    # - Continuous control can depend on flows (which are not continuously controlled themselves),
    #   so these flows have to be formulated first.
    # - Pid control can depend on the du of basins and subsequently change them
    #   because of the error derivative term.

    # Basin forcings
    update_vertical_flux!(basin, du)

    # Formulate intermediate flows (non continuously controlled)
    formulate_flows!(du, p, t, current_storage, current_low_storage_factor, current_level)

    # Compute continuous control
    formulate_continuous_control!(du, p, t)

    # Formulate intermediate flows (controlled by ContinuousControl)
    formulate_flows!(
        du,
        p,
        t,
        current_storage,
        current_low_storage_factor,
        current_level;
        continuous_control_type = ContinuousControlType.Continuous,
    )

    # Compute PID control
    formulate_pid_control!(u, du, pid_control, p, t)

    # Formulate intermediate flow (controlled by PID control)
    formulate_flows!(
        du,
        p,
        t,
        current_storage,
        current_low_storage_factor,
        current_level;
        continuous_control_type = ContinuousControlType.PID,
    )

    return nothing
end

function formulate_continuous_control!(du, p, t)::Nothing
    (; compound_variable, target_ref, func) = p.continuous_control

    for (cvar, ref, func_) in zip(compound_variable, target_ref, func)
        value = compound_variable_value(cvar, p, du, t)
        set_value!(ref, func_(value), du)
    end
    return nothing
end

"""
Compute the storages, levels and areas of all Basins given the
state u and the time t.
"""
function set_current_basin_properties!(
    du::ComponentVector,
    u::ComponentVector,
    p::Parameters,
    t::Number,
)::Nothing
    (; basin) = p
    (; current_properties, cumulative_precipitation, cumulative_drainage, vertical_flux) =
        basin
    (;
        current_storage,
        current_low_storage_factor,
        current_level,
        current_area,
        current_cumulative_precipitation,
        current_cumulative_drainage,
    ) = current_properties

    current_storage = current_storage[parent(du)]
    current_low_storage_factor = current_low_storage_factor[parent(du)]
    current_level = current_level[parent(du)]
    current_area = current_area[parent(du)]
    current_cumulative_precipitation = current_cumulative_precipitation[parent(du)]
    current_cumulative_drainage = current_cumulative_drainage[parent(du)]

    # The exact cumulative precipitation and drainage up to the t of this water_balance call
    dt = t - p.tprev
    for node_id in basin.node_id
        fixed_area = basin_areas(basin, node_id.idx)[end]
        current_cumulative_precipitation[node_id.idx] =
            cumulative_precipitation[node_id.idx] +
            fixed_area * vertical_flux.precipitation[node_id.idx] * dt
    end
    @. current_cumulative_drainage = cumulative_drainage + dt * vertical_flux.drainage

    formulate_storages!(current_storage, du, u, p, t)

    for (id, s) in zip(basin.node_id, current_storage)
        i = id.idx
        current_low_storage_factor[i] = reduction_factor(s, LOW_STORAGE_THRESHOLD)
        current_level[i] = get_level_from_storage(basin, i, s)
        current_area[i] = basin.level_to_area[i](current_level[i])
    end
end

function formulate_storages!(
    current_storage::AbstractVector,
    du::ComponentVector,
    u::ComponentVector,
    p::Parameters,
    t::Number;
    add_initial_storage::Bool = true,
)::Nothing
    (; basin, flow_boundary, tprev, flow_to_storage) = p
    # Current storage: initial condition +
    # total inflows and outflows since the start
    # of the simulation
    if add_initial_storage
        current_storage .= basin.storage0
    else
        current_storage .= 0.0
    end
    mul!(current_storage, flow_to_storage, u, 1, 1)
    formulate_storage!(current_storage, basin, du)
    formulate_storage!(current_storage, tprev, t, flow_boundary)
    return nothing
end

"""
The storage contributions of the forcings that are not part of the state.
"""
function formulate_storage!(
    current_storage::AbstractVector,
    basin::Basin,
    du::ComponentVector,
)
    (; current_cumulative_precipitation, current_cumulative_drainage) =
        basin.current_properties

    current_cumulative_precipitation = current_cumulative_precipitation[parent(du)]
    current_cumulative_drainage = current_cumulative_drainage[parent(du)]
    current_storage .+= current_cumulative_precipitation
    current_storage .+= current_cumulative_drainage
end

"""
Formulate storage contributions of flow boundaries.
"""
function formulate_storage!(
    current_storage::AbstractVector,
    tprev::Number,
    t::Number,
    flow_boundary::FlowBoundary,
)
    for (flow_rate, outflow_edges, active, cumulative_flow) in zip(
        flow_boundary.flow_rate,
        flow_boundary.outflow_edges,
        flow_boundary.active,
        flow_boundary.cumulative_flow,
    )
        volume = cumulative_flow
        if active
            volume += integral(flow_rate, tprev, t)
        end
        for outflow_edge in outflow_edges
            outflow_id = outflow_edge.edge[2]
            if outflow_id.type == NodeType.Basin
                current_storage[outflow_id.idx] += volume
            end
        end
    end
end

"""
Smoothly let the evaporation flux go to 0 when at small water depths
Currently at less than 0.1 m.
"""
function update_vertical_flux!(basin::Basin, du::AbstractVector)::Nothing
    (; vertical_flux, current_properties) = basin
    (; current_level, current_area) = current_properties
    current_level = current_level[parent(du)]
    current_area = current_area[parent(du)]

    for id in basin.node_id
        level = current_level[id.idx]
        area = current_area[id.idx]

        bottom = basin_levels(basin, id.idx)[1]
        depth = max(level - bottom, 0.0)
        factor = reduction_factor(depth, 0.1)

        evaporation = area * factor * vertical_flux.potential_evaporation[id.idx]
        infiltration = factor * vertical_flux.infiltration[id.idx]

        du.evaporation[id.idx] = evaporation
        du.infiltration[id.idx] = infiltration
    end

    return nothing
end

function set_error!(pid_control::PidControl, p::Parameters, du::ComponentVector, t::Number)
    (; basin) = p
    (; listen_node_id, target, error) = pid_control
    error = error[parent(du)]
    current_level = basin.current_properties.current_level[parent(du)]

    for i in eachindex(listen_node_id)
        listened_node_id = listen_node_id[i]
        @assert listened_node_id.type == NodeType.Basin lazy"Listen node $listened_node_id is not a Basin."
        error[i] = target[i](t) - current_level[listened_node_id.idx]
    end
end

function formulate_pid_control!(
    u::ComponentVector,
    du::ComponentVector,
    pid_control::PidControl,
    p::Parameters,
    t::Number,
)::Nothing
    (; basin) = p
    (; node_id, active, target, listen_node_id, error) = pid_control
    (; current_area) = basin.current_properties

    current_area = current_area[parent(du)]
    error = error[parent(du)]
    all_nodes_active = p.all_nodes_active[]

    set_error!(pid_control, p, du, t)

    for (i, id) in enumerate(node_id)
        if !(active[i] || all_nodes_active)
            du.integral[i] = 0.0
            u.integral[i] = 0.0
            continue
        end

        du.integral[i] = error[i]

        listened_node_id = listen_node_id[i]

        flow_rate = zero(eltype(du))

        K_p = pid_control.proportional[i](t)
        K_i = pid_control.integral[i](t)
        K_d = pid_control.derivative[i](t)

        if !iszero(K_d)
            # dlevel/dstorage = 1/area
            # TODO: replace by DataInterpolations.derivative(storage_to_level, storage)
            area = current_area[listened_node_id.idx]
            D = 1.0 - K_d / area
        else
            D = 1.0
        end

        if !iszero(K_p)
            flow_rate += K_p * error[i] / D
        end

        if !iszero(K_i)
            flow_rate += K_i * u.integral[i] / D
        end

        if !iszero(K_d)
            dlevel_demand = derivative(target[i], t)
            dstorage_listened_basin_old = formulate_dstorage(du, p, t, listened_node_id)
            # The expression below is the solution to an implicit equation for
            # dstorage_listened_basin. This equation results from the fact that if the derivative
            # term in the PID controller is used, the controlled pump flow rate depends on itself.
            flow_rate += K_d * (dlevel_demand - dstorage_listened_basin_old / area) / D
        end

        # Set flow_rate
        set_value!(pid_control.target_ref[i], flow_rate, du)
    end
    return nothing
end

"""
Formulate the time derivative of the storage in a single Basin.
"""
function formulate_dstorage(du::ComponentVector, p::Parameters, t::Number, node_id::NodeID)
    (; basin) = p
    (; inflow_ids, outflow_ids, vertical_flux) = basin
    @assert node_id.type == NodeType.Basin
    dstorage = 0.0
    for inflow_id in inflow_ids[node_id.idx]
        dstorage += get_flow(du, p, t, (inflow_id, node_id))
    end
    for outflow_id in outflow_ids[node_id.idx]
        dstorage -= get_flow(du, p, t, (node_id, outflow_id))
    end

    fixed_area = basin_areas(basin, node_id.idx)[end]
    dstorage += fixed_area * vertical_flux.precipitation[node_id.idx]
    dstorage += vertical_flux.drainage[node_id.idx]
    dstorage -= du.evaporation[node_id.idx]
    dstorage -= du.infiltration[node_id.idx]

    dstorage
end

function formulate_flow!(
    du::ComponentVector,
    user_demand::UserDemand,
    p::Parameters,
    t::Number,
    current_low_storage_factor::Vector,
    current_level::Vector,
)::Nothing
    (; allocation) = p
    all_nodes_active = p.all_nodes_active[]
    for (id, inflow_edge, outflow_edge, active, allocated, return_factor, min_level) in zip(
        user_demand.node_id,
        user_demand.inflow_edge,
        user_demand.outflow_edge,
        user_demand.active,
        eachrow(user_demand.allocated),
        user_demand.return_factor,
        user_demand.min_level,
    )
        if !(active || all_nodes_active)
            continue
        end

        q = 0.0

        # Take as effectively allocated the minimum of what is allocated by allocation optimization
        # and the current demand.
        # If allocation is not optimized then allocated = Inf, so the result is always
        # effectively allocated = demand.
        for priority_idx in eachindex(allocation.priorities)
            alloc_prio = allocated[priority_idx]
            demand_prio = get_demand(user_demand, id, priority_idx, t)
            alloc = min(alloc_prio, demand_prio)
            q += alloc
        end

        # Smoothly let abstraction go to 0 as the source basin dries out
        inflow_id = inflow_edge.edge[1]
        factor_basin = get_low_storage_factor(current_low_storage_factor, inflow_id)
        q *= factor_basin

        # Smoothly let abstraction go to 0 as the source basin
        # level reaches its minimum level
        source_level = get_level(p, inflow_id, t, current_level)
        Δsource_level = source_level - min_level
        factor_level = reduction_factor(Δsource_level, USER_DEMAND_MIN_LEVEL_THRESHOLD)
        q *= factor_level
        du.user_demand_inflow[id.idx] = q
        du.user_demand_outflow[id.idx] = q * return_factor(t)
    end
    return nothing
end

function formulate_flow!(
    du::ComponentVector,
    linear_resistance::LinearResistance,
    p::Parameters,
    t::Number,
    current_low_storage_factor::Vector,
    current_level::Vector,
)::Nothing
    all_nodes_active = p.all_nodes_active[]
    (; node_id, active, resistance, max_flow_rate) = linear_resistance
    for id in node_id
        inflow_edge = linear_resistance.inflow_edge[id.idx]
        outflow_edge = linear_resistance.outflow_edge[id.idx]

        inflow_id = inflow_edge.edge[1]
        outflow_id = outflow_edge.edge[2]

        if (active[id.idx] || all_nodes_active)
            h_a = get_level(p, inflow_id, t, current_level)
            h_b = get_level(p, outflow_id, t, current_level)
            q_unlimited = (h_a - h_b) / resistance[id.idx]
            q = clamp(q_unlimited, -max_flow_rate[id.idx], max_flow_rate[id.idx])
            q *= low_storage_factor_resistance_node(
                current_low_storage_factor,
                q,
                inflow_id,
                outflow_id,
            )
            du.linear_resistance[id.idx] = q
        end
    end
    return nothing
end

function formulate_flow!(
    du::AbstractVector,
    tabulated_rating_curve::TabulatedRatingCurve,
    p::Parameters,
    t::Number,
    current_low_storage_factor::Vector,
    current_level::Vector,
)::Nothing
    all_nodes_active = p.all_nodes_active[]
    (; node_id, active, interpolations, current_interpolation_index) =
        tabulated_rating_curve

    for id in node_id
        inflow_edge = tabulated_rating_curve.inflow_edge[id.idx]
        outflow_edge = tabulated_rating_curve.outflow_edge[id.idx]
        inflow_id = inflow_edge.edge[1]
        outflow_id = outflow_edge.edge[2]
        max_downstream_level = tabulated_rating_curve.max_downstream_level[id.idx]

        h_a = get_level(p, inflow_id, t, current_level)
        h_b = get_level(p, outflow_id, t, current_level)
        Δh = h_a - h_b

        if active[id.idx] || all_nodes_active
            factor = get_low_storage_factor(current_low_storage_factor, inflow_id)
            interpolation_index = Int(current_interpolation_index[id.idx](t))
            qh = interpolations[interpolation_index]
            q = factor * qh(h_a)
            q *= reduction_factor(Δh, 0.02)
            q *= reduction_factor(max_downstream_level - h_b, 0.02)
        else
            q = 0.0
        end

        du.tabulated_rating_curve[id.idx] = q
    end
    return nothing
end

"""
Conservation of energy for two basins, a and b:

    h_a + v_a^2 / (2 * g) = h_b + v_b^2 / (2 * g) + S_f * L + C / 2 * g * (v_b^2 - v_a^2)

Where:

* h_a, h_b are the heads at basin a and b.
* v_a, v_b are the velocities at basin a and b.
* g is the gravitational constant.
* S_f is the friction slope.
* C is an expansion or extraction coefficient.

We assume velocity differences are negligible (v_a = v_b):

    h_a = h_b + S_f * L

The friction losses are approximated by the Gauckler-Manning formula:

    Q = A * (1 / n) * R_h^(2/3) * S_f^(1/2)

Where:

* Where A is the cross-sectional area.
* V is the cross-sectional average velocity.
* n is the Gauckler-Manning coefficient.
* R_h is the hydraulic radius.
* S_f is the friction slope.

The hydraulic radius is defined as:

    R_h = A / P

Where P is the wetted perimeter.

The average of the upstream and downstream water depth is used to compute cross-sectional area and
hydraulic radius. This ensures that a basin can receive water after it has gone
dry.
"""
function formulate_flow!(
    du::AbstractVector,
    manning_resistance::ManningResistance,
    p::Parameters,
    t::Number,
    current_low_storage_factor::Vector,
    current_level::Vector,
)::Nothing
    (;
        node_id,
        active,
        length,
        manning_n,
        profile_width,
        profile_slope,
        upstream_bottom,
        downstream_bottom,
    ) = manning_resistance
    all_nodes_active = p.all_nodes_active[]
    for id in node_id
        inflow_edge = manning_resistance.inflow_edge[id.idx]
        outflow_edge = manning_resistance.outflow_edge[id.idx]

        inflow_id = inflow_edge.edge[1]
        outflow_id = outflow_edge.edge[2]

        if !(active[id.idx] || all_nodes_active)
            continue
        end

        h_a = get_level(p, inflow_id, t, current_level)
        h_b = get_level(p, outflow_id, t, current_level)

        bottom_a = upstream_bottom[id.idx]
        bottom_b = downstream_bottom[id.idx]
        slope = profile_slope[id.idx]
        width = profile_width[id.idx]
        n = manning_n[id.idx]
        L = length[id.idx]

        # Average d, A, R
        d_a = h_a - bottom_a
        d_b = h_b - bottom_b
        d = 0.5 * (d_a + d_b)

        A_a = width * d + slope * d_a^2
        A_b = width * d + slope * d_b^2
        A = 0.5 * (A_a + A_b)

        slope_unit_length = sqrt(slope^2 + 1.0)
        P_a = width + 2.0 * d_a * slope_unit_length
        P_b = width + 2.0 * d_b * slope_unit_length
        R_h_a = A_a / P_a
        R_h_b = A_b / P_b
        R_h = 0.5 * (R_h_a + R_h_b)

        Δh = h_a - h_b

        q = A / n * ∛(R_h^2) * relaxed_root(Δh / L, 1e-3)
        q *= low_storage_factor_resistance_node(
            current_low_storage_factor,
            q,
            inflow_id,
            outflow_id,
        )
        du.manning_resistance[id.idx] = q
    end
    return nothing
end

function formulate_flow!(
    du::AbstractVector,
    pump::Pump,
    p::Parameters,
    t::Number,
    current_low_storage_factor::Vector,
    current_level::Vector,
    continuous_control_type_::ContinuousControlType.T,
)::Nothing
    all_nodes_active = p.all_nodes_active[]
    for (
        id,
        inflow_edge,
        outflow_edge,
        active,
        flow_rate,
        min_flow_rate,
        max_flow_rate,
        min_upstream_level,
        max_downstream_level,
        continuous_control_type,
    ) in zip(
        pump.node_id,
        pump.inflow_edge,
        pump.outflow_edge,
        pump.active,
        pump.flow_rate[parent(du)],
        pump.min_flow_rate,
        pump.max_flow_rate,
        pump.min_upstream_level,
        pump.max_downstream_level,
        pump.continuous_control_type,
    )
        if !(active || all_nodes_active) ||
           (continuous_control_type != continuous_control_type_)
            continue
        end

        inflow_id = inflow_edge.edge[1]
        outflow_id = outflow_edge.edge[2]
        src_level = get_level(p, inflow_id, t, current_level)
        dst_level = get_level(p, outflow_id, t, current_level)

        factor = get_low_storage_factor(current_low_storage_factor, inflow_id)
        q = flow_rate * factor

        q *= reduction_factor(src_level - min_upstream_level, 0.02)
        q *= reduction_factor(max_downstream_level - dst_level, 0.02)

        q = clamp(q, min_flow_rate, max_flow_rate)
        du.pump[id.idx] = q
    end
    return nothing
end

function formulate_flow!(
    du::AbstractVector,
    outlet::Outlet,
    p::Parameters,
    t::Number,
    current_low_storage_factor::Vector,
    current_level::Vector,
    continuous_control_type_::ContinuousControlType.T,
)::Nothing
    all_nodes_active = p.all_nodes_active[]
    for (
        id,
        inflow_edge,
        outflow_edge,
        active,
        flow_rate,
        min_flow_rate,
        max_flow_rate,
        continuous_control_type,
        min_upstream_level,
        max_downstream_level,
    ) in zip(
        outlet.node_id,
        outlet.inflow_edge,
        outlet.outflow_edge,
        outlet.active,
        outlet.flow_rate[parent(du)],
        outlet.min_flow_rate,
        outlet.max_flow_rate,
        outlet.continuous_control_type,
        outlet.min_upstream_level,
        outlet.max_downstream_level,
    )
        if !(active || all_nodes_active) ||
           (continuous_control_type != continuous_control_type_)
            continue
        end

        inflow_id = inflow_edge.edge[1]
        outflow_id = outflow_edge.edge[2]
        src_level = get_level(p, inflow_id, t, current_level)
        dst_level = get_level(p, outflow_id, t, current_level)

        q = flow_rate
        q *= get_low_storage_factor(current_low_storage_factor, inflow_id)

        # No flow of outlet if source level is lower than target level
        Δlevel = src_level - dst_level
        q *= reduction_factor(Δlevel, 0.02)
        q *= reduction_factor(src_level - min_upstream_level, 0.02)
        q *= reduction_factor(max_downstream_level - dst_level, 0.02)

        q = clamp(q, min_flow_rate, max_flow_rate)
        du.outlet[id.idx] = q
    end
    return nothing
end

function formulate_flows!(
    du::AbstractVector,
    p::Parameters,
    t::Number,
    current_storage::Vector,
    current_low_storage_factor::Vector,
    current_level::Vector;
    continuous_control_type::ContinuousControlType.T = ContinuousControlType.None,
)::Nothing
    (;
        linear_resistance,
        manning_resistance,
        tabulated_rating_curve,
        pump,
        outlet,
        user_demand,
    ) = p

    formulate_flow!(
        du,
        pump,
        p,
        t,
        current_low_storage_factor,
        current_level,
        continuous_control_type,
    )
    formulate_flow!(
        du,
        outlet,
        p,
        t,
        current_low_storage_factor,
        current_level,
        continuous_control_type,
    )

    if continuous_control_type == ContinuousControlType.None
        formulate_flow!(
            du,
            linear_resistance,
            p,
            t,
            current_low_storage_factor,
            current_level,
        )
        formulate_flow!(
            du,
            manning_resistance,
            p,
            t,
            current_low_storage_factor,
            current_level,
        )
        formulate_flow!(
            du,
            tabulated_rating_curve,
            p,
            t,
            current_low_storage_factor,
            current_level,
        )
        formulate_flow!(du, user_demand, p, t, current_low_storage_factor, current_level)
    end
end

"""
Clamp the cumulative flow states within the minimum and maximum
flow rates for the last time step if these flow rate bounds are known.
"""
function limit_flow!(
    u::ComponentVector,
    integrator::DEIntegrator,
    p::Parameters,
    t::Number,
)::Nothing
    (; uprev, dt) = integrator
    (;
        pump,
        outlet,
        linear_resistance,
        user_demand,
        tabulated_rating_curve,
        basin,
        allocation,
    ) = p

    # The current storage and level based on the proposed u are used to estimate the lowest
    # storage and level attained in the last time step to estimate whether there was an effect
    # of reduction factors
    du = get_du(integrator)
    set_current_basin_properties!(du, u, p, t)
    current_storage = basin.current_properties.current_storage[parent(u)]
    current_level = basin.current_properties.current_level[parent(u)]

    # TabulatedRatingCurve flow is in [0, ∞) and can be inactive
    for (id, active) in zip(tabulated_rating_curve.node_id, tabulated_rating_curve.active)
        limit_flow!(
            u.tabulated_rating_curve,
            uprev.tabulated_rating_curve,
            id,
            0.0,
            Inf,
            active,
            dt,
        )
    end

    # Pump flow is in [min_flow_rate, max_flow_rate] and can be inactive
    for (id, min_flow_rate, max_flow_rate, active) in
        zip(pump.node_id, pump.min_flow_rate, pump.max_flow_rate, pump.active)
        limit_flow!(u.pump, uprev.pump, id, min_flow_rate, max_flow_rate, active, dt)
    end

    # Outlet flow is in [min_flow_rate, max_flow_rate] and can be inactive
    for (id, min_flow_rate, max_flow_rate, active) in
        zip(outlet.node_id, outlet.min_flow_rate, outlet.max_flow_rate, outlet.active)
        limit_flow!(u.outlet, uprev.outlet, id, min_flow_rate, max_flow_rate, active, dt)
    end

    # LinearResistance flow is in [-max_flow_rate, max_flow_rate] and can be inactive
    for (id, max_flow_rate, active) in zip(
        linear_resistance.node_id,
        linear_resistance.max_flow_rate,
        linear_resistance.active,
    )
        limit_flow!(
            u.linear_resistance,
            uprev.linear_resistance,
            id,
            -max_flow_rate,
            max_flow_rate,
            active,
            dt,
        )
    end

    # UserDemand inflow bounds depend on multiple aspects of the simulation
    for (id, active, inflow_edge, demand_from_timeseries) in zip(
        user_demand.node_id,
        user_demand.active,
        user_demand.inflow_edge,
        user_demand.demand_from_timeseries,
    )
        min_flow_rate, max_flow_rate = if demand_from_timeseries
            # Bounding the flow rate if the demand comes from a time series is hard
            0, Inf
        else
            # The lower bound is estimated as the lowest inflow given the minimum values
            # of the reduction factors involved (with a margin)
            inflow_id = inflow_edge.edge[1]
            factor_basin_min =
                min_low_storage_factor(current_storage, basin.storage_prev, inflow_id)
            factor_level_min = min_low_user_demand_level_factor(
                current_level,
                basin.level_prev,
                user_demand.min_level,
                id,
                inflow_id,
            )
            allocated_total =
                is_active(allocation) ? sum(user_demand.allocated[id.idx, :]) :
                sum(user_demand.demand[id.idx, :])
            factor_basin_min * factor_level_min * allocated_total, allocated_total
        end
        limit_flow!(
            u.user_demand_inflow,
            uprev.user_demand_inflow,
            id,
            min_flow_rate,
            max_flow_rate,
            active,
            dt,
        )
    end

    # Evaporation is in [0, ∞) (stricter bounds would require also estimating the area)
    # Infiltration is in [f * infiltration, infiltration] where f is a rough estimate of the smallest low storage factor
    # reduction factor value that was attained over the last timestep
    for (id, infiltration) in zip(basin.node_id, basin.vertical_flux.infiltration)
        factor_min = min_low_storage_factor(current_storage, basin.storage_prev, id)
        limit_flow!(u.evaporation, uprev.evaporation, id, 0.0, Inf, true, dt)
        limit_flow!(
            u.infiltration,
            uprev.infiltration,
            id,
            factor_min * infiltration,
            infiltration,
            true,
            dt,
        )
    end

    return nothing
end

function limit_flow!(
    u_component,
    uprev_component,
    id::NodeID,
    min_flow_rate::Number,
    max_flow_rate::Number,
    active::Bool,
    dt::Number,
)::Nothing
    u_prev = uprev_component[id.idx]
    if active
        u_component[id.idx] = clamp(
            u_component[id.idx],
            u_prev + min_flow_rate * dt,
            u_prev + max_flow_rate * dt,
        )
    else
        u_component[id.idx] = uprev_component[id.idx]
    end
    return nothing
end
