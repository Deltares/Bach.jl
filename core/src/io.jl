function get_ids(db::DB)::Vector{Int}
    return only(execute(columntable, db, "select fid from Node"))
end

function get_ids(db::DB, nodetype)::Vector{Int}
    sql = "select fid from Node where type = $(esc_id(nodetype))"
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
    seconds_since(t::DateTime, t0::DateTime)::Float64

Convert a DateTime to a float that is the number of seconds since the start of the
simulation. This is used to convert between the solver's inner float time, and the calendar.
"""
seconds_since(t::DateTime, t0::DateTime)::Float64 = 0.001 * Dates.value(t - t0)

"""
    datetime_since(t::Real, t0::DateTime)::DateTime

Convert a Real that represents the seconds passed since the simulation start to the nearest
DateTime. This is used to convert between the solver's inner float time, and the calendar.
"""
datetime_since(t::Real, t0::DateTime)::DateTime = t0 + Millisecond(round(1000 * t))

"""
    load_data(db::DB, config::Config, nodetype::Symbol, kind::Symbol)::Union{Table, Query, Nothing}

Load data from Arrow files if available, otherwise the GeoPackage.
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
    path = getfield(getfield(config, node), kind)
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

Load data from Arrow files if available, otherwise the GeoPackage.
Always returns a StructVector of the given struct type T, which is empty if the table is
not found.
"""
function load_structvector(
    db::DB,
    config::Config,
    ::Type{T},
)::StructVector{T} where {T <: AbstractRow}
    table = load_data(db, config, T)
    if isnothing(table)
        return StructVector{T}(undef, 0)
    end

    nt = Tables.columntable(table)
    if table isa Query && haskey(nt, :time)
        # time is stored as a String in the GeoPackage
        nt = merge(nt, (; time = DateTime.(nt.time)))
    end

    table = StructVector{T}(nt)
    sv = Legolas._schema_version_from_record_type(T)
    tableschema = Tables.schema(table)
    if declared(sv) && !isnothing(tableschema)
        validate(tableschema, sv)
        # R = Legolas.record_type(sv)
        # foreach(R, Tables.rows(table))  # construct each row
    else
        @warn "No (validation) schema declared for $nodetype $kind"
    end

    return table
end

"Construct a path relative to both the TOML directory and the optional `input_dir`"
function input_path(config::Config, path::String)
    return normpath(config.toml_dir, config.input_dir, path)
end

"Construct a path relative to both the TOML directory and the optional `output_dir`"
function output_path(config::Config, path::String)
    return normpath(config.toml_dir, config.output_dir, path)
end

parsefile(config_path::AbstractString) =
    from_toml(Config, config_path; toml_dir = dirname(normpath(config_path)))

function write_basin_output(model::Model)
    (; config, integrator) = model
    (; sol, p) = integrator

    # u_index is an OrderedDict, in the same order as u
    basin_id = collect(keys(p.connectivity.u_index))
    nbasin = length(basin_id)
    tsteps = datetime_since.(timesteps(model), config.starttime)
    ntsteps = length(tsteps)

    time = convert.(Arrow.DATETIME, repeat(tsteps; inner = nbasin))
    node_id = repeat(basin_id; outer = ntsteps)

    storage = reshape(vec(sol), nbasin, ntsteps)
    level = zero(storage)
    for (i, basin_storage) in enumerate(eachrow(storage))
        level[i, :] = p.basin.level[i].(basin_storage)
    end

    basin = (; time, node_id, storage = vec(storage), level = vec(level))
    path = output_path(config, config.output.basin)
    mkpath(dirname(path))
    Arrow.write(path, basin; compress = :lz4)
end

function write_flow_output(model::Model)
    (; config, saved_flow, integrator) = model
    (; t, saveval) = saved_flow
    (; connectivity) = integrator.p

    I, J, _ = findnz(connectivity.flow)
    unique_edge_ids = [connectivity.edge_ids[i, j] for (i, j) in zip(I, J)]
    nflow = length(I)
    ntsteps = length(t)

    time =
        convert.(
            Arrow.DATETIME,
            repeat(datetime_since.(t, config.starttime); inner = nflow),
        )
    edge_id = repeat(unique_edge_ids; outer = ntsteps)
    from_node_id = repeat(I; outer = ntsteps)
    to_node_id = repeat(J; outer = ntsteps)
    flow = collect(Iterators.flatten(saveval))

    table = (; time, edge_id, from_node_id, to_node_id, flow)
    path = output_path(config, config.output.flow)
    mkpath(dirname(path))
    Arrow.write(path, table; compress = :lz4)
end
