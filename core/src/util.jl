"Get the package version of a given module"
function pkgversion(m::Module)::VersionNumber
    version = Base.pkgversion(Ribasim)
    !isnothing(version) && return version

    # Base.pkgversion doesn't work with compiled binaries
    # If it returns `nothing`, we try a different way
    rootmodule = Base.moduleroot(m)
    pkg = Base.PkgId(rootmodule)
    pkgorigin = get(Base.pkgorigins, pkg, nothing)
    return pkgorigin.version
end

"Calculate a profile storage by integrating the areas over the levels"
function profile_storage(levels::Vector, areas::Vector)::Vector{Float64}
    # profile starts at the bottom; first storage is 0
    storages = zero(areas)
    n = length(storages)

    for i in 2:n
        Δh = levels[i] - levels[i - 1]
        avg_area = 0.5 * (areas[i - 1] + areas[i])
        ΔS = avg_area * Δh
        storages[i] = storages[i - 1] + ΔS
    end
    return storages
end

"""Get the storage of a basin from its level."""
function get_storage_from_level(basin::Basin, state_idx::Int, level::Float64)::Float64
    storage_discrete = basin.storage[state_idx]
    area_discrete = basin.area[state_idx]
    level_discrete = basin.level[state_idx]
    bottom = first(level_discrete)

    if level < bottom
        node_id = basin.node_id.values[state_idx]
        @error "The level $level of basin $node_id is lower than the bottom of this basin $bottom."
        return NaN
    end

    level_lower_index = searchsortedlast(level_discrete, level)

    # If the level is equal to the bottom then the storage is 0
    if level_lower_index == 0
        return 0.0
    end

    level_lower_index = min(level_lower_index, length(level_discrete) - 1)

    darea =
        (area_discrete[level_lower_index + 1] - area_discrete[level_lower_index]) /
        (level_discrete[level_lower_index + 1] - level_discrete[level_lower_index])

    level_lower = level_discrete[level_lower_index]
    area_lower = area_discrete[level_lower_index]
    level_diff = level - level_lower

    storage =
        storage_discrete[level_lower_index] +
        area_lower * level_diff +
        0.5 * darea * level_diff^2

    return storage
end

"""Compute the storages of the basins based on the water level of the basins."""
function get_storages_from_levels(basin::Basin, levels::Vector)::Vector{Float64}
    errors = false
    state_length = length(levels)
    basin_length = length(basin.level)
    if state_length != basin_length
        @error "Unexpected 'Basin / state' length." state_length basin_length
        errors = true
    end
    storages = zeros(state_length)

    for (i, level) in enumerate(levels)
        storage = get_storage_from_level(basin, i, level)
        if isnan(storage)
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
Compute the area and level of a basin given its storage.
Also returns darea/dlevel as it is needed for the Jacobian.
"""
function get_area_and_level(basin::Basin, state_idx::Int, storage::Real)::Tuple{Real, Real}
    storage_discrete = basin.storage[state_idx]
    area_discrete = basin.area[state_idx]
    level_discrete = basin.level[state_idx]

    return get_area_and_level(storage_discrete, area_discrete, level_discrete, storage)
end

function get_area_and_level(
    storage_discrete::Vector,
    area_discrete::Vector,
    level_discrete::Vector,
    storage::Real,
)::Tuple{Real, Real}
    # storage_idx: smallest index such that storage_discrete[storage_idx] >= storage
    storage_idx = searchsortedfirst(storage_discrete, storage)

    if storage_idx == 1
        # This can only happen if the storage is 0
        level = level_discrete[1]
        area = area_discrete[1]

        level_lower = level
        level_higher = level_discrete[2]
        area_lower = area
        area_higher = area_discrete[2]

        darea = (area_higher - area_lower) / (level_higher - level_lower)

    elseif storage_idx == length(storage_discrete) + 1
        # With a storage above the profile, use a linear extrapolation of area(level)
        # based on the last 2 values.
        area_lower = area_discrete[end - 1]
        area_higher = area_discrete[end]
        level_lower = level_discrete[end - 1]
        level_higher = level_discrete[end]
        storage_lower = storage_discrete[end - 1]
        storage_higher = storage_discrete[end]

        area_diff = area_higher - area_lower
        level_diff = level_higher - level_lower

        if area_diff ≈ 0
            # Constant area means linear interpolation of level
            darea = 0.0
            area = area_lower
            level =
                level_higher +
                level_diff * (storage - storage_higher) / (storage_higher - storage_lower)
        else
            darea = area_diff / level_diff
            area = sqrt(area_higher^2 + 2 * (storage - storage_higher) * darea)
            level = level_lower + level_diff * (area - area_lower) / area_diff
        end

    else
        area_lower = area_discrete[storage_idx - 1]
        area_higher = area_discrete[storage_idx]
        level_lower = level_discrete[storage_idx - 1]
        level_higher = level_discrete[storage_idx]
        storage_lower = storage_discrete[storage_idx - 1]
        storage_higher = storage_discrete[storage_idx]

        area_diff = area_higher - area_lower
        level_diff = level_higher - level_lower

        if area_diff ≈ 0
            # Constant area means linear interpolation of level
            darea = 0.0
            area = area_lower
            level =
                level_lower +
                level_diff * (storage - storage_lower) / (storage_higher - storage_lower)

        else
            darea = area_diff / level_diff
            area = sqrt(area_lower^2 + 2 * (storage - storage_lower) * darea)
            level = level_lower + level_diff * (area - area_lower) / area_diff
        end
    end

    return area, level
end

"""
For an element `id` and a vector of elements `ids`, get the range of indices of the last
consecutive block of `id`.
Returns the empty range `1:0` if `id` is not in `ids`.

```jldoctest
#                         1 2 3 4 5 6 7 8 9
Ribasim.findlastgroup(2, [5,4,2,2,5,2,2,2,1])
# output
6:8
```
"""
function findlastgroup(id::Int, ids::AbstractVector{Int})::UnitRange{Int}
    idx_block_end = findlast(==(id), ids)
    if idx_block_end === nothing
        return 1:0
    end
    idx_block_begin = findprev(!=(id), ids, idx_block_end)
    idx_block_begin = if idx_block_begin === nothing
        1
    else
        # can happen if that id is the only ID in ids
        idx_block_begin + 1
    end
    return idx_block_begin:idx_block_end
end

"Linear interpolation of a scalar with constant extrapolation."
function get_scalar_interpolation(
    starttime::DateTime,
    t_end::Float64,
    time::AbstractVector,
    node_id::Int,
    param::Symbol;
    default_value::Float64 = 0.0,
)::Tuple{LinearInterpolation, Bool}
    rows = searchsorted(time.node_id, node_id)
    parameter = getfield.(time, param)[rows]
    parameter = coalesce(parameter, default_value)
    times = seconds_since.(time.time[rows], starttime)
    # Add extra timestep at start for constant extrapolation
    if times[1] > 0
        pushfirst!(times, 0.0)
        pushfirst!(parameter, parameter[1])
    end
    # Add extra timestep at end for constant extrapolation
    if times[end] < t_end
        push!(times, t_end)
        push!(parameter, parameter[end])
    end

    return LinearInterpolation(parameter, times), allunique(times)
end

"Derivative of scalar interpolation."
function scalar_interpolation_derivative(
    itp::ScalarInterpolation,
    t::Float64;
    extrapolate_down_constant::Bool = true,
    extrapolate_up_constant::Bool = true,
)::Float64
    # The function 'derivative' doesn't handle extrapolation well (DataInterpolations v4.0.1)
    t_smaller_index = searchsortedlast(itp.t, t)
    if t_smaller_index == 0
        if extrapolate_down_constant
            return 0.0
        else
            # Get derivative in middle of last interval
            return derivative(itp, (itp.t[end] - itp.t[end - 1]) / 2)
        end
    elseif t_smaller_index == length(itp.t)
        if extrapolate_up_constant
            return 0.0
        else
            # Get derivative in middle of first interval
            return derivative(itp, (itp.t[2] - itp.t[1]) / 2)
        end
    else
        return derivative(itp, t)
    end
end

function qh_interpolation(
    level::AbstractVector,
    flow_rate::AbstractVector,
)::Tuple{LinearInterpolation, Bool}
    return LinearInterpolation(flow_rate, level; extrapolate = true), allunique(level)
end

"""
From a table with columns node_id, flow_rate (Q) and level (h),
create a LinearInterpolation from level to flow rate for a given node_id.
"""
function qh_interpolation(
    node_id::Int,
    table::StructVector,
)::Tuple{LinearInterpolation, Bool}
    rowrange = findlastgroup(node_id, table.node_id)
    @assert !isempty(rowrange) "timeseries starts after model start time"
    return qh_interpolation(table.level[rowrange], table.flow_rate[rowrange])
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

"""
Update `table` at row index `i`, with the values of a given row.
`table` must be a NamedTuple of vectors with all variables that must be loaded.
The row must contain all the column names that are present in the table.
If a value is missing, it is not set.
"""
function set_table_row!(table::NamedTuple, row, i::Int)::NamedTuple
    for (symbol, vector) in pairs(table)
        val = getproperty(row, symbol)
        if !ismissing(val)
            vector[i] = val
        end
    end
    return table
end

"""
Load data from a source table `static` into a destination `table`.
Data is matched based on the node_id, which is sorted.
"""
function set_static_value!(
    table::NamedTuple,
    node_id::Vector{Int},
    static::StructVector,
)::NamedTuple
    for (i, id) in enumerate(node_id)
        idx = findsorted(static.node_id, id)
        idx === nothing && continue
        row = static[idx]
        set_table_row!(table, row, i)
    end
    return table
end

"""
From a timeseries table `time`, load the most recent applicable data into `table`.
`table` must be a NamedTuple of vectors with all variables that must be loaded.
The most recent applicable data is non-NaN data for a given ID that is on or before `t`.
"""
function set_current_value!(
    table::NamedTuple,
    node_id::Vector{Int},
    time::StructVector,
    t::DateTime,
)::NamedTuple
    idx_starttime = searchsortedlast(time.time, t)
    pre_table = view(time, 1:idx_starttime)

    for (i, id) in enumerate(node_id)
        for (symbol, vector) in pairs(table)
            idx = findlast(
                row -> row.node_id == id && !ismissing(getproperty(row, symbol)),
                pre_table,
            )
            if idx !== nothing
                vector[i] = getproperty(pre_table, symbol)[idx]
            end
        end
    end
    return table
end

function check_no_nans(table::NamedTuple, nodetype::String)
    for (symbol, vector) in pairs(table)
        any(isnan, vector) &&
            error("Missing initial data for the $nodetype variable $symbol")
    end
    return nothing
end

"From an iterable of DateTimes, find the times the solver needs to stop"
function get_tstops(time, starttime::DateTime)::Vector{Float64}
    unique_times = unique(time)
    return seconds_since.(unique_times, starttime)
end

"""
Get the current water level of a node ID.
The ID can belong to either a Basin or a LevelBoundary.
storage: tells ForwardDiff whether this call is for differentiation or not
"""
function get_level(
    p::Parameters,
    node_id::NodeID,
    t::Number;
    storage::Union{AbstractArray, Number} = 0,
)::Union{Real, Nothing}
    (; basin, level_boundary) = p
    hasindex, i = id_index(basin.node_id, node_id)
    current_level = get_tmp(basin.current_level, storage)
    return if hasindex
        current_level[i]
    else
        i = findsorted(level_boundary.node_id, node_id)
        if i === nothing
            nothing
        else
            level_boundary.level[i](t)
        end
    end
end

"Get the index of an ID in a set of indices."
function id_index(ids::Indices{NodeID}, id::NodeID)::Tuple{Bool, Int}
    # We avoid creating Dictionary here since it converts the values to a Vector,
    # leading to allocations when used with PreallocationTools's ReinterpretArrays.
    hasindex, (_, i) = gettoken(ids, id)
    return hasindex, i
end

"Return the bottom elevation of the basin with index i, or nothing if it doesn't exist"
function basin_bottom(basin::Basin, node_id::NodeID)::Union{Float64, Nothing}
    hasindex, i = id_index(basin.node_id, node_id)
    return if hasindex
        # get level(storage) interpolation function
        level_discrete = basin.level[i]
        # and return the first level in this vector, representing the bottom
        first(level_discrete)
    else
        nothing
    end
end

"Get the bottom on both ends of a node. If only one has a bottom, use that for both."
function basin_bottoms(
    basin::Basin,
    basin_a_id::NodeID,
    basin_b_id::NodeID,
    id::NodeID,
)::Tuple{Float64, Float64}
    bottom_a = basin_bottom(basin, basin_a_id)
    bottom_b = basin_bottom(basin, basin_b_id)
    if bottom_a === bottom_b === nothing
        error(lazy"No bottom defined on either side of $id")
    end
    bottom_a = something(bottom_a, bottom_b)
    bottom_b = something(bottom_b, bottom_a)
    return bottom_a, bottom_b
end

"""
Replace the truth states in the logic mapping which contain wildcards with
all possible explicit truth states.
"""
function expand_logic_mapping(
    logic_mapping::Dict{Tuple{NodeID, String}, String},
)::Dict{Tuple{NodeID, String}, String}
    logic_mapping_expanded = Dict{Tuple{NodeID, String}, String}()

    for (node_id, truth_state) in keys(logic_mapping)
        pattern = r"^[TFUD\*]+$"
        if !occursin(pattern, truth_state)
            error("Truth state \'$truth_state\' contains illegal characters or is empty.")
        end

        control_state = logic_mapping[(node_id, truth_state)]
        n_wildcards = count(==('*'), truth_state)

        substitutions = if n_wildcards > 0
            substitutions = Iterators.product(fill(['T', 'F'], n_wildcards)...)
        else
            [nothing]
        end

        # Loop over all substitution sets for the wildcards
        for substitution in substitutions
            truth_state_new = ""
            s_index = 0

            # If a wildcard is found replace it, otherwise take the old truth value
            for truth_value in truth_state
                truth_state_new *= if truth_value == '*'
                    s_index += 1
                    substitution[s_index]
                else
                    truth_value
                end
            end

            new_key = (node_id, truth_state_new)

            if haskey(logic_mapping_expanded, new_key)
                control_state_existing = logic_mapping_expanded[new_key]
                control_states = sort([control_state, control_state_existing])
                msg = "Multiple control states found for DiscreteControl node $node_id for truth state `$truth_state_new`: $control_states."
                @assert control_state_existing == control_state msg
            else
                logic_mapping_expanded[new_key] = control_state
            end
        end
    end
    return logic_mapping_expanded
end

"""Get all node fieldnames of the parameter object."""
nodefields(p::Parameters) = (
    name for
    name in fieldnames(typeof(p)) if fieldtype(typeof(p), name) <: AbstractParameterNode
)

"""
Get the node type specific indices of the fractional flows and basins,
that are consecutively connected to a node of given id.
"""
function get_fractional_flow_connected_basins(
    node_id::NodeID,
    basin::Basin,
    fractional_flow::FractionalFlow,
    graph::MetaGraph,
)::Tuple{Vector{Int}, Vector{Int}, Bool}
    fractional_flow_idxs = Int[]
    basin_idxs = Int[]

    has_fractional_flow_outneighbors = false

    for first_outneighbor_id in outflow_ids(graph, node_id)
        if first_outneighbor_id in fractional_flow.node_id
            has_fractional_flow_outneighbors = true
            second_outneighbor_id = outflow_id(graph, first_outneighbor_id)
            has_index, basin_idx = id_index(basin.node_id, second_outneighbor_id)
            if has_index
                push!(
                    fractional_flow_idxs,
                    searchsortedfirst(fractional_flow.node_id, first_outneighbor_id),
                )
                push!(basin_idxs, basin_idx)
            end
        end
    end
    return fractional_flow_idxs, basin_idxs, has_fractional_flow_outneighbors
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

"If id is a Basin with storage below the threshold, return a reduction factor != 1"
function low_storage_factor(
    storage::AbstractVector{T},
    basin_ids::Indices{NodeID},
    id::NodeID,
    threshold::Real,
)::T where {T <: Real}
    hasindex, basin_idx = id_index(basin_ids, id)
    return if hasindex
        reduction_factor(storage[basin_idx], threshold)
    else
        one(T)
    end
end

"""Whether the given node node is flow constraining by having a maximum flow rate."""
is_flow_constraining(node::AbstractParameterNode) = hasfield(typeof(node), :max_flow_rate)

"""Whether the given node is flow direction constraining (only in direction of edges)."""
is_flow_direction_constraining(node::AbstractParameterNode) =
    (nameof(typeof(node)) ∈ [:Pump, :Outlet, :TabulatedRatingCurve, :FractionalFlow])

"""Find out whether a path exists between a start node and end node in the given allocation graph."""
function allocation_path_exists_in_graph(
    graph::MetaGraph,
    start_node_id::NodeID,
    end_node_id::NodeID,
)::Bool
    node_ids_visited = Set{NodeID}()
    stack = [start_node_id]

    while !isempty(stack)
        current_node_id = pop!(stack)
        if current_node_id == end_node_id
            return true
        end
        if !(current_node_id in node_ids_visited)
            push!(node_ids_visited, current_node_id)
            for outneighbor_node_id in outflow_ids_allocation(graph, current_node_id)
                push!(stack, outneighbor_node_id)
            end
        end
    end
    return false
end

function has_main_network(allocation::Allocation)::Bool
    return first(allocation.allocation_network_ids) == 1
end

function is_main_network(allocation_network_id::Int)::Bool
    return allocation_network_id == 1
end

function get_user_demand(user::User, node_id::NodeID, priority_idx::Int)::Float64
    (; demand) = user
    user_idx = findsorted(user.node_id, node_id)
    n_priorities = length(user.priorities)
    return demand[(user_idx - 1) * n_priorities + priority_idx]
end

function set_user_demand!(
    user::User,
    node_id::NodeID,
    priority_idx::Int,
    value::Float64,
)::Nothing
    (; demand) = user
    user_idx = findsorted(user.node_id, node_id)
    n_priorities = length(user.priorities)
    demand[(user_idx - 1) * n_priorities + priority_idx] = value
    return nothing
end
