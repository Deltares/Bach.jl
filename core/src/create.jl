function Connectivity(db::DB)::Connectivity
    graph, edge_ids = create_graph(db)

    flow = adjacency_matrix(graph, Float64)
    nonzeros(flow) .= 0.0

    basin_id = get_ids(db, "Basin")
    u_index = Dict(id => i for (i, id) in enumerate(basin_id))

    return Connectivity(graph, flow, u_index, edge_ids)
end

function LinearLevelConnection(db::DB, config::Config)::LinearLevelConnection
    data = load_data(db, config, LinearLevelConnectionStaticV1)
    isnothing(data) && return LinearLevelConnection()
    tbl = columntable(data)
    return LinearLevelConnection(tbl.node_id, tbl.conductance)
end

function TabulatedRatingCurve(db::DB, config::Config)::TabulatedRatingCurve
    static = load_structvector(db, config, TabulatedRatingCurveStaticV1)
    time = load_structvector(db, config, TabulatedRatingCurveTimeV1)

    static_node_ids = Set(static.node_id)
    time_node_ids = Set(time.node_id)
    msg = "TabulatedRatingCurve cannot be in both static and time tables"
    @assert isdisjoint(static_node_ids, time_node_ids) msg
    node_ids = get_ids(db, "TabulatedRatingCurve")
    msg = "TabulatedRatingCurve node IDs don't match"
    @assert issetequal(node_ids, union(static_node_ids, time_node_ids))

    interpolations = Interpolation[]
    for node_id in node_ids
        interpolation = if node_id in static_node_ids
            qh_interpolation(node_id, static)
        elseif node_id in time_node_ids
            # get the timestamp that applies to the model starttime
            idx_starttime = searchsortedlast(time.time, config.starttime)
            pre_table = view(time, 1:idx_starttime)
            qh_interpolation(node_id, pre_table)
        else
            error("TabulatedRatingCurve node ID $node_id data not in any table.")
        end
        push!(interpolations, interpolation)
    end
    return TabulatedRatingCurve(node_ids, interpolations, time)
end

function create_storage_tables(db::DB, config::Config)
    df = load_dataframe(db, config, BasinProfileV1; strict = true)
    area = Interpolation[]
    level = Interpolation[]
    for group in groupby(df, :node_id; sort = true)
        order = sortperm(group.storage)
        storage = group.storage[order]
        area_itp = LinearInterpolation(group.area[order], storage)
        level_itp = LinearInterpolation(group.level[order], storage)
        push!(area, area_itp)
        push!(level, level_itp)
    end
    return area, level
end

function FractionalFlow(db::DB, config::Config)::FractionalFlow
    data = load_data(db, config, FractionalFlowStaticV1)
    isnothing(data) && return FractionalFlow()
    tbl = columntable(data)
    return FractionalFlow(tbl.node_id, tbl.fraction)
end

function LevelControl(db::DB, config::Config)::LevelControl
    data = load_data(db, config, LevelControlStaticV1)
    isnothing(data) && return LevelControl()
    tbl = columntable(data)
    # TODO add LevelControl conductance to LHM / ribasim-python datasets
    # TODO Move to Struct constructor
    conductance = fill(100.0 / (3600.0 * 24), length(tbl.node_id))
    return LevelControl(tbl.node_id, tbl.target_level, conductance)
end

function Pump(db::DB, config::Config)::Pump
    data = load_data(db, config, PumpStaticV1)
    isnothing(data) && return Pump()
    tbl = columntable(data)
    return Pump(tbl.node_id, tbl.flow_rate)
end

function push_time_interpolation!(
    interpolations::Vector{Interpolation},
    col::Symbol,
    time::Vector{Float64},  # all float times for forcing_id
    forcing_id::DataFrame,
    t_end::Float64,
    static_id::DataFrame,
)::Vector{Interpolation}
    values = forcing_id[!, col]
    interpolation = LinearInterpolation(values, time)
    if isempty(interpolation)
        # either no records or all missing
        # use static values over entire timespan
        values = static_id[!, col]
        value = if isempty(values)
            0.0  # safe default static value for in- and outflows
        else
            only(values)
        end
        interpolation = LinearInterpolation([value, value], [zero(t_end), t_end])
    end
    @assert interpolation.t[begin] <= 0 "Forcing for $col starts after simulation start."
    @assert interpolation.t[end] >= t_end "Forcing for $col stops before simulation end."
    push!(interpolations, interpolation)
end

function Basin(db::DB, config::Config)::Basin
    # TODO support forcing for other nodetypes
    node_id = get_ids(db, "Basin")
    n = length(node_id)
    current_area = zeros(n)
    current_level = zeros(n)
    area, level = create_storage_tables(db, config)
    t_end = seconds_since(config.endtime, config.starttime)

    # both static and forcing are optional, but we need fallback defaults
    static = load_dataframe(db, config, BasinStaticV1)
    forcing = load_dataframe(db, config, BasinForcingV1)
    if static === forcing === nothing
        error("Neither static or transient forcing found for Basin.")
    end
    if forcing === nothing
        # empty forcing so nothing is found
        forcing = DataFrame(;
            time = DateTime[],
            node_id = Int[],
            precipitation = Float64[],
            potential_evaporation = Float64[],
            drainage = Float64[],
            infiltration = Float64[],
        )
    end
    if static === nothing
        # empty static so nothing is found
        static = DataFrame(;
            node_id = Int[],
            precipitation = Float64[],
            potential_evaporation = Float64[],
            drainage = Float64[],
            infiltration = Float64[],
        )
    end

    precipitation = Interpolation[]
    potential_evaporation = Interpolation[]
    drainage = Interpolation[]
    infiltration = Interpolation[]

    for id in node_id
        # filter forcing for this ID and put it in an Interpolation, or use static as a
        # fallback option
        static_id = filter(:node_id => ==(id), static)
        forcing_id = filter(:node_id => ==(id), forcing)
        time = seconds_since.(forcing_id.time, config.starttime)

        push_time_interpolation!(
            precipitation,
            :precipitation,
            time,
            forcing_id,
            t_end,
            static_id,
        )
        push_time_interpolation!(
            precipitation,
            :precipitation,
            time,
            forcing_id,
            t_end,
            static_id,
        )
        push_time_interpolation!(
            potential_evaporation,
            :potential_evaporation,
            time,
            forcing_id,
            t_end,
            static_id,
        )
        push_time_interpolation!(drainage, :drainage, time, forcing_id, t_end, static_id)
        push_time_interpolation!(
            infiltration,
            :infiltration,
            time,
            forcing_id,
            t_end,
            static_id,
        )
    end

    return Basin(
        current_area,
        current_level,
        area,
        level,
        precipitation,
        potential_evaporation,
        drainage,
        infiltration,
    )
end

function Parameters(db::DB, config::Config)::Parameters

    # Setup node/edges graph, so validate in `Connectivity`?
    connectivity = Connectivity(db)

    linear_level_connection = LinearLevelConnection(db, config)
    tabulated_rating_curve = TabulatedRatingCurve(db, config)
    fractional_flow = FractionalFlow(db, config)
    level_control = LevelControl(db, config)
    pump = Pump(db, config)

    basin = Basin(db, config)

    return Parameters(
        config.starttime,
        connectivity,
        basin,
        linear_level_connection,
        tabulated_rating_curve,
        fractional_flow,
        level_control,
        pump,
    )
end
