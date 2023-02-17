"Construct a path relative to both the TOML directory and the optional `dir_input`"
function input_path(config::Config, path::String)
    return normpath(config.toml_dir, config.dir_input, path)
end

"Construct a path relative to both the TOML directory and the optional `dir_output`"
function output_path(config::Config, path::String)
    return normpath(config.toml_dir, config.dir_output, path)
end

parsefile(config_path::AbstractString) =
    from_toml(Config, config_path; toml_dir = dirname(normpath(config_path)))

function BMI.initialize(T::Type{Register}, config_path::AbstractString)
    config = parsefile(config_path)
    BMI.initialize(T, config)
end

# create a subgraph, with fractions on the edges we use
function subgraph(network, ids)
    # defined for every edge in the ply file
    fractions_all = network.edge_table.fractions
    lsw_all = Int.(network.node_table.location)
    graph_all = network.graph
    lsw_indices = [findfirst(==(lsw_id), lsw_all) for lsw_id in ids]
    graph, _ = induced_subgraph(graph_all, lsw_indices)

    return graph, graph_all, fractions_all, lsw_all
end

# Read into memory for now with read, to avoid locking the file, since it mmaps otherwise.
# We could pass Mmap.mmap(path) ourselves and make sure it gets closed, since Arrow.Table
# does not have an io handle to close.
_read_table(entry::AbstractString) = Arrow.Table(read(entry))
_read_table(entry) = entry

function read_table(entry; schema = nothing)
    table = _read_table(entry)
    @assert Tables.istable(table)
    if !isnothing(schema)
        sv = schema()
        validate(Tables.schema(table), sv)
        R = Legolas.record_type(sv)
        foreach(R, Tables.rows(table))  # construct each row
    end
    return DataFrame(table)
end

"Create an extra column in the forcing which is 0 or the index into the system parameters"
function find_param_index(forcing, p_vars, p_ids)
    (; variable, id) = forcing
    # 0 means not in the model, skip
    param_index = zeros(Int, length(variable))

    for i in eachindex(variable, id, param_index)
        var = variable[i]
        id_ = id[i]
        for (j, (p_var, p_id)) in enumerate(zip(p_vars, p_ids))
            if (p_id == id_) && (p_var == var)
                param_index[i] = j
            end
        end
    end
    return param_index
end

function BMI.initialize(T::Type{Register}, config::Config)
    gpkg_path = input_path(config, config.geopackage)
    if !isfile(gpkg_path)
        throw(SystemError("GeoPackage file not found: ", gpkg_path))
    end
    db = DB(gpkg_path)  # sqlite DB

    parameters, used_time_uniq = create_parameters(db, config)

    # We update parameters with forcing data. Only the current value per parameter is
    # stored in the solution object, so we track the history ourselves.
    param_hist = ForwardFill(Float64[], Vector{Float64}[])
    tspan = (datetime2unix(config.starttime), datetime2unix(config.endtime))

    @timeit_debug to "Setup ODEProblem" begin
        u0 = ones(length(parameters.area)) .* 10.0
        prob = ODEProblem(water_balance!, u0, tspan, parameters)
    end

    # To retain all information, we need to save before and after callbacks that affect the
    # system, meaning we get multiple outputs on the same timestep. Make it configurable
    # to be able to disable callback saving as needed.
    # TODO: Check if regular saveat saving is before or after the callbacks.
    forcing_cb = PresetTimeCallback(
        datetime2unix.(used_time_uniq),
        update_forcings!;
        config.save_positions,
    )
    # add a single time step's contribution to the water balance step's totals
    trackwb_cb = FunctionCallingCallback(track_waterbalance!)

    @timeit_debug to "Setup callbackset" callback = CallbackSet(forcing_cb, trackwb_cb)

    @timeit_debug to "Setup integrator" integrator = init(
        prob,
        Euler();
        dt = config.update_timestep,
        progress = true,
        progress_name = "Simulating",
        callback,
        config.saveat,
        abstol = 1e-6,
        reltol = 1e-3,
    )

    waterbalance = DataFrame()  # not used at the moment
    return Register(integrator, param_hist, waterbalance)
end

function BMI.update(reg::Register)
    step!(reg.integrator)
    return reg
end

function BMI.update_until(reg::Register, time)
    integrator = reg.integrator
    t = integrator.t
    dt = time - t
    if dt < 0
        error("The model has already passed the given timestamp.")
    elseif dt == 0
        return reg
    else
        step!(integrator, dt)
    end
    return reg
end

BMI.get_current_time(reg::Register) = reg.integrator.t

run(config_file::AbstractString) = run(TOML.parsefile(config_file))

function run(config::Config)
    reg = BMI.initialize(Register, config)
    solve!(reg.integrator)
    if haskey(config, "waterbalance")
        path = config["waterbalance"]
        # create directory if needed
        mkpath(dirname(path))
    end
    return reg
end

function run()
    usage = "Usage: julia -e 'using Ribasim; Ribasim.run()' 'path/to/config.toml'"
    n = length(ARGS)
    if n != 1
        throw(ArgumentError(usage))
    end
    toml_path = only(ARGS)
    if !isfile(toml_path)
        throw(ArgumentError("File not found: $(toml_path)\n" * usage))
    end
    run(toml_path)
end
