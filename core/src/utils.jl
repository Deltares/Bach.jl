"Return a directed graph, and a mapping from source and target nodes to edge fid."
function create_graph(
    db::DB,
    edge_type_::String,
)::Tuple{DiGraph, Dictionary{Tuple{Int, Int}, Int}, Dictionary{Int, Tuple{Symbol, Symbol}}}
    node_rows = execute(db, "select fid, type from Node")
    nodes = dictionary((fid => Symbol(type) for (; fid, type) in node_rows))
    graph = DiGraph(length(nodes))
    edge_rows = execute(db, "select fid, from_node_id, to_node_id, edge_type from Edge")
    edge_ids = Dictionary{Tuple{Int, Int}, Int}()
    edge_connection_types = Dictionary{Int, Tuple{Symbol, Symbol}}()
    for (; fid, from_node_id, to_node_id, edge_type) in edge_rows
        if edge_type == edge_type_
            add_edge!(graph, from_node_id, to_node_id)
            insert!(edge_ids, (from_node_id, to_node_id), fid)
            insert!(edge_connection_types, fid, (nodes[from_node_id], nodes[to_node_id]))
        end
    end
    return graph, edge_ids, edge_connection_types
end

"Calculate a profile storage by integrating the areas over the levels"
function profile_storage(levels::Vector{Float64}, areas::Vector{Float64})::Vector{Float64}
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

"Read the Basin / profile table and return all area and level and computed storage values"
function create_storage_tables(
    db::DB,
    config::Config,
)::Tuple{Vector{Vector{Float64}}, Vector{Vector{Float64}}, Vector{Vector{Float64}}}
    profiles = load_structvector(db, config, BasinProfileV1)
    area = Vector{Vector{Float64}}()
    level = Vector{Vector{Float64}}()
    storage = Vector{Vector{Float64}}()

    for group in IterTools.groupby(row -> row.node_id, profiles)
        group_area = getproperty.(group, :area)
        group_level = getproperty.(group, :level)
        group_storage = profile_storage(group_level, group_area)
        push!(area, group_area)
        push!(level, group_level)
        push!(storage, group_storage)
    end
    return area, level, storage
end

function get_area_and_level(
    basin::Basin,
    state_idx::Int,
    storage::Float64,
)::Tuple{Float64, Float64}
    storage_discrete = basin.storage[state_idx]
    area_discrete = basin.area[state_idx]
    level_discrete = basin.level[state_idx]

    return get_area_and_level(storage_discrete, area_discrete, level_discrete, storage)
end

function get_area_and_level(
    storage_discrete::Vector{Float64},
    area_discrete::Vector{Float64},
    level_discrete::Vector{Float64},
    storage::Float64,
)::Tuple{Float64, Float64}
    # storage_idx: smallest index such that storage_discrete[storage_idx] >= storage
    storage_idx = searchsortedfirst(storage_discrete, storage)

    if storage_idx == 1
        # This can only happen if the storage is 0
        level = level_discrete[1]
        area = area_discrete[1]

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
            area = area_lower
            level =
                level_higher +
                level_diff * (storage - storage_higher) / (storage_higher - storage_lower)
        else
            area = sqrt(
                area_higher^2 + 2 * (storage - storage_higher) * area_diff / level_diff,
            )
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
            area = area_lower
            level =
                level_lower +
                level_diff * (storage - storage_lower) / (storage_higher - storage_lower)

        else
            area =
                sqrt(area_lower^2 + 2 * (storage - storage_lower) * area_diff / level_diff)
            level = level_lower + level_diff * (area - area_lower) / area_diff
        end
    end

    return area, level
end

"""
For an element `id` and a vector of elements `ids`, get the range of indices of the last
consecutive block of `id`.
Returns the empty range `1:0` if `id` is not in `ids`.

```
#                  1 2 3 4 5 6 7 8 9
findlastgroup(2, [5,4,2,2,5,2,2,2,1])  # -> 6:8
```
"""
function findlastgroup(id::Int, ids::AbstractVector{Int})::UnitRange{Int}
    idx_block_end = findlast(==(id), ids)
    if isnothing(idx_block_end)
        return 1:0
    end
    idx_block_begin = findprev(!=(id), ids, idx_block_end)
    idx_block_begin = if isnothing(idx_block_begin)
        1
    else
        # can happen if that if id is the only ID in ids
        idx_block_begin + 1
    end
    return idx_block_begin:idx_block_end
end

function qh_interpolation(
    level::AbstractVector,
    discharge::AbstractVector,
)::Tuple{LinearInterpolation, Bool}
    return LinearInterpolation(discharge, level), allunique(level)
end

"""
From a table with columns node_id, discharge (Q) and level (h),
create a LinearInterpolation from level to discharge for a given node_id.
"""
function qh_interpolation(
    node_id::Int,
    table::StructVector,
)::Tuple{LinearInterpolation, Bool}
    rowrange = findlastgroup(node_id, table.node_id)
    @assert !isempty(rowrange) "timeseries starts after model start time"
    return qh_interpolation(table.level[rowrange], table.discharge[rowrange])
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
If a value is NaN, it is not set.
"""
function set_table_row!(table::NamedTuple, row, i::Int)::NamedTuple
    for (symbol, vector) in pairs(table)
        val = getproperty(row, symbol)
        if !isnan(val)
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
        isnothing(idx) && continue
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
                row -> row.node_id == id && !isnan(getproperty(row, symbol)),
                pre_table,
            )
            if !isnothing(idx)
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
"""
function get_level(p::Parameters, node_id::Int)::Float64
    (; basin, level_boundary) = p
    # since the node_id fields are already Indices, Dictionary creation is instant
    basin = Dictionary(basin.node_id, basin.current_level)
    hasindex, token = gettoken(basin, node_id)
    return if hasindex
        gettokenvalue(basin, token)
    else
        boundary = Dictionary(level_boundary.node_id, level_boundary.level)
        boundary[node_id]
    end
end

"Get the index of an ID in a set of indices."
function id_index(ids::Indices{Int}, id::Int)
    # There might be a better approach for this, this feels too internal
    # the second return is the token, a Tuple{Int, Int}
    hasindex, (_, idx) = gettoken(ids, id)
    return hasindex, idx
end

"Return the bottom elevation of the basin with index i, or nothing if it doesn't exist"
function basin_bottom(basin::Basin, node_id::Int)::Union{Float64, Nothing}
    basin = Dictionary(basin.node_id, basin.level)
    hasindex, token = gettoken(basin, node_id)
    return if hasindex
        # get level(storage) interpolation function
        level_discrete = gettokenvalue(basin, token)
        # and return the first level in this vector, representing the bottom
        first(level_discrete)
    else
        nothing
    end
end

"Get the bottom on both ends of a node. If only one has a bottom, use that for both."
function basin_bottoms(
    basin::Basin,
    basin_a_id::Int,
    basin_b_id::Int,
    id::Int,
)::Tuple{Float64, Float64}
    bottom_a = basin_bottom(basin, basin_a_id)
    bottom_b = basin_bottom(basin, basin_b_id)
    if isnothing(bottom_a) && isnothing(bottom_b)
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
    logic_mapping::Dict{Tuple{Int, String}, String},
)::Dict{Tuple{Int, String}, String}
    logic_mapping_expanded = Dict{Tuple{Int, String}, String}()

    for (node_id, truth_state) in keys(logic_mapping)
        pattern = r"^[TF\*]+$"
        msg = "Truth state \'$truth_state\' contains illegal characters or is empty."
        @assert occursin(pattern, truth_state) msg

        control_state = logic_mapping[(node_id, truth_state)]
        n_wildcards = count(==('*'), truth_state)

        if n_wildcards > 0

            # Loop over all substitution sets for the wildcards
            for substitution in Iterators.product(fill(['T', 'F'], n_wildcards)...)
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
                    msg = "Multiple control states found for DiscreteControl node #$node_id for truth state `$truth_state_new`: $control_state, $control_state_existing."
                    @assert control_state_existing == control_state msg
                else
                    logic_mapping_expanded[new_key] = control_state
                end
            end
        else
            logic_mapping_expanded[(node_id, truth_state)] = control_state
        end
    end
    return logic_mapping_expanded
end
