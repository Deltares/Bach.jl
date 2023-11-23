# These schemas define the name of database tables and the configuration file structure
# The identifier is parsed as ribasim.nodetype.kind, no capitals or underscores are allowed.
@schema "ribasim.node" Node
@schema "ribasim.edge" Edge
@schema "ribasim.discretecontrol.condition" DiscreteControlCondition
@schema "ribasim.discretecontrol.logic" DiscreteControlLogic
@schema "ribasim.basin.static" BasinStatic
@schema "ribasim.basin.time" BasinTime
@schema "ribasim.basin.profile" BasinProfile
@schema "ribasim.basin.state" BasinState
@schema "ribasim.terminal.static" TerminalStatic
@schema "ribasim.fractionalflow.static" FractionalFlowStatic
@schema "ribasim.flowboundary.static" FlowBoundaryStatic
@schema "ribasim.flowboundary.time" FlowBoundaryTime
@schema "ribasim.levelboundary.static" LevelBoundaryStatic
@schema "ribasim.levelboundary.time" LevelBoundaryTime
@schema "ribasim.linearresistance.static" LinearResistanceStatic
@schema "ribasim.manningresistance.static" ManningResistanceStatic
@schema "ribasim.pidcontrol.static" PidControlStatic
@schema "ribasim.pidcontrol.time" PidControlTime
@schema "ribasim.pump.static" PumpStatic
@schema "ribasim.tabulatedratingcurve.static" TabulatedRatingCurveStatic
@schema "ribasim.tabulatedratingcurve.time" TabulatedRatingCurveTime
@schema "ribasim.outlet.static" OutletStatic
@schema "ribasim.user.static" UserStatic
@schema "ribasim.user.time" UserTime

const delimiter = " / "
tablename(sv::Type{SchemaVersion{T, N}}) where {T, N} = tablename(sv())
tablename(sv::SchemaVersion{T, N}) where {T, N} =
    join(filter(!isnothing, nodetype(sv)), delimiter)
isnode(sv::Type{SchemaVersion{T, N}}) where {T, N} = isnode(sv())
isnode(::SchemaVersion{T, N}) where {T, N} = length(split(string(T), ".")) == 3
nodetype(sv::Type{SchemaVersion{T, N}}) where {T, N} = nodetype(sv())

"""
From a SchemaVersion("ribasim.flowboundary.static", 1) return (:FlowBoundary, :static)
"""
function nodetype(
    sv::SchemaVersion{T, N},
)::Tuple{Symbol, Union{Nothing, Symbol}} where {T, N}
    # Names derived from a schema are in underscores (basintime),
    # so we parse the related record Ribasim.BasinTimeV1
    # to derive BasinTime from it.
    record = Legolas.record_type(sv)
    node = last(split(string(Symbol(record)), "."))

    elements = split(string(T), ".")
    if isnode(sv)
        n = elements[2]
        k = Symbol(elements[3])
    else
        n = last(elements)
        k = nothing
    end

    return Symbol(node[begin:length(n)]), k
end

# Allowed types for downstream (to_node_id) nodes given the type of the upstream (from_node_id) node
neighbortypes(nodetype::Symbol) = neighbortypes(Val(nodetype))
neighbortypes(::Val{:pump}) = Set((:basin, :fractional_flow, :terminal, :level_boundary))
neighbortypes(::Val{:outlet}) = Set((:basin, :fractional_flow, :terminal, :level_boundary))
neighbortypes(::Val{:user}) = Set((:basin, :fractional_flow, :terminal, :level_boundary))
neighbortypes(::Val{:basin}) = Set((
    :linear_resistance,
    :tabulated_rating_curve,
    :manning_resistance,
    :pump,
    :outlet,
    :user,
))
neighbortypes(::Val{:terminal}) = Set{Symbol}() # only endnode
neighbortypes(::Val{:fractional_flow}) = Set((:basin, :terminal, :level_boundary))
neighbortypes(::Val{:flow_boundary}) =
    Set((:basin, :fractional_flow, :terminal, :level_boundary))
neighbortypes(::Val{:level_boundary}) =
    Set((:linear_resistance, :manning_resistance, :pump, :outlet))
neighbortypes(::Val{:linear_resistance}) = Set((:basin, :level_boundary))
neighbortypes(::Val{:manning_resistance}) = Set((:basin, :level_boundary))
neighbortypes(::Val{:discrete_control}) = Set((
    :pump,
    :outlet,
    :tabulated_rating_curve,
    :linear_resistance,
    :manning_resistance,
    :fractioal_flow,
    :pid_control,
))
neighbortypes(::Val{:pid_control}) = Set((:pump, :outlet))
neighbortypes(::Val{:tabulated_rating_curve}) =
    Set((:basin, :fractional_flow, :terminal, :level_boundary))
neighbortypes(::Any) = Set{Symbol}()

# Allowed number of inneighbors and outneighbors per node type
struct n_neighbor_bounds
    in_min::Int
    in_max::Int
    out_min::Int
    out_max::Int
end

n_neighbor_bounds_flow(nodetype::Symbol) = n_neighbor_bounds_flow(Val(nodetype))
n_neighbor_bounds_flow(::Val{:Basin}) = n_neighbor_bounds(0, typemax(Int), 0, typemax(Int))
n_neighbor_bounds_flow(::Val{:LinearResistance}) = n_neighbor_bounds(1, 1, 1, typemax(Int))
n_neighbor_bounds_flow(::Val{:ManningResistance}) = n_neighbor_bounds(1, 1, 1, typemax(Int))
n_neighbor_bounds_flow(::Val{:TabulatedRatingCurve}) =
    n_neighbor_bounds(1, 1, 1, typemax(Int))
n_neighbor_bounds_flow(::Val{:FractionalFlow}) = n_neighbor_bounds(1, 1, 1, 1)
n_neighbor_bounds_flow(::Val{:LevelBoundary}) =
    n_neighbor_bounds(0, typemax(Int), 0, typemax(Int))
n_neighbor_bounds_flow(::Val{:FlowBoundary}) = n_neighbor_bounds(0, 0, 1, typemax(Int))
n_neighbor_bounds_flow(::Val{:Pump}) = n_neighbor_bounds(1, 1, 1, typemax(Int))
n_neighbor_bounds_flow(::Val{:Outlet}) = n_neighbor_bounds(1, 1, 1, typemax(Int))
n_neighbor_bounds_flow(::Val{:Terminal}) = n_neighbor_bounds(1, typemax(Int), 0, 0)
n_neighbor_bounds_flow(::Val{:PidControl}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_flow(::Val{:DiscreteControl}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_flow(::Val{:User}) = n_neighbor_bounds(1, 1, 1, 1)
n_neighbor_bounds_flow(nodetype) =
    error("'n_neighbor_bounds_flow' not defined for $nodetype.")

n_neighbor_bounds_control(nodetype::Symbol) = n_neighbor_bounds_control(Val(nodetype))
n_neighbor_bounds_control(::Val{:Basin}) = n_neighbor_bounds(0, 0, 0, typemax(Int))
n_neighbor_bounds_control(::Val{:LinearResistance}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:ManningResistance}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:TabulatedRatingCurve}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:FractionalFlow}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:LevelBoundary}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_control(::Val{:FlowBoundary}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_control(::Val{:Pump}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:Outlet}) = n_neighbor_bounds(0, 1, 0, 0)
n_neighbor_bounds_control(::Val{:Terminal}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_control(::Val{:PidControl}) = n_neighbor_bounds(0, 1, 1, 1)
n_neighbor_bounds_control(::Val{:DiscreteControl}) =
    n_neighbor_bounds(0, 0, 1, typemax(Int))
n_neighbor_bounds_control(::Val{:User}) = n_neighbor_bounds(0, 0, 0, 0)
n_neighbor_bounds_control(nodetype) =
    error("'n_neighbor_bounds_control' not defined for $nodetype.")

@version NodeV1 begin
    fid::Int
    name::String = isnothing(s) ? "" : String(s)
    type::String = in(Symbol(type), nodetypes) ? type : error("Unknown node type $type")
    allocation_network_id::Union{Missing, Int}
end

@version EdgeV1 begin
    fid::Int
    name::String = isnothing(s) ? "" : String(s)
    from_node_id::Int
    to_node_id::Int
    edge_type::String
    allocation_network_id::Union{Missing, Int}
end

@version PumpStaticV1 begin
    node_id::Int
    active::Union{Missing, Bool}
    flow_rate::Float64
    min_flow_rate::Union{Missing, Float64}
    max_flow_rate::Union{Missing, Float64}
    control_state::Union{Missing, String}
end

@version OutletStaticV1 begin
    node_id::Int
    active::Union{Missing, Bool}
    flow_rate::Float64
    min_flow_rate::Union{Missing, Float64}
    max_flow_rate::Union{Missing, Float64}
    min_crest_level::Union{Missing, Float64}
    control_state::Union{Missing, String}
end

@version BasinStaticV1 begin
    node_id::Int
    drainage::Float64
    potential_evaporation::Float64
    infiltration::Float64
    precipitation::Float64
    urban_runoff::Float64
end

@version BasinTimeV1 begin
    node_id::Int
    time::DateTime
    drainage::Float64
    potential_evaporation::Float64
    infiltration::Float64
    precipitation::Float64
    urban_runoff::Float64
end

@version BasinProfileV1 begin
    node_id::Int
    area::Float64
    level::Float64
end

@version BasinStateV1 begin
    node_id::Int
    level::Float64
end

@version FractionalFlowStaticV1 begin
    node_id::Int
    fraction::Float64
    control_state::Union{Missing, String}
end

@version LevelBoundaryStaticV1 begin
    node_id::Int
    active::Union{Missing, Bool}
    level::Float64
end

@version LevelBoundaryTimeV1 begin
    node_id::Int
    time::DateTime
    level::Float64
end

@version FlowBoundaryStaticV1 begin
    node_id::Int
    active::Union{Missing, Bool}
    flow_rate::Float64
end

@version FlowBoundaryTimeV1 begin
    node_id::Int
    time::DateTime
    flow_rate::Float64
end

@version LinearResistanceStaticV1 begin
    node_id::Int
    active::Union{Missing, Bool}
    resistance::Float64
    control_state::Union{Missing, String}
end

@version ManningResistanceStaticV1 begin
    node_id::Int
    active::Union{Missing, Bool}
    length::Float64
    manning_n::Float64
    profile_width::Float64
    profile_slope::Float64
    control_state::Union{Missing, String}
end

@version TabulatedRatingCurveStaticV1 begin
    node_id::Int
    active::Union{Missing, Bool}
    level::Float64
    discharge::Float64
    control_state::Union{Missing, String}
end

@version TabulatedRatingCurveTimeV1 begin
    node_id::Int
    time::DateTime
    level::Float64
    discharge::Float64
end

@version TerminalStaticV1 begin
    node_id::Int
end

@version DiscreteControlConditionV1 begin
    node_id::Int
    listen_feature_id::Int
    variable::String
    greater_than::Float64
    look_ahead::Union{Missing, Float64}
end

@version DiscreteControlLogicV1 begin
    node_id::Int
    truth_state::String
    control_state::String
end

@version PidControlStaticV1 begin
    node_id::Int
    active::Union{Missing, Bool}
    listen_node_id::Int
    target::Float64
    proportional::Float64
    integral::Float64
    derivative::Float64
    control_state::Union{Missing, String}
end

@version PidControlTimeV1 begin
    node_id::Int
    listen_node_id::Int
    time::DateTime
    target::Float64
    proportional::Float64
    integral::Float64
    derivative::Float64
    control_state::Union{Missing, String}
end

@version UserStaticV1 begin
    node_id::Int
    active::Union{Missing, Bool}
    demand::Float64
    return_factor::Float64
    min_level::Float64
    priority::Int
end

@version UserTimeV1 begin
    node_id::Int
    time::DateTime
    demand::Float64
    return_factor::Float64
    min_level::Float64
    priority::Int
end

function variable_names(s::Any)
    filter(x -> !(x in (:node_id, :control_state)), fieldnames(s))
end
function variable_nt(s::Any)
    names = variable_names(typeof(s))
    NamedTuple{names}((getfield(s, x) for x in names))
end

function is_consistent(node, edge, state, static, profile, time)

    # Check that node ids exist
    # TODO Do we need to check the reverse as well? All ids in use?
    ids = node.fid
    @assert edge.from_node_id ⊆ ids "Edge from_node_id not in node ids"
    @assert edge.to_node_id ⊆ ids "Edge to_node_id not in node ids"
    @assert state.node_id ⊆ ids "State id not in node ids"
    @assert static.node_id ⊆ ids "Static id not in node ids"
    @assert profile.node_id ⊆ ids "Profile id not in node ids"
    @assert time.node_id ⊆ ids "Time id not in node ids"

    # Check edges for uniqueness
    @assert allunique(edge, [:from_node_id, :to_node_id]) "Duplicate edge found"

    # TODO Check states

    # TODO Check statics

    # TODO Check forcings

    true
end

# functions used by sort(x; by)
sort_by_fid(row) = row.fid
sort_by_id(row) = row.node_id
sort_by_time_id(row) = (row.time, row.node_id)
sort_by_id_level(row) = (row.node_id, row.level)
sort_by_id_state_level(row) = (row.node_id, row.control_state, row.level)
sort_by_priority(row) = (row.node_id, row.priority)
sort_by_priority_time(row) = (row.node_id, row.priority, row.time)

# get the right sort by function given the Schema, with sort_by_id as the default
sort_by_function(table::StructVector{<:Legolas.AbstractRecord}) = sort_by_id
sort_by_function(table::StructVector{NodeV1}) = sort_by_fid
sort_by_function(table::StructVector{EdgeV1}) = sort_by_fid
sort_by_function(table::StructVector{TabulatedRatingCurveStaticV1}) = sort_by_id_state_level
sort_by_function(table::StructVector{BasinProfileV1}) = sort_by_id_level
sort_by_function(table::StructVector{UserStaticV1}) = sort_by_priority
sort_by_function(table::StructVector{UserTimeV1}) = sort_by_priority_time

const TimeSchemas = Union{
    BasinTimeV1,
    FlowBoundaryTimeV1,
    LevelBoundaryTimeV1,
    PidControlTimeV1,
    TabulatedRatingCurveTimeV1,
    UserTimeV1,
}

function sort_by_function(table::StructVector{<:TimeSchemas})
    return sort_by_time_id
end

"""
Depending on if a table can be sorted, either sort it or assert that it is sorted.

Tables loaded from the database into memory can be sorted.
Tables loaded from Arrow files are memory mapped and can therefore not be sorted.
"""
function sorted_table!(
    table::StructVector{<:Legolas.AbstractRecord},
)::StructVector{<:Legolas.AbstractRecord}
    by = sort_by_function(table)
    if any((typeof(col) <: Arrow.Primitive for col in Tables.columns(table)))
        et = eltype(table)
        if !issorted(table; by)
            error("Arrow table for $et not sorted as required.")
        end
    else
        sort!(table; by)
    end
    return table
end

struct NodeID
    value::Int
end

Base.convert(::Type{NodeID}, value::Int) = NodeID(value)
Base.broadcastable(id::NodeID) = Ref(id)
Base.show(io::IO, id::NodeID) = print(io, '#', id.value)

function Base.isless(id_1::NodeID, id_2::NodeID)::Bool
    return id_1.value < id_2.value
end

function Base.getindex(M::AbstractArray, id_row::NodeID, id_col::NodeID)
    return M[id_row.value, id_col.value]
end

function Base.setindex!(
    M::AbstractArray,
    value::T,
    id_row::NodeID,
    id_col::NodeID,
)::Nothing where {T}
    M[id_row.value, id_col.value] = value
    return nothing
end

"""
Test for each node given its node type whether the nodes that
# are downstream ('down-edge') of this node are of an allowed type
"""
function valid_edges(graph::MetaGraph)::Bool
    errors = false
    for e in edges(graph)
        id_src = label_for(graph, e.src)
        id_dst = label_for(graph, e.dst)
        type_src = graph[id_src].type
        type_dst = graph[id_dst].type

        if !(type_dst in neighbortypes(type_src))
            errors = true
            edge_id = graph[id_src, id_dst].id.value
            @error "Cannot connect a $type_src to a $type_dst (edge #$edge_id from node $id_src to $id_dst)."
        end
    end
    return !errors
end

"""
Check whether the profile data has no repeats in the levels and the areas start positive.
"""
function valid_profiles(
    node_id::Indices{NodeID},
    level::Vector{Vector{Float64}},
    area::Vector{Vector{Float64}},
)::Vector{String}
    errors = String[]

    for (id, levels, areas) in zip(node_id, level, area)
        if !allunique(levels)
            push!(errors, "Basin $id has repeated levels, this cannot be interpolated.")
        end

        if areas[1] <= 0
            push!(
                errors,
                "Basin profiles cannot start with area <= 0 at the bottom for numerical reasons (got area $(areas[1]) for node $id).",
            )
        end

        if areas[end] < areas[end - 1]
            push!(
                errors,
                "Basin profiles cannot have decreasing area at the top since extrapolating could lead to negative areas, found decreasing top areas for node $id.",
            )
        end
    end
    return errors
end

"""
Test whether static or discrete controlled flow rates are indeed non-negative.
"""
function valid_flow_rates(
    node_id::Vector{NodeID},
    flow_rate::Vector,
    control_mapping::Dict{Tuple{NodeID, String}, NamedTuple},
    node_type::Symbol,
)::Bool
    errors = false

    # Collect ids of discrete controlled nodes so that they do not give another error
    # if their initial value is also invalid.
    ids_controlled = NodeID[]

    for (key, control_values) in pairs(control_mapping)
        id_controlled = key[1]
        push!(ids_controlled, id_controlled)
        flow_rate_ = get(control_values, :flow_rate, 1)

        if flow_rate_ < 0.0
            errors = true
            control_state = key[2]
            @error "$node_type flow rates must be non-negative, found $flow_rate_ for control state '$control_state' of $id_controlled."
        end
    end

    for (id, flow_rate_) in zip(node_id, flow_rate)
        if id in ids_controlled
            continue
        end
        if flow_rate_ < 0.0
            errors = true
            @error "$node_type flow rates must be non-negative, found $flow_rate_ for static $id."
        end
    end

    return !errors
end

function valid_pid_connectivity(
    pid_control_node_id::Vector{NodeID},
    pid_control_listen_node_id::Vector{NodeID},
    graph::MetaGraph,
    basin_node_id::Indices{NodeID},
    pump_node_id::Vector{NodeID},
)::Bool
    errors = false

    for (id, listen_id) in zip(pid_control_node_id, pid_control_listen_node_id)
        has_index, _ = id_index(basin_node_id, listen_id)
        if !has_index
            @error "Listen node $listen_id of PidControl node $id is not a Basin"
            errors = true
        end

        controlled_id = only(outneighbor_labels_type(graph, id, EdgeType.control))

        if controlled_id in pump_node_id
            pump_intake_id = inflow_id(graph, controlled_id)
            if pump_intake_id != listen_id
                @error "Listen node $listen_id of PidControl node $id is not upstream of controlled pump $controlled_id"
                errors = true
            end
        else
            outlet_outflow_id = outflow_id(graph, controlled_id)
            if outlet_outflow_id != listen_id
                @error "Listen node $listen_id of PidControl node $id is not downstream of controlled outlet $controlled_id"
                errors = true
            end
        end
    end

    return !errors
end

"""
Check that nodes that have fractional flow outneighbors do not have any other type of
outneighbor, that the fractions leaving a node add up to ≈1 and that the fractions are non-negative.
"""
function valid_fractional_flow(
    graph::MetaGraph,
    node_id::Vector{NodeID},
    control_mapping::Dict{Tuple{NodeID, String}, NamedTuple},
)::Bool
    errors = false

    # Node IDs that have fractional flow outneighbors
    src_ids = Set{NodeID}()

    for id in node_id
        union!(src_ids, inneighbor_labels(graph, id))
    end

    node_id_set = Set{NodeID}(node_id)
    control_states = Set{String}([key[2] for key in keys(control_mapping)])

    for src_id in src_ids
        src_outneighbor_ids = Set(outneighbor_labels(graph, src_id))
        if src_outneighbor_ids ⊈ node_id
            errors = true
            @error(
                "Node $src_id combines fractional flow outneighbors with other outneigbor types."
            )
        end

        # Each control state (including missing) must sum to 1
        for control_state in control_states
            fraction_sum = 0.0

            for ff_id in intersect(src_outneighbor_ids, node_id_set)
                parameter_values = get(control_mapping, (ff_id, control_state), nothing)
                if parameter_values === nothing
                    continue
                else
                    (; fraction) = parameter_values
                end

                fraction_sum += fraction

                if fraction < 0
                    errors = true
                    @error(
                        "Fractional flow nodes must have non-negative fractions.",
                        fraction,
                        node_id = ff_id,
                        control_state,
                    )
                end
            end

            if !(fraction_sum ≈ 1)
                errors = true
                @error(
                    "The sum of fractional flow fractions leaving a node must be ≈1.",
                    fraction_sum,
                    node_id = src_id,
                    control_state,
                )
            end
        end
    end
    return !errors
end
