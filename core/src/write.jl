"""
    write_results(model::Model)::Model

Write all results to the Arrow files as specified in the model configuration.
"""
function write_results(model::Model)::Model
    (; config) = model
    (; results, experimental) = model.config
    compress = get_compressor(results)
    remove_empty_table = model.integrator.t != 0

    # state
    table = basin_state_table(model)
    path = results_path(config, RESULTS_FILENAME.basin_state)
    write_arrow(path, table, compress; remove_empty_table)

    # basin
    table = basin_table(model)
    path = results_path(config, RESULTS_FILENAME.basin)
    write_arrow(path, table, compress; remove_empty_table)

    # flow
    table = flow_table(model)
    path = results_path(config, RESULTS_FILENAME.flow)
    write_arrow(path, table, compress; remove_empty_table)

    # concentrations
    if experimental.concentration
        table = concentration_table(model)
        path = results_path(config, RESULTS_FILENAME.concentration)
        write_arrow(path, table, compress; remove_empty_table)
    end

    # discrete control
    table = discrete_control_table(model)
    path = results_path(config, RESULTS_FILENAME.control)
    write_arrow(path, table, compress; remove_empty_table)

    # allocation
    table = allocation_table(model)
    path = results_path(config, RESULTS_FILENAME.allocation)
    write_arrow(path, table, compress; remove_empty_table)

    # allocation flow
    table = allocation_flow_table(model)
    path = results_path(config, RESULTS_FILENAME.allocation_flow)
    write_arrow(path, table, compress; remove_empty_table)

    # exported levels
    table = subgrid_level_table(model)
    path = results_path(config, RESULTS_FILENAME.subgrid_level)
    write_arrow(path, table, compress; remove_empty_table)

    # solver stats
    table = solver_stats_table(model)
    path = results_path(config, RESULTS_FILENAME.solver_stats)
    write_arrow(path, table, compress; remove_empty_table)

    @debug "Wrote results."
    return model
end

const RESULTS_FILENAME = (
    basin_state = "basin_state.arrow",
    basin = "basin.arrow",
    flow = "flow.arrow",
    concentration = "concentration.arrow",
    control = "control.arrow",
    allocation = "allocation.arrow",
    allocation_flow = "allocation_flow.arrow",
    subgrid_level = "subgrid_level.arrow",
    solver_stats = "solver_stats.arrow",
)

"Get the storage and level of all basins as matrices of nbasin × ntime"
function get_storages_and_levels(
    model::Model,
)::@NamedTuple{
    time::Vector{DateTime},
    node_id::Vector{NodeID},
    storage::Matrix{Float64},
    level::Matrix{Float64},
}
    (; config, integrator, saved) = model
    (; p) = integrator

    node_id = p.basin.node_id::Vector{NodeID}
    tsteps = datetime_since.(tsaves(model), config.starttime)

    storage = zeros(length(node_id), length(tsteps))
    level = zero(storage)
    for (i, cvec) in enumerate(saved.basin_state.saveval)
        storage[:, i] .= cvec.storage
        level[:, i] .= cvec.level
    end

    return (; time = tsteps, node_id, storage, level)
end

"Create the basin state table from the saved data"
function basin_state_table(
    model::Model,
)::@NamedTuple{node_id::Vector{Int32}, level::Vector{Float64}}
    du = get_du(model.integrator)
    (; u, p, t) = model.integrator

    # ensure the levels are up-to-date
    set_current_basin_properties!(du, u, p, t)

    return (;
        node_id = Int32.(p.basin.node_id),
        level = p.basin.current_properties.current_level[Float64[]],
    )
end

"Create the basin result table from the saved data"
function basin_table(
    model::Model,
)::@NamedTuple{
    time::Vector{DateTime},
    node_id::Vector{Int32},
    level::Vector{Float64},
    storage::Vector{Float64},
    inflow_rate::Vector{Float64},
    outflow_rate::Vector{Float64},
    storage_rate::Vector{Float64},
    precipitation::Vector{Float64},
    evaporation::Vector{Float64},
    drainage::Vector{Float64},
    infiltration::Vector{Float64},
    balance_error::Vector{Float64},
    relative_error::Vector{Float64},
}
    (; saved) = model
    # The last timestep is not included; there is no period over which to compute flows.
    data = get_storages_and_levels(model)
    storage = vec(data.storage[:, begin:(end - 1)])
    level = vec(data.level[:, begin:(end - 1)])

    nbasin = length(data.node_id)
    ntsteps = length(data.time) - 1
    nrows = nbasin * ntsteps

    inflow_rate = FlatVector(saved.flow.saveval, :inflow)
    outflow_rate = FlatVector(saved.flow.saveval, :outflow)
    drainage = FlatVector(saved.flow.saveval, :drainage)
    infiltration = zeros(nrows)
    evaporation = zeros(nrows)
    precipitation = FlatVector(saved.flow.saveval, :precipitation)
    storage_rate = FlatVector(saved.flow.saveval, :storage_rate)
    balance_error = FlatVector(saved.flow.saveval, :balance_error)
    relative_error = FlatVector(saved.flow.saveval, :relative_error)

    idx_row = 0
    for cvec in saved.flow.saveval
        for (evaporation_, infiltration_) in
            zip(cvec.flow.evaporation, cvec.flow.infiltration)
            idx_row += 1
            evaporation[idx_row] = evaporation_
            infiltration[idx_row] = infiltration_
        end
    end

    time = repeat(data.time[begin:(end - 1)]; inner = nbasin)
    node_id = repeat(Int32.(data.node_id); outer = ntsteps)

    return (;
        time,
        node_id,
        level,
        storage,
        inflow_rate,
        outflow_rate,
        storage_rate,
        precipitation,
        evaporation,
        drainage,
        infiltration,
        balance_error,
        relative_error,
    )
end

function solver_stats_table(
    model::Model,
)::@NamedTuple{
    time::Vector{DateTime},
    rhs_calls::Vector{Int},
    linear_solves::Vector{Int},
    accepted_timesteps::Vector{Int},
    rejected_timesteps::Vector{Int},
}
    solver_stats = StructVector(model.saved.solver_stats.saveval)
    (;
        time = datetime_since.(
            solver_stats.time[1:(end - 1)],
            model.integrator.p.starttime,
        ),
        rhs_calls = diff(solver_stats.rhs_calls),
        linear_solves = diff(solver_stats.linear_solves),
        accepted_timesteps = diff(solver_stats.accepted_timesteps),
        rejected_timesteps = diff(solver_stats.rejected_timesteps),
    )
end

"Create a flow result table from the saved data"
function flow_table(
    model::Model,
)::@NamedTuple{
    time::Vector{DateTime},
    edge_id::Vector{Union{Int32, Missing}},
    from_node_id::Vector{Int32},
    to_node_id::Vector{Int32},
    flow_rate::Vector{Float64},
}
    (; config, saved, integrator) = model
    (; t, saveval) = saved.flow
    (; p) = integrator
    (; graph) = p
    (; flow_edges) = graph[]

    from_node_id = Int32[]
    to_node_id = Int32[]
    unique_edge_ids_flow = Union{Int32, Missing}[]

    flow_edge_ids = [flow_edge.edge for flow_edge in flow_edges]

    for (from_id, to_id) in flow_edge_ids
        push!(from_node_id, from_id.value)
        push!(to_node_id, to_id.value)
        push!(unique_edge_ids_flow, graph[from_id, to_id].id)
    end

    nflow = length(unique_edge_ids_flow)
    ntsteps = length(t)

    flow_rate = zeros(nflow * ntsteps)

    for (i, edge) in enumerate(flow_edge_ids)
        for (j, cvec) in enumerate(saveval)
            (; flow, flow_boundary) = cvec
            flow_rate[i + (j - 1) * nflow] =
                get_flow(flow, p, 0.0, edge; boundary_flow = flow_boundary)
        end
    end

    # the timestamp should represent the start of the period, not the end
    t_starts = circshift(t, 1)
    if !isempty(t)
        t_starts[1] = 0.0
    end
    time = repeat(datetime_since.(t_starts, config.starttime); inner = nflow)
    edge_id = repeat(unique_edge_ids_flow; outer = ntsteps)
    from_node_id = repeat(from_node_id; outer = ntsteps)
    to_node_id = repeat(to_node_id; outer = ntsteps)

    return (; time, edge_id, from_node_id, to_node_id, flow_rate)
end

"Create a concentration result table from the saved data"
function concentration_table(
    model::Model,
)::@NamedTuple{
    time::Vector{DateTime},
    node_id::Vector{Int32},
    substance::Vector{String},
    concentration::Vector{Float64},
}
    (; saved, integrator) = model
    (; p) = integrator
    (; basin) = p

    # The last timestep is not included; there is no period over which to compute flows.
    data = get_storages_and_levels(model)

    ntsteps = length(data.time) - 1
    nbasin = length(data.node_id)
    nsubstance = length(basin.concentration_data.substances)

    substances = String.(basin.concentration_data.substances)
    concentration = FlatVector(saved.flow.saveval, :concentration)

    time = repeat(data.time[begin:(end - 1)]; inner = nbasin * nsubstance)
    substance = repeat(substances; inner = nbasin, outer = ntsteps)
    node_id = repeat(Int32.(data.node_id); outer = ntsteps * nsubstance)

    return (; time, node_id, substance, concentration)
end

"Create a discrete control result table from the saved data"
function discrete_control_table(
    model::Model,
)::@NamedTuple{
    time::Vector{DateTime},
    control_node_id::Vector{Int32},
    truth_state::Vector{String},
    control_state::Vector{String},
}
    (; config) = model
    (; record) = model.integrator.p.discrete_control

    time = datetime_since.(record.time, config.starttime)
    return (; time, record.control_node_id, record.truth_state, record.control_state)
end

"Create an allocation result table for the saved data"
function allocation_table(
    model::Model,
)::@NamedTuple{
    time::Vector{DateTime},
    subnetwork_id::Vector{Int32},
    node_type::Vector{String},
    node_id::Vector{Int32},
    demand_priority::Vector{Int32},
    demand::Vector{Float64},
    allocated::Vector{Float64},
    realized::Vector{Float64},
}
    (; config) = model
    (; record_demand) = model.integrator.p.allocation

    time = datetime_since.(record_demand.time, config.starttime)
    return (;
        time,
        record_demand.subnetwork_id,
        record_demand.node_type,
        record_demand.node_id,
        record_demand.demand_priority,
        record_demand.demand,
        record_demand.allocated,
        record_demand.realized,
    )
end

function allocation_flow_table(
    model::Model,
)::@NamedTuple{
    time::Vector{DateTime},
    edge_id::Vector{Int32},
    from_node_type::Vector{String},
    from_node_id::Vector{Int32},
    to_node_type::Vector{String},
    to_node_id::Vector{Int32},
    subnetwork_id::Vector{Int32},
    demand_priority::Vector{Int32},
    flow_rate::Vector{Float64},
    optimization_type::Vector{String},
}
    (; config) = model
    (; record_flow) = model.integrator.p.allocation

    time = datetime_since.(record_flow.time, config.starttime)

    return (;
        time,
        record_flow.edge_id,
        record_flow.from_node_type,
        record_flow.from_node_id,
        record_flow.to_node_type,
        record_flow.to_node_id,
        record_flow.subnetwork_id,
        record_flow.demand_priority,
        record_flow.flow_rate,
        record_flow.optimization_type,
    )
end

function subgrid_level_table(
    model::Model,
)::@NamedTuple{
    time::Vector{DateTime},
    subgrid_id::Vector{Int32},
    subgrid_level::Vector{Float64},
}
    (; config, saved, integrator) = model
    (; t, saveval) = saved.subgrid_level
    subgrid = integrator.p.subgrid

    nelem = length(subgrid.level)
    ntsteps = length(t)

    time = repeat(datetime_since.(t, config.starttime); inner = nelem)
    subgrid_id = repeat(
        sort(vcat(subgrid.subgrid_id_static, subgrid.subgrid_id_time));
        outer = ntsteps,
    )
    subgrid_level = FlatVector(saveval)
    return (; time, subgrid_id, subgrid_level)
end

"Write a result table to disk as an Arrow file"
function write_arrow(
    path::AbstractString,
    table::NamedTuple,
    compress::Union{ZstdCompressor, Nothing};
    remove_empty_table::Bool = false,
)::Nothing
    # At the start of the simulation, write an empty table to ensure we have permissions
    # and fail early.
    # At the end of the simulation, write all non-empty tables, and remove existing empty ones.
    if haskey(table, :time) && isempty(table.time) && remove_empty_table
        try
            rm(path; force = true)
        catch
            @warn "Failed to remove results, file may be locked." path
        end
        return nothing
    end
    if haskey(table, :time)
        # ensure DateTime is encoded in a compatible manner
        # https://github.com/apache/arrow-julia/issues/303
        table = merge(table, (; time = convert.(Arrow.DATETIME, table.time)))
    end
    metadata = ["ribasim_version" => string(pkgversion(Ribasim))]
    mkpath(dirname(path))
    try
        Arrow.write(path, table; compress, metadata)
    catch e
        @error "Failed to write results, file may be locked." path
        rethrow(e)
    end
    return nothing
end

"Get the compressor based on the Results section"
function get_compressor(results::Results)::Union{ZstdCompressor, Nothing}
    compressor = results.compression
    level = results.compression_level
    if compressor
        c = ZstdCompressor(; level)
        TranscodingStreams.initialize(c)
    else
        c = nothing
    end
    return c
end
