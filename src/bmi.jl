"Change a dictionary entry to be relative to `dir` if is is not an abolute path"
function relative_path!(dict, key, dir)
    if haskey(dict, key)
        val = dict[key]
        dict[key] = normpath(dir, val)
    end
    return dict
end

"Make all possible path entries relative to `dir`."
function relative_paths!(dict, dir)
    relative_path!(dict, "forcing", dir)
    relative_path!(dict, "state", dir)
    relative_path!(dict, "static", dir)
    relative_path!(dict, "profile", dir)
    relative_path!(dict, "network_path", dir)
    relative_path!(dict, "waterbalance", dir)
    if haskey(dict, "modflow")
        relative_path!(dict["modflow"], "simulation", dir)
        relative_path!(dict["modflow"]["models"]["gwf"], "dataset", dir)
    end
    # Append pkg version to cache filename
    if haskey(dict, "cache")
        v = pkgversion(Ribasim)
        n, ext = splitext(dict["cache"])
        dict["cache"] = "$(n)_$(string(v))$ext"
        relative_path!(dict, "cache", dir)
    end
    return dict
end

"Parse the TOML configuration file, updating paths to be relative to the TOML file."
function parsefile(config_file::AbstractString)
    config = TOML.parsefile(config_file)
    dir = dirname(config_file)
    return relative_paths!(config, dir)
end

function BMI.initialize(T::Type{Register}, config_file::AbstractString)
    config = TOML.parsefile(config_file)
    dir = dirname(config_file)
    config = relative_paths!(config, dir)
    BMI.initialize(T, config)
end

# create a subgraph, with fractions on the edges we use
function subgraph(network, lsw_ids)
    # defined for every edge in the ply file
    fractions_all = network.edge_table.fractions
    lsw_all = Int.(network.node_table.location)
    graph_all = network.graph
    lsw_indices = [findfirst(==(lsw_id), lsw_all) for lsw_id in lsw_ids]
    graph, _ = induced_subgraph(graph_all, lsw_indices)

    return graph, graph_all, fractions_all, lsw_all
end

function create_curve_dict(profile, lsw_ids)
    @assert issorted(profile.location)

    curve_dict = Dict{Int, Ribasim.StorageCurve}()
    for lsw_id in lsw_ids
        profile_rows = searchsorted(profile.location, lsw_id)
        curve_dict[lsw_id] = Ribasim.StorageCurve(profile.volume[profile_rows],
                                                  profile.area[profile_rows],
                                                  profile.discharge[profile_rows],
                                                  profile.level[profile_rows])
    end
    return curve_dict
end

# Read into memory for now with read, to avoid locking the file, since it mmaps otherwise.
# We could pass Mmap.mmap(path) ourselves and make sure it gets closed, since Arrow.Table
# does not have an io handle to close.
read_table(entry::AbstractString) = Arrow.Table(read(entry))

function read_table(entry)
    @assert Tables.istable(entry)
    return entry
end

"Create an extra column in the forcing which is 0 or the index into the system parameters"
function find_param_index(variable, location, p_vars, p_locs)
    # zero means not in the model, skip
    param_index = zeros(Int, length(variable))

    for i in eachindex(variable, location, param_index)
        var = variable[i]
        loc = location[i]
        for (j, (p_var, p_loc)) in enumerate(zip(p_vars, p_locs))
            if (p_var, p_loc) == (var, loc)
                param_index[i] = j
            end
        end
    end
    return param_index
end

"Get the indices of modflow-coupled LSWs into the system state vector"
function find_volume_index(mf_locs, u_vars, u_locs)
    volume_index = zeros(Int, length(mf_locs))

    for (i, mf_loc) in enumerate(mf_locs)
        for (j, (u_var, u_loc)) in enumerate(zip(u_vars, u_locs))
            if (u_var, u_loc) == (Symbol("lsw.S"), mf_loc)
                volume_index[i] = j
            end
        end
        @assert volume_index[i] != 0
    end
    return volume_index
end

function find_modflow_indices(mf_locs, p_vars, p_locs)
    drainage_index = zeros(Int, length(mf_locs))
    infiltration_index = zeros(Int, length(mf_locs))

    for (i, mf_loc) in enumerate(mf_locs)
        for (j, (p_var, p_loc)) in enumerate(zip(p_vars, p_locs))
            if (p_var, p_loc) == (Symbol("lsw.drainage"), mf_loc)
                drainage_index[i] = j
            elseif (p_var, p_loc) == (Symbol("lsw.infiltration"), mf_loc)
                infiltration_index[i] = j
            end
        end
        @assert drainage_index[i] != 0
        @assert infiltration_index[i] != 0
    end
    return drainage_index, infiltration_index
end

"Collect the indices, locations and names of all integrals, for writing to output"
function prepare_waterbalance(syms::Vector{Symbol})
    # fluxes integrated over time
    wbal_entries = (; location = Int[], variable = String[], index = Int[], flip = Bool[])
    # initial values are handled in callback
    prev_state = fill(NaN, length(syms))
    for (i, sym) in enumerate(syms)
        varname, location = Ribasim.parsename(sym)
        varname = String(varname)
        if endswith(varname, ".sum.x")
            variable = replace(varname, r".sum.x$" => "")
            # flip the sign of the loss terms
            flip = if endswith(variable, ".x.Q")
                true
            elseif variable in ("weir.Q", "lsw.Q_eact", "lsw.infiltration_act")
                true
            else
                false
            end
            push!(wbal_entries.location, location)
            push!(wbal_entries.variable, variable)
            push!(wbal_entries.index, i)
            push!(wbal_entries.flip, flip)
        elseif varname == "lsw.S"
            push!(wbal_entries.location, location)
            push!(wbal_entries.variable, varname)
            push!(wbal_entries.index, i)
            push!(wbal_entries.flip, false)
        end
    end
    return wbal_entries, prev_state
end

function getstate(integrator, s)::Real
    (; u) = integrator
    (; syms) = integrator.sol.prob.f
    sym = Symbolics.getname(s)::Symbol
    i = findfirst(==(sym), syms)
    if i === nothing
        error(lazy"not found: $sym")
    end
    return u[i]
end

function param(integrator, s)::Real
    (; p) = integrator
    (; paramsyms) = integrator.sol.prob.f
    sym = Symbolics.getname(s)::Symbol
    i = findfirst(==(sym), paramsyms)
    if i === nothing
        error(lazy"not found: $sym")
    end
    return p[i]
end

function param!(integrator, s, x::Real)::Real
    (; p) = integrator
    (; paramsyms) = integrator.sol.prob.f
    sym = Symbolics.getname(s)::Symbol
    i = findfirst(==(sym), paramsyms)
    if i === nothing
        error(lazy"not found: $sym")
    end
    return p[i] = x
end

function BMI.initialize(T::Type{Register}, config::AbstractDict)
    # support either paths to Arrow files or tables
    forcing = read_table(config["forcing"])
    state = read_table(config["state"])
    static = read_table(config["static"])
    profile = read_table(config["profile"])

    forcing = DataFrame(forcing)
    state = DataFrame(state)
    static = DataFrame(static)
    profile = DataFrame(profile)

    if haskey(config, "lsw_ids")
        lsw_ids = config["lsw_ids"]::Vector{Int}
    else
        # use all lsw_ids in the state if it is not given in the TOML file
        lsw_ids = Vector{Int}(state.location)
    end
    n_lsw = length(lsw_ids)

    network = if n_lsw == 0
        error("lsw_ids is empty")
    elseif n_lsw == 1 && !haskey(config, "network_path")
        # network_path is optional for size 1 networks
        (graph = DiGraph(1),
         node_table = (; x = [NaN], y = [NaN], location = lsw_ids),
         edge_table = (; fractions = [1.0]),
         crs = nothing)
    else
        read_ply(config["network_path"])
    end

    # Δt for periodic update frequency, including user horizons
    Δt = Float64(config["update_timestep"])
    add_levelcontrol = get(config, "add_levelcontrol", true)::Bool

    starttime = DateTime(config["starttime"])
    endtime = DateTime(config["endtime"])

    curve_dict = create_curve_dict(profile, lsw_ids)

    # read state data
    used_rows = findall(in(lsw_ids), state.location)
    used_state = (; volume = state.volume[used_rows],
                  salinity = state.salinity[used_rows])

    # read static data
    static_rows = findall(in(lsw_ids), static.location)
    target_volumes = static.target_volume[static_rows]
    target_levels = static.target_level[static_rows]
    types = static.local_surface_water_type[static_rows]

    # create a vector of vectors of all non zero general users within all the lsws
    all_users = fill([:agric], length(lsw_ids))

    function allocate!(integrator)
        # exchange with Modflow and Metaswap here
        (; t, p) = integrator

        for (i, id) in enumerate(lsw_ids)
            lswusers = copy(all_users[i])
            type = types[i]
            S = getstate(integrator, name_t(:lsw, id, :S))

            # forcing values
            P = param(integrator, name_t(:lsw, id, :P))
            E_pot = param(integrator, name_t(:lsw, id, :E_pot))
            drainage = param(integrator, name_t(:lsw, id, :drainage))
            infiltration = param(integrator, name_t(:lsw, id, :infiltration))
            urban_runoff = param(integrator, name_t(:lsw, id, :urban_runoff))
            demand_agric = param(integrator, name(:usersys, id, :demand))
            prio_agric = param(integrator, name(:usersys, id, :prio))

            demandlsw = [demand_agric]
            priolsw = [prio_agric]

            # area: it's much faster to do the area lookup ourselves than to generate the
            # observed function for area and get it from there
            curve = curve_dict[id]
            lsw_area = LinearInterpolation(curve.a, curve.s)
            area = lsw_area(S)

            if type == 'P'
                if add_levelcontrol
                    # TODO integrate with forcing
                    prio_wm = 0

                    # set the Q_wm for the coming day based on the expected storage
                    tv_name = Symbol(:levelcontrol_, id, :₊target_volume)
                    target_volume = param(integrator, tv_name)

                    # what is the expected storage difference at the end of the period
                    # if there is no watermanagement?
                    # this assumes a constant area during the period
                    # TODO add upstream to ΔS calculation
                    ΔS = Δt *
                         ((area * P) + drainage - infiltration + urban_runoff -
                          (area * E_pot))
                    Q_wm = (S + ΔS - target_volume) / Δt

                    # add levelcontrol to users
                    push!(lswusers, :levelcontrol)
                    push!(demandlsw, -Q_wm) # make negative to keep consistent with other demands
                    push!(priolsw, prio_wm)
                else
                    Q_wm = 0.0
                end

                allocate_P!(;
                            integrator,
                            lsw_id = id,
                            P,
                            area,
                            E_pot,
                            urban_runoff,
                            drainage,
                            infiltration,
                            demandlsw,
                            priolsw,
                            lswusers,
                            wm_demand = Q_wm)
            elseif length(lswusers) > 0
                # allocate to different users for a free flowing LSW
                allocate_V!(;
                            integrator,
                            lsw_id = id,
                            P,
                            area,
                            E_pot,
                            urban_runoff,
                            drainage,
                            infiltration,
                            demandlsw,
                            priolsw,
                            lswusers = lswusers)
            end

            # update parameters
            param!(integrator, name_t(:lsw, id, :P), P)
            param!(integrator, name_t(:lsw, id, :E_pot), E_pot)
            param!(integrator, name_t(:lsw, id, :drainage), drainage)
            param!(integrator, name_t(:lsw, id, :infiltration), infiltration)
            param!(integrator, name_t(:lsw, id, :urban_runoff), urban_runoff)

            # Allocate water to flushing (only external water. Flush in = Flush out)
            # outname_flush = Symbol(:flushing_, id, :₊)
            # param!(integrator, Symbol(outname_flush, :Q), demand_flush)

        end

        Ribasim.save!(param_hist, t, p)
        return nothing
    end

    # Allocate function for free flowing LSWs
    function allocate_V!(;
                         integrator,
                         lsw_id,
                         P,
                         area,
                         E_pot,
                         urban_runoff,
                         drainage,
                         infiltration,
                         demandlsw,
                         priolsw,
                         lswusers::Vector{Symbol})

        # function for demand allocation based upon user prioritisation
        # Note: equation not currently reproducing Mozart
        Q_avail_vol = ((P - E_pot) * area) / Δt -
                      min(0.0, infiltration - drainage - urban_runoff)

        users = []
        for (i, user) in enumerate(lswusers)
            priority = priolsw[i]
            demand = demandlsw[i]
            tmp = (; user, priority, demand, alloc = Ref(0.0))
            push!(users, tmp)
        end
        sort!(users, by = x -> x.priority)

        # allocate by priority based on available water
        for user in users
            if user.demand <= 0
                # allocation is initialized to 0
            elseif Q_avail_vol >= user.demand
                user.alloc[] = user.demand
                Q_avail_vol -= user.alloc[]
            else
                user.alloc[] = Q_avail_vol
                Q_avail_vol = 0.0
            end

            # update parameters
            symalloc = name(:usersys, lsw_id, :alloc)
            param!(integrator, symalloc, -user.alloc[])
            # The following are not essential for the simulation
            symdemand = name(:usersys, lsw_id, :demand)
            param!(integrator, symdemand, -user.demand[])
            symprio = name(:usersys, lsw_id, :prio)
            param!(integrator, symprio, user.priority[])
        end

        return nothing
    end

    # Allocate function for level controled LSWs
    function allocate_P!(;
                         integrator,
                         lsw_id,
                         P,
                         area,
                         E_pot,
                         urban_runoff,
                         drainage,
                         infiltration,
                         demandlsw,
                         priolsw,
                         lswusers::Vector{Symbol},
                         wm_demand)
        # function for demand allocation based upon user prioritisation
        # Note: equation not currently reproducing Mozart
        Q_avail_vol = ((P - E_pot) * area) / Δt -
                      min(0.0, infiltration - drainage - urban_runoff)

        users = []
        total_user_demand = 0.0
        for (i, user) in enumerate(lswusers)
            priority = priolsw[i]
            demand = demandlsw[i]
            tmp = (; user, priority, demand, alloc_a = Ref(0.0), alloc_b = Ref(0.0)) # alloc_a is lsw sourced, alloc_b is external source
            push!(users, tmp)
            total_user_demand += demand
        end
        sort!(users, by = x -> x.priority)

        if wm_demand > 0.0
            Q_avail_vol += wm_demand
        end
        external_demand = total_user_demand - Q_avail_vol
        external_avail = external_demand # For prototype, enough water can be supplied from external

        # allocate by priority based on available water
        for user in users
            if user.demand <= 0.0
                # allocation is initialized to 0
                if user.user === :levelcontrol
                    # pump excess water to external water
                    user.alloc_b[] = user.demand
                end
            elseif Q_avail_vol >= user.demand
                user.alloc_a[] = user.demand
                Q_avail_vol -= user.alloc_a[]
                if user.user !== :levelcontrol
                    # if general users are allocated by lsw water before wm, then the wm demand increases
                    levelcontrol.demand += user.alloc_a
                end
            else
                # If water cannot be supplied by LSW, demand is sourced from external network
                external_alloc = user.demand - Q_avail_vol
                Q_avail_vol = 0.0
                if external_avail >= external_alloc # Currently always true
                    user.alloc_b[] = external_alloc
                    external_avail -= external_alloc
                else
                    user.alloc_b[] = external_avail
                    external_avail = 0.0
                end
            end

            # update parameters
            # TODO generalize for new user naming
            symalloc = name(:usersys, lsw_id, :alloc_a)
            param!(integrator, symalloc, -user.alloc_a[])
            symalloc = name(:usersys, lsw_id, :alloc_b)
            param!(integrator, symalloc, -user.alloc_b[])
        end

        return nothing
    end

    param_hist = ForwardFill(Float64[], Vector{Float64}[])
    tspan = (datetime2unix(starttime), datetime2unix(endtime))

    if !(haskey(config, "cache") && isfile(config["cache"]))
        graph, graph_all, fractions_all, lsw_all = subgraph(network, lsw_ids)
        fractions = fraction_dict(graph_all, fractions_all, lsw_all, lsw_ids)

        # store all MTK.unbound_inputs here to speed up structural simplify,
        # avoiding some quadratic scaling
        inputs = []
        @named netsys = NetworkSystem(; lsw_ids, types, graph, fractions, target_volumes,
                                      target_levels,
                                      used_state, all_users, curve_dict, add_levelcontrol,
                                      inputs)

        sim, input_idxs = structural_simplify(netsys, (; inputs, outputs = []))

        prob = ODAEProblem(sim, [], tspan; sparse = true)
        if haskey(config, "cache")
            @warn "Cache is specified, but path $(config["cache"])
                doesn't exist yet; creating it now."
            open(config["cache"], "w") do io
                serialize(io, prob)
            end
        end
    else
        @info "Using cached problem from $(config["cache"])."
        prob = deserialize(config["cache"])
    end

    # subset of parameters that we possibly have forcing data for
    # map from variable symbols from Ribasim.parsename to forcing.variable symbols
    # TODO make this systematic such that we don't need a manual mapping anymore
    paramvars = Dict{Symbol, Symbol}(:agric_demand => :demand_agriculture,
                                     :agric_prio => :priority_agriculture,
                                     :P => :precipitation,
                                     :E_pot => :evaporation,
                                     :infiltration => :infiltration,
                                     :drainage => :drainage,
                                     :urban_runoff => :urban_runoff)

    run_modflow = get(config, "run_modflow", false)::Bool
    if run_modflow
        # these will be provided by modflow
        pop!(paramvars, :drainage)
        pop!(paramvars, :infiltration)
    end

    # add (t) to make it the same with the syms as stored in the integrator
    syms = [Symbol(getname(s), "(t)") for s in states(prob.f.sys)]
    paramsyms = getname.(parameters(prob.f.sys))
    # take only the forcing data we need, and add the system's parameter index
    # split out the variables and locations to make it easier to find the right param index
    pf_vars = [get(paramvars, Ribasim.parsename(p)[1], :none) for p in paramsyms]
    pf_locs = getindex.(Ribasim.parsename.(paramsyms), 2)

    param_index = find_param_index(forcing.variable, forcing.location, pf_vars, pf_locs)
    used_param_index = filter(!=(0), param_index)
    used_rows = findall(!=(0), param_index)
    # consider usign views here
    used_time = forcing.time[used_rows]
    @assert issorted(used_time) "time column in forcing must be sorted"
    used_time_unix = datetime2unix.(used_time)
    used_value = forcing.value[used_rows]
    # this is how often we need to callback
    used_time_uniq = unique(used_time)

    # find the range of the current timestep, and the associated parameter indices,
    # and update all the corresponding parameter values
    # captures used_time_unix, used_param_index, used_value, param_hist
    function update_forcings!(integrator)
        (; t, p) = integrator
        r = searchsorted(used_time_unix, t)
        i = used_param_index[r]
        v = used_value[r]
        p[i] .= v
        Ribasim.save!(param_hist, t, p)
        return nothing
    end

    if run_modflow
        # initialize Modflow model
        config_modflow = config["modflow"]
        Δt_modflow = Float64(config_modflow["timestep"])
        rme = RibasimModflowExchange(config_modflow, lsw_ids)

        # get the index into the system state vector for each coupled LSW
        mf_locs = collect(keys(rme.basin_volume))
        u_vars = getindex.(Ribasim.parsename.(syms), 1)
        u_locs = getindex.(Ribasim.parsename.(syms), 2)
        volume_index = find_volume_index(mf_locs, u_vars, u_locs)

        # similarly for the index into the system parameter vector
        pmf_vars = getindex.(Ribasim.parsename.(paramsyms), 1)
        pmf_locs = getindex.(Ribasim.parsename.(paramsyms), 2)
        drainage_index, infiltration_index = find_modflow_indices(mf_locs, pmf_vars,
                                                                  pmf_locs)
    else
        rme = nothing
    end

    # captures volume_index, drainage_index, infiltration_index, rme, tspan
    function exchange_modflow!(integrator)
        (; t, u, p) = integrator

        # set basin_volume from Ribasim
        # mutate the underlying vector, we know the keys are equal
        rme.basin_volume.values .= u[volume_index]

        # convert basin_volume to modflow levels
        exchange_ribasim_to_modflow!(rme)

        # run modflow timestep
        first_step = t == tspan[begin]
        update!(rme.modflow, first_step)

        # sets basin_infiltration and basin_drainage from modflow
        exchange_modflow_to_ribasim!(rme)

        # put basin_infiltration and basin_drainage into Ribasim
        # convert modflow m3/d to Ribasim m3/s, both positive
        # TODO don't use infiltration and drainage from forcing
        p[drainage_index] .= rme.basin_drainage.values ./ 86400.0
        p[infiltration_index] .= rme.basin_infiltration.values ./ 86400.0
    end

    wbal_entries, prev_state = prepare_waterbalance(syms)
    waterbalance = DataFrame(time = DateTime[], variable = String[], location = Int[],
                             value = Float64[])
    # captures waterbalance, wbal_entries, prev_state, tspan
    function write_output!(integrator)
        (; t, u) = integrator
        time = unix2datetime(t)
        first_step = t == tspan[begin]
        for (; variable, location, index, flip) in Tables.rows(wbal_entries)
            if variable == "lsw.S"
                S = u[index]
                if first_step
                    prev_state[index] = S
                end
                value = prev_state[index] - S
                prev_state[index] = S
            else
                value = flip ? -u[index] : u[index]
                u[index] = 0.0  # reset cumulative back to 0 to get m3 since previous record
            end
            record = (; time, variable, location, value)
            push!(waterbalance, record)
        end
    end

    # To retain all information, we need to save before and after callbacks that affect the
    # system, meaning we get multiple outputs on the same timestep. Make it configurable
    # to be able to disable callback saving as needed.
    # TODO: Check if regular saveat saving is before or after the callbacks.
    save_positions = Tuple(get(config, "save_positions", (true, true)))::Tuple{Bool, Bool}
    forcing_cb = PresetTimeCallback(datetime2unix.(used_time_uniq), update_forcings!;
                                    save_positions)
    allocation_cb = PeriodicCallback(allocate!, Δt; initial_affect = true, save_positions)
    Δt_output = Float64(get(config, "output_timestep", 86400.0))
    output_cb = PeriodicCallback(write_output!, Δt_output; initial_affect = true,
                                 save_positions = (false, false))

    cb = if run_modflow
        modflow_cb = PeriodicCallback(exchange_modflow!, Δt_modflow; initial_affect = true)
        CallbackSet(forcing_cb, allocation_cb, output_cb, modflow_cb)
    else
        CallbackSet(forcing_cb, allocation_cb, output_cb)
    end

    integrator = init(prob,
                      AutoTsit5(Rosenbrock23());
                      progress = true,
                      progress_name = "Simulating",
                      callback = cb,
                      saveat = get(config, "saveat", []),
                      abstol = 1e-6,
                      reltol = 1e-3)

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

run(config_file::AbstractString) = run(parsefile(config_file))

function run(config::AbstractDict)
    reg = BMI.initialize(Register, config)
    solve!(reg.integrator)
    if haskey(config, "waterbalance")
        path = config["waterbalance"]
        # create directory if needed
        mkpath(dirname(path))
        Arrow.write(path, reg.waterbalance)
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
