"""
The right hand side function of the system of ODEs set up by Ribasim.
"""
function water_balance!(
    du::ComponentVector,
    u::ComponentVector,
    p::Parameters,
    t::Number,
)::Nothing
    (; graph, basin, pid_control) = p

    storage = u.storage
    integral = u.integral

    du .= 0.0
    get_tmp(graph[].flow, storage) .= 0.0

    # Ensures current_* vectors are current
    set_current_basin_properties!(basin, storage)

    # Basin forcings
    formulate_basins!(du, basin, storage)

    # First formulate intermediate flows
    formulate_flows!(p, storage, t)

    # Now formulate du
    formulate_du!(du, graph, storage)

    # PID control (changes the du of PID controlled basins)
    continuous_control!(u, du, pid_control, p, integral, t)

    return nothing
end

function set_current_basin_properties!(basin::Basin, storage::AbstractVector)::Nothing
    (; current_level, current_area) = basin
    current_level = get_tmp(current_level, storage)
    current_area = get_tmp(current_area, storage)

    for i in eachindex(storage)
        s = storage[i]
        area, level = get_area_and_level(basin, i, s)

        current_area[i] = area
        current_level[i] = level
    end
end

"""
Smoothly let the evaporation flux go to 0 when at small water depths
Currently at less than 0.1 m.
"""
function update_vertical_flux!(basin::Basin, storage::AbstractVector)::Nothing
    (; current_level, current_area, vertical_flux_from_input, vertical_flux) = basin
    current_level = get_tmp(current_level, storage)
    current_area = get_tmp(current_area, storage)
    vertical_flux = get_tmp(vertical_flux, storage)

    for id in basin.node_id
        level = current_level[id.idx]
        area = current_area[id.idx]

        bottom = basin_levels(basin, id.idx)[1]
        fixed_area = basin_areas(basin, id.idx)[end]
        depth = max(level - bottom, 0.0)
        factor = reduction_factor(depth, 0.1)

        precipitation = fixed_area * vertical_flux_from_input.precipitation[id.idx]
        evaporation = area * factor * vertical_flux_from_input.potential_evaporation[id.idx]
        drainage = vertical_flux_from_input.drainage[id.idx]
        infiltration = factor * vertical_flux_from_input.infiltration[id.idx]

        vertical_flux.precipitation[id.idx] = precipitation
        vertical_flux.evaporation[id.idx] = evaporation
        vertical_flux.drainage[id.idx] = drainage
        vertical_flux.infiltration[id.idx] = infiltration
    end

    return nothing
end

function formulate_basins!(
    du::AbstractVector,
    basin::Basin,
    storage::AbstractVector,
)::Nothing
    update_vertical_flux!(basin, storage)
    for id in basin.node_id
        # add all vertical fluxes that enter the Basin
        du.storage[id.idx] += get_influx(basin, id.idx)
    end
    return nothing
end

function set_error!(pid_control::PidControl, p::Parameters, u::ComponentVector, t::Number)
    (; basin) = p
    (; listen_node_id, target, error) = pid_control
    error = get_tmp(error, u)
    current_level = get_tmp(basin.current_level, u)

    for i in eachindex(listen_node_id)
        listened_node_id = listen_node_id[i]
        @assert listened_node_id.type == NodeType.Basin lazy"Listen node $listened_node_id is not a Basin."
        error[i] = target[i](t) - current_level[listened_node_id.idx]
    end
end

function continuous_control!(
    u::ComponentVector,
    du::ComponentVector,
    pid_control::PidControl,
    p::Parameters,
    integral_value::SubArray,
    t::Number,
)::Nothing
    (; graph, pump, outlet, basin, fractional_flow) = p
    min_flow_rate_pump = pump.min_flow_rate
    max_flow_rate_pump = pump.max_flow_rate
    min_flow_rate_outlet = outlet.min_flow_rate
    max_flow_rate_outlet = outlet.max_flow_rate
    (; node_id, active, target, listen_node_id, error) = pid_control
    (; current_area) = basin

    current_area = get_tmp(current_area, u)
    storage = u.storage
    error = get_tmp(error, u)

    set_error!(pid_control, p, u, t)

    for id in node_id
        if !active[id.idx]
            du.integral[id.idx] = 0.0
            u.integral[id.idx] = 0.0
            continue
        end

        du.integral[id.idx] = error[id.idx]

        listened_node_id = listen_node_id[id.idx]

        controlled_node_id = only(outneighbor_labels_type(graph, id, EdgeType.control))
        controls_pump = (controlled_node_id in pump.node_id)

        if !controls_pump
            src_id = inflow_id(graph, controlled_node_id)
            dst_id = outflow_id(graph, controlled_node_id)

            inflow_edge = graph[src_id, controlled_node_id]
            outflow_edge = graph[controlled_node_id, dst_id]

            has_src_level, src_level = get_level(p, src_id, t; storage)
            has_dst_level, dst_level = get_level(p, dst_id, t; storage)

            factor_outlet = 1.0

            # No flow out of outlet if source level is lower than reference level
            if has_src_level && has_dst_level
                Δlevel = src_level - dst_level
                factor_outlet *= reduction_factor(Δlevel, 0.1)
            end

            # No flow out of outlet if source level is lower than minimum crest level
            if has_src_level
                factor_outlet *= reduction_factor(
                    src_level - outlet.min_crest_level[controlled_node_id.idx],
                    0.1,
                )
            end
        else
            factor_outlet = 1.0
        end

        id_inflow = inflow_id(graph, controlled_node_id)
        factor_basin = low_storage_factor(storage, id_inflow, 10.0)

        factor = factor_basin * factor_outlet
        flow_rate = 0.0

        K_p = pid_control.proportional[id.idx](t)
        K_i = pid_control.integral[id.idx](t)
        K_d = pid_control.derivative[id.idx](t)

        if !iszero(K_d)
            # dlevel/dstorage = 1/area
            area = current_area[listened_node_id.idx]
            D = 1.0 - K_d * factor / area
        else
            D = 1.0
        end

        if !iszero(K_p)
            flow_rate += factor * K_p * error[id.idx] / D
        end

        if !iszero(K_i)
            flow_rate += factor * K_i * integral_value[id.idx] / D
        end

        if !iszero(K_d)
            dlevel_demand = derivative(target[id.idx], t)
            du_listened_basin_old = du.storage[listened_node_id.idx]
            # The expression below is the solution to an implicit equation for
            # du_listened_basin. This equation results from the fact that if the derivative
            # term in the PID controller is used, the controlled pump flow rate depends on itself.
            flow_rate += K_d * (dlevel_demand - du_listened_basin_old / area) / D
        end

        # Clamp values outside pump flow rate bounds
        if controls_pump
            min_flow_rate = min_flow_rate_pump
            max_flow_rate = max_flow_rate_pump
        else
            min_flow_rate = min_flow_rate_outlet
            max_flow_rate = max_flow_rate_outlet
        end

        flow_rate = clamp(
            flow_rate,
            min_flow_rate[controlled_node_id.idx],
            max_flow_rate[controlled_node_id.idx],
        )

        # Set flow for connected edges
        src_id = inflow_id(graph, controlled_node_id)
        dst_id = outflow_id(graph, controlled_node_id)

        set_flow!(graph, src_id, controlled_node_id, flow_rate)
        set_flow!(graph, controlled_node_id, dst_id, flow_rate)

        # Below du.storage is updated. This is normally only done
        # in formulate!(du, connectivity, basin), but in this function
        # flows are set so du has to be updated too.
        if dst_id.type == NodeType.Basin
            du.storage[dst_id.idx] += flow_rate
        end

        if src_id.type == NodeType.Basin
            du.storage[src_id.idx] -= flow_rate
        end

        # When the controlled pump flows out into fractional flow nodes
        if controls_pump
            for id in outflow_ids(graph, controlled_node_id)
                if id in fractional_flow.node_id
                    after_ff_id = fractional_flow.outflow_edge[id.idx].edge[2]
                    flow_rate_fraction = fractional_flow.fraction[id.idx] * flow_rate
                    flow[id, after_ff_id] = flow_rate_fraction

                    if after_ff_id.type == NodeType.Basin
                        du.storage[after_ff_id.idx] += flow_rate_fraction
                    end
                end
            end
        end
    end
    return nothing
end

function formulate_flow!(
    user_demand::UserDemand,
    p::Parameters,
    storage::AbstractVector,
    t::Number,
)::Nothing
    (; graph, allocation) = p

    for (
        node_id,
        inflow_edge,
        outflow_edge,
        active,
        demand_itp,
        demand,
        allocated,
        return_factor,
        min_level,
        demand_from_timeseries,
    ) in zip(
        user_demand.node_id,
        user_demand.inflow_edge,
        user_demand.outflow_edge,
        user_demand.active,
        user_demand.demand_itp,
        # TODO permute these so the nodes are the last dimension, for performance
        eachrow(user_demand.demand),
        eachrow(user_demand.allocated),
        user_demand.return_factor,
        user_demand.min_level,
        user_demand.demand_from_timeseries,
    )
        if !active
            continue
        end

        q = 0.0

        # Take as effectively allocated the minimum of what is allocated by allocation optimization
        # and the current demand.
        # If allocation is not optimized then allocated = Inf, so the result is always
        # effectively allocated = demand.
        for priority_idx in eachindex(allocation.priorities)
            alloc_prio = allocated[priority_idx]
            demand_prio = if demand_from_timeseries
                demand_itp[priority_idx](t)
            else
                demand[priority_idx]
            end
            alloc = min(alloc_prio, demand_prio)
            q += alloc
        end

        # Smoothly let abstraction go to 0 as the source basin dries out
        inflow_id = inflow_edge.edge[1]
        factor_basin = low_storage_factor(storage, inflow_id, 10.0)
        q *= factor_basin

        # Smoothly let abstraction go to 0 as the source basin
        # level reaches its minimum level
        _, source_level = get_level(p, inflow_id, t; storage)
        Δsource_level = source_level - min_level
        factor_level = reduction_factor(Δsource_level, 0.1)
        q *= factor_level

        set_flow!(graph, inflow_edge, q)

        # Return flow is immediate
        set_flow!(graph, outflow_edge, q * return_factor)
    end
    return nothing
end

"""
Directed graph: outflow is positive!
"""
function formulate_flow!(
    linear_resistance::LinearResistance,
    p::Parameters,
    storage::AbstractVector,
    t::Number,
)::Nothing
    (; graph) = p
    (; node_id, active, resistance, max_flow_rate) = linear_resistance
    for id in node_id
        inflow_edge = linear_resistance.inflow_edge[id.idx]
        outflow_edge = linear_resistance.outflow_edge[id.idx]

        inflow_id = inflow_edge.edge[1]
        outflow_id = outflow_edge.edge[2]

        if active[id.idx]
            _, h_a = get_level(p, inflow_id, t; storage)
            _, h_b = get_level(p, outflow_id, t; storage)
            q_unlimited = (h_a - h_b) / resistance[id.idx]
            q = clamp(q_unlimited, -max_flow_rate[id.idx], max_flow_rate[id.idx])

            # add reduction_factor on highest level
            if q > 0
                q *= low_storage_factor(storage, inflow_id, 10.0)
            else
                q *= low_storage_factor(storage, outflow_id, 10.0)
            end

            set_flow!(graph, inflow_edge, q)
            set_flow!(graph, outflow_edge, q)
        end
    end
    return nothing
end

"""
Directed graph: outflow is positive!
"""
function formulate_flow!(
    tabulated_rating_curve::TabulatedRatingCurve,
    p::Parameters,
    storage::AbstractVector,
    t::Number,
)::Nothing
    (; graph) = p
    (; node_id, active, table, inflow_edge, outflow_edges) = tabulated_rating_curve

    for id in node_id
        upstream_edge = inflow_edge[id.idx]
        downstream_edges = outflow_edges[id.idx]
        upstream_basin_id = upstream_edge.edge[1]

        if active[id.idx]
            factor = low_storage_factor(storage, upstream_basin_id, 10.0)
            q = factor * table[id.idx](get_level(p, upstream_basin_id, t; storage)[2])
        else
            q = 0.0
        end

        set_flow!(graph, upstream_edge, q)
        for downstream_edge in downstream_edges
            set_flow!(graph, downstream_edge, q)
        end
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
    manning_resistance::ManningResistance,
    p::Parameters,
    storage::AbstractVector{T},
    t::Number,
)::Nothing where {T}
    (; graph) = p
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
    for id in node_id
        inflow_edge = manning_resistance.inflow_edge[id.idx]
        outflow_edge = manning_resistance.outflow_edge[id.idx]

        inflow_id = inflow_edge.edge[1]
        outflow_id = outflow_edge.edge[2]

        if !active[id.idx]
            continue
        end

        _, h_a = get_level(p, inflow_id, t; storage)
        _, h_b = get_level(p, outflow_id, t; storage)
        bottom_a = upstream_bottom[id.idx]
        bottom_b = downstream_bottom[id.idx]
        slope = profile_slope[id.idx]
        width = profile_width[id.idx]
        n = manning_n[id.idx]
        L = length[id.idx]

        Δh = h_a - h_b
        q_sign = sign(Δh)

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
        R_h::T = 0.5 * (R_h_a + R_h_b)
        k = 1000.0
        # This epsilon makes sure the AD derivative at Δh = 0 does not give NaN
        eps = 1e-200

        q = q_sign * A / n * ∛(R_h^2) * sqrt(Δh / L * 2 / π * atan(k * Δh) + eps)

        set_flow!(graph, inflow_edge, q)
        set_flow!(graph, outflow_edge, q)
    end
    return nothing
end

function formulate_flow!(
    fractional_flow::FractionalFlow,
    p::Parameters,
    storage::AbstractVector,
    t::Number,
)::Nothing
    (; graph) = p

    for (node_id, inflow_edge, outflow_edge, fraction) in zip(
        fractional_flow.node_id,
        fractional_flow.inflow_edge,
        fractional_flow.outflow_edge,
        fractional_flow.fraction,
    )
        # overwrite the inflow such that flow is conserved over the FractionalFlow
        outflow = get_flow(graph, inflow_edge, storage) * fraction
        set_flow!(graph, inflow_edge, outflow)
        set_flow!(graph, outflow_edge, outflow)
    end
    return nothing
end

function formulate_flow!(
    flow_boundary::FlowBoundary,
    p::Parameters,
    storage::AbstractVector,
    t::Number,
)::Nothing
    (; graph) = p
    (; node_id, active, flow_rate, outflow_edges) = flow_boundary

    for id in node_id
        if active[id.idx]
            rate = flow_rate[id.idx](t)
            for outflow_edge in outflow_edges[id.idx]

                # Adding water is always possible
                set_flow!(graph, outflow_edge, rate)
            end
        end
    end
end

function formulate_flow!(
    pump::Pump,
    p::Parameters,
    storage::AbstractVector,
    t::Number,
)::Nothing
    (; graph, basin) = p

    for (node_id, inflow_edge, outflow_edges, active, flow_rate, is_pid_controlled) in zip(
        pump.node_id,
        pump.inflow_edge,
        pump.outflow_edges,
        pump.active,
        get_tmp(pump.flow_rate, storage),
        pump.is_pid_controlled,
    )
        if !active || is_pid_controlled
            continue
        end

        inflow_id = inflow_edge.edge[1]
        factor = low_storage_factor(storage, inflow_id, 10.0)
        q = flow_rate * factor

        set_flow!(graph, inflow_edge, q)

        for outflow_edge in outflow_edges
            set_flow!(graph, outflow_edge, q)
        end
    end
    return nothing
end

function formulate_flow!(
    outlet::Outlet,
    p::Parameters,
    storage::AbstractVector,
    t::Number,
)::Nothing
    (; graph) = p

    for (
        node_id,
        inflow_edge,
        outflow_edges,
        active,
        flow_rate,
        is_pid_controlled,
        min_crest_level,
    ) in zip(
        outlet.node_id,
        outlet.inflow_edge,
        outlet.outflow_edges,
        outlet.active,
        get_tmp(outlet.flow_rate, storage),
        outlet.is_pid_controlled,
        outlet.min_crest_level,
    )
        if !active || is_pid_controlled
            continue
        end

        inflow_id = inflow_edge.edge[1]
        q = flow_rate
        q *= low_storage_factor(storage, inflow_id, 10.0)

        # No flow of outlet if source level is lower than target level
        # TODO support multiple outflows to FractionalFlow, or refactor FractionalFlow
        outflow_edge = only(outflow_edges)
        outflow_id = outflow_edge.edge[2]
        _, src_level = get_level(p, inflow_id, t; storage)
        _, dst_level = get_level(p, outflow_id, t; storage)

        if src_level !== nothing && dst_level !== nothing
            Δlevel = src_level - dst_level
            q *= reduction_factor(Δlevel, 0.1)
        end

        # No flow out outlet if source level is lower than minimum crest level
        if src_level !== nothing
            q *= reduction_factor(src_level - min_crest_level, 0.1)
        end

        set_flow!(graph, inflow_edge, q)

        for outflow_edge in outflow_edges
            set_flow!(graph, outflow_edge, q)
        end
    end
    return nothing
end

function formulate_du!(
    du::ComponentVector,
    graph::MetaGraph,
    storage::AbstractVector,
)::Nothing
    # loop over basins
    # subtract all outgoing flows
    # add all ingoing flows
    for edge_metadata in values(graph[].flow_edges)
        from_id, to_id = edge_metadata.edge

        if from_id.type == NodeType.Basin
            q = get_flow(graph, edge_metadata, storage)
            du[from_id.idx] -= q
        elseif to_id.type == NodeType.Basin
            q = get_flow(graph, edge_metadata, storage)
            du[to_id.idx] += q
        end
    end
    return nothing
end

function formulate_flows!(p::Parameters, storage::AbstractVector, t::Number)::Nothing
    (;
        linear_resistance,
        manning_resistance,
        tabulated_rating_curve,
        flow_boundary,
        pump,
        outlet,
        user_demand,
        fractional_flow,
    ) = p

    formulate_flow!(linear_resistance, p, storage, t)
    formulate_flow!(manning_resistance, p, storage, t)
    formulate_flow!(tabulated_rating_curve, p, storage, t)
    formulate_flow!(flow_boundary, p, storage, t)
    formulate_flow!(pump, p, storage, t)
    formulate_flow!(outlet, p, storage, t)
    formulate_flow!(user_demand, p, storage, t)

    # do this last since they rely on formulated input flows
    formulate_flow!(fractional_flow, p, storage, t)
end
