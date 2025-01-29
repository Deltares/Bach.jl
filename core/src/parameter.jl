
# Universal reduction factor threshold for the low storage factor
const LOW_STORAGE_THRESHOLD = 10.0

# Universal reduction factor threshold for the minimum upstream level of UserDemand nodes
const USER_DEMAND_MIN_LEVEL_THRESHOLD = 0.1

const SolverStats = @NamedTuple{
    time::Float64,
    rhs_calls::Int,
    linear_solves::Int,
    accepted_timesteps::Int,
    rejected_timesteps::Int,
}

# EdgeType.flow and NodeType.FlowBoundary
@enumx EdgeType flow control none
@eval @enumx NodeType $(config.nodetypes...)
@enumx ContinuousControlType None Continuous PID
@enumx Substance Continuity = 1 Initial = 2 LevelBoundary = 3 FlowBoundary = 4 UserDemand =
    5 Drainage = 6 Precipitation = 7
Base.to_index(id::Substance.T) = Int(id)  # used to index into concentration matrices

@generated function config.snake_case(nt::NodeType.T)
    ex = quote end
    for (sym, _) in EnumX.symbol_map(NodeType.T)
        sc = QuoteNode(config.snake_case(sym))
        t = NodeType.T(sym)
        push!(ex.args, :(nt === $t && return $sc))
    end
    push!(ex.args, :(return :nothing))  # type stability
    ex
end

# Support creating a NodeType enum instance from a symbol or string
function NodeType.T(s::Symbol)::NodeType.T
    symbol_map = EnumX.symbol_map(NodeType.T)
    for (sym, val) in symbol_map
        sym == s && return NodeType.T(val)
    end
    throw(ArgumentError("Invalid value for NodeType: $s"))
end

NodeType.T(str::AbstractString) = NodeType.T(Symbol(str))
NodeType.T(x::NodeType.T) = x
Base.convert(::Type{NodeType.T}, x::String) = NodeType.T(x)
Base.convert(::Type{NodeType.T}, x::Symbol) = NodeType.T(x)

SQLite.esc_id(x::NodeType.T) = esc_id(string(x))

"""
    NodeID(type::Union{NodeType.T, Symbol, AbstractString}, value::Integer, idx::Int)
    NodeID(type::Union{NodeType.T, Symbol, AbstractString}, value::Integer, p::Parameters)
    NodeID(type::Union{NodeType.T, Symbol, AbstractString}, value::Integer, node_ids::Vector{NodeID})

NodeID is a unique identifier for a node in the model, as well as an index into the internal node type struct.

The combination to the node type and ID is unique in the model.
The index is used to find the parameters of the node.
This index can be passed directly, or calculated from the database or parameters.
"""
@kwdef struct NodeID
    "Type of node, e.g. Basin, Pump, etc."
    type::NodeType.T
    "ID of node as given by users"
    value::Int32
    "Index into the internal node type struct."
    idx::Int
end

function NodeID(node_type, value::Integer, node_ids::Vector{NodeID})::NodeID
    node_type = NodeType.T(node_type)
    index = searchsortedfirst(node_ids, value; by = Int32)
    if index == lastindex(node_ids) + 1
        @error "Node ID $node_type #$value is not in the Node table."
        error("Node ID not found")
    end
    node_id = node_ids[index]
    if node_id.type !== node_type
        @error "Requested node ID #$value is of type $(node_id.type), not $node_type"
        error("Node ID is of the wrong type")
    end
    return node_id
end

function NodeID(value::Integer, node_ids::Vector{NodeID})::NodeID
    index = searchsortedfirst(node_ids, value; by = Int32)
    if index == lastindex(node_ids) + 1
        @error "Node ID #$value is not in the Node table."
        error("Node ID not found")
    end
    return node_ids[index]
end

Base.Int32(id::NodeID) = id.value
Base.convert(::Type{Int32}, id::NodeID) = id.value
Base.broadcastable(id::NodeID) = Ref(id)
Base.show(io::IO, id::NodeID) = print(io, id.type, " #", id.value)
config.snake_case(id::NodeID) = config.snake_case(id.type)
Base.to_index(id::NodeID) = Int(id.value)

# Compare only by value for working with a mix of integers from tables and processed NodeIDs
Base.:(==)(id_1::NodeID, id_2::NodeID) = id_1.value == id_2.value
Base.:(==)(id_1::Integer, id_2::NodeID) = id_1 == id_2.value
Base.:(==)(id_1::NodeID, id_2::Integer) = id_1.value == id_2

Base.isless(id_1::NodeID, id_2::NodeID)::Bool = id_1.value < id_2.value
Base.isless(id_1::Integer, id_2::NodeID)::Bool = id_1 < id_2.value
Base.isless(id_1::NodeID, id_2::Integer)::Bool = id_1.value < id_2

"ConstantInterpolation from a Float64 to a Float64"
const ScalarConstantInterpolation =
    ConstantInterpolation{Vector{Float64}, Vector{Float64}, Vector{Float64}, Float64, (1,)}

"LinearInterpolation from a Float64 to a Float64"
const ScalarInterpolation = LinearInterpolation{
    Vector{Float64},
    Vector{Float64},
    Vector{Float64},
    Vector{Float64},
    Float64,
    (1,),
}

"ConstantInterpolation from a Float64 to an Int, used to look up indices over time"
const IndexLookup =
    ConstantInterpolation{Vector{Int64}, Vector{Float64}, Vector{Float64}, Int64, (1,)}

set_zero!(v) = v .= zero(eltype(v))
const Cache = LazyBufferCache{Returns{Int}, typeof(set_zero!)}

"""
Cache for in place computations within water_balance!, with different eltypes
for different situations:
- Symbolics.Num for Jacobian sparsity detection
- ForwardDiff.Dual for automatic differentiation
- Float64 for normal calls

The caches are always initialized with zeros
"""
cache(len::Int)::Cache = LazyBufferCache(Returns(len); initializer! = set_zero!)

@enumx AllocationSourceType boundary_node basin main_to_sub user_return buffer

"""
Data structure for a single source within an allocation subnetwork.
edge: The outflow edge of the source
type: The type of source (edge, basin, main_to_sub, user_return, buffer)
capacity: The initial capacity of the source as determined by the physical layer
capacity_reduced: The capacity adjusted by passed optimizations
basin_flow_rate: The total outflow rate of a basin when optimized over all sources for one demand priority.
    Ignored when the source is not a basin.
"""
@kwdef mutable struct AllocationSource
    const edge::Tuple{NodeID, NodeID}
    const type::AllocationSourceType.T
    capacity::Float64 = 0.0
    capacity_reduced::Float64 = 0.0
    basin_flow_rate::Float64 = 0.0
end

function Base.show(io::IO, source::AllocationSource)
    (; edge, type) = source
    print(io, "AllocationSource of type $type at edge $edge")
end

"""
Store information for a subnetwork used for allocation.

subnetwork_id: The ID of this allocation network
capacity: The capacity per edge of the allocation network, as constrained by nodes that have a max_flow_rate
flow: The flows over all the edges in the subnetwork for a certain demand priority (used for allocation_flow output)
sources: source data in preferred order of optimization
problem: The JuMP.jl model for solving the allocation problem
Δt_allocation: The time interval between consecutive allocation solves
"""
@kwdef struct AllocationModel
    subnetwork_id::Int32
    capacity::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}}
    flow::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}}
    sources::OrderedDict{Tuple{NodeID, NodeID}, AllocationSource}
    problem::JuMP.Model
    Δt_allocation::Float64
end

"""
Object for all information about allocation
subnetwork_ids: The unique sorted allocation network IDs
allocation_models: The allocation models for the main network and subnetworks corresponding to
    subnetwork_ids
main_network_connections: (from_id, to_id) from the main network to the subnetwork per subnetwork
demand_priorities: All used demand priority values.
subnetwork_demands: The demand of an edge from the main network to a subnetwork
subnetwork_allocateds: The allocated flow of an edge from the main network to a subnetwork
mean_input_flows: Per subnetwork, flows averaged over Δt_allocation over edges that are allocation sources
mean_realized_flows: Flows averaged over Δt_allocation over edges that realize a demand
record_demand: A record of demands and allocated flows for nodes that have these
record_flow: A record of all flows computed by allocation optimization, eventually saved to
    output file
"""
@kwdef struct Allocation
    subnetwork_ids::Vector{Int32} = Int32[]
    allocation_models::Vector{AllocationModel} = AllocationModel[]
    main_network_connections::Vector{Vector{Tuple{NodeID, NodeID}}} =
        Vector{Tuple{NodeID, NodeID}}[]
    demand_priorities::Vector{Int32}
    subnetwork_demands::Dict{Tuple{NodeID, NodeID}, Vector{Float64}} = Dict()
    subnetwork_allocateds::Dict{Tuple{NodeID, NodeID}, Vector{Float64}} = Dict()
    mean_input_flows::Vector{Dict{Tuple{NodeID, NodeID}, Float64}}
    mean_realized_flows::Dict{Tuple{NodeID, NodeID}, Float64}
    record_demand::@NamedTuple{
        time::Vector{Float64},
        subnetwork_id::Vector{Int32},
        node_type::Vector{String},
        node_id::Vector{Int32},
        demand_priority::Vector{Int32},
        demand::Vector{Float64},
        allocated::Vector{Float64},
        realized::Vector{Float64},
    } = (;
        time = Float64[],
        subnetwork_id = Int32[],
        node_type = String[],
        node_id = Int32[],
        demand_priority = Int32[],
        demand = Float64[],
        allocated = Float64[],
        realized = Float64[],
    )
    record_flow::@NamedTuple{
        time::Vector{Float64},
        edge_id::Vector{Int32},
        from_node_type::Vector{String},
        from_node_id::Vector{Int32},
        to_node_type::Vector{String},
        to_node_id::Vector{Int32},
        subnetwork_id::Vector{Int32},
        demand_priority::Vector{Int32},
        flow_rate::Vector{Float64},
        optimization_type::Vector{String},
    } = (;
        time = Float64[],
        edge_id = Int32[],
        from_node_type = String[],
        from_node_id = Int32[],
        to_node_type = String[],
        to_node_id = Int32[],
        subnetwork_id = Int32[],
        demand_priority = Int32[],
        flow_rate = Float64[],
        optimization_type = String[],
    )
end

is_active(allocation::Allocation) = !isempty(allocation.allocation_models)

"""
Type for storing metadata of nodes in the graph
type: type of the node
subnetwork_id: Allocation network ID (0 if not in subnetwork)
"""
@kwdef struct NodeMetadata
    type::Symbol
    subnetwork_id::Int32
end

"""
Type for storing metadata of edges in the graph:
id: ID of the edge (only used for labeling flow output)
type: type of the edge
edge: (from node ID, to node ID)
"""
@kwdef struct EdgeMetadata
    id::Int32
    type::EdgeType.T
    edge::Tuple{NodeID, NodeID}
end

Base.length(::EdgeMetadata) = 1

"""
The update of a parameter given by a value and a reference to the target
location of the variable in memory
"""
struct ParameterUpdate{T}
    name::Symbol
    value::T
    ref::Base.RefArray{T, Vector{T}, Nothing}
end

function ParameterUpdate(name::Symbol, value::T)::ParameterUpdate{T} where {T}
    return ParameterUpdate(name, value, Ref(T[], 0))
end

"""
The parameter update associated with a certain control state for discrete control
"""
@kwdef struct ControlStateUpdate{T <: AbstractInterpolation}
    active::ParameterUpdate{Bool}
    scalar_update::Vector{ParameterUpdate{Float64}} = []
    itp_update::Vector{ParameterUpdate{T}} = ParameterUpdate{ScalarInterpolation}[]
end

"""
In-memory storage of saved mean flows for writing to results.

- `flow`: The mean flows on all edges and state-dependent forcings
- `inflow`: The sum of the mean flows coming into each Basin
- `outflow`: The sum of the mean flows going out of each Basin
- `flow_boundary`: The exact integrated mean flows of flow boundaries
- `precipitation`: The exact integrated mean precipitation
- `drainage`: The exact integrated mean drainage
- `concentration`: Concentrations for each Basin and substance
- `balance_error`: The (absolute) water balance error
- `relative_error`: The relative water balance error
- `t`: Endtime of the interval over which is averaged
"""
@kwdef struct SavedFlow{V}
    flow::V
    inflow::Vector{Float64}
    outflow::Vector{Float64}
    flow_boundary::Vector{Float64}
    precipitation::Vector{Float64}
    drainage::Vector{Float64}
    concentration::Matrix{Float64}
    storage_rate::Vector{Float64} = zero(precipitation)
    balance_error::Vector{Float64} = zero(precipitation)
    relative_error::Vector{Float64} = zero(precipitation)
    t::Float64
end

"""
In-memory storage of saved instantaneous storages and levels for writing to results.
"""
@kwdef struct SavedBasinState
    storage::Vector{Float64}
    level::Vector{Float64}
    t::Float64
end

abstract type AbstractParameterNode end

abstract type AbstractDemandNode <: AbstractParameterNode end

"""
Caches of current basin properties
"""
struct CurrentBasinProperties
    current_storage::Cache
    # Low storage factor for reducing flows out of drying basins
    # given the current storages
    current_low_storage_factor::Cache
    current_level::Cache
    current_area::Cache
    current_cumulative_precipitation::Cache
    current_cumulative_drainage::Cache
    function CurrentBasinProperties(n)
        new((cache(n) for _ in 1:6)...)
    end
end

@kwdef struct ConcentrationData
    # Config setting to enable/disable evaporation of mass
    evaporate_mass::Bool = true
    # Cumulative inflow for each Basin at a given time
    cumulative_in::Vector{Float64}
    # matrix with concentrations for each Basin and substance
    concentration_state::Matrix{Float64}  # Basin, substance
    # matrix with boundary concentrations for each boundary, Basin and substance
    concentration::Array{Float64, 3}
    # matrix with mass for each Basin and substance
    mass::Matrix{Float64}
    # substances in use by the model (ordered like their axis in the concentration matrices)
    substances::OrderedSet{Symbol}
    # Data source for external concentrations (used in control)
    concentration_external::Vector{Dict{String, ScalarInterpolation}} =
        Dict{String, ScalarInterpolation}[]
end

"""
Data source for Basin parameter updates over time

This is used for both static and dynamic values,
the length of each Vector is the number of Basins.
"""
@kwdef struct BasinForcing
    precipitation::Vector{ScalarConstantInterpolation} = ScalarConstantInterpolation[]
    potential_evaporation::Vector{ScalarConstantInterpolation} =
        ScalarConstantInterpolation[]
    drainage::Vector{ScalarConstantInterpolation} = ScalarConstantInterpolation[]
    infiltration::Vector{ScalarConstantInterpolation} = ScalarConstantInterpolation[]
end

"""Current values of the vertical fluxes in a Basin, per node ID.

Current forcing is stored as separate array for BMI access.
These are updated from BasinForcing at runtime.
"""
@kwdef struct VerticalFlux
    precipitation::Vector{Float64}
    potential_evaporation::Vector{Float64}
    drainage::Vector{Float64}
    infiltration::Vector{Float64}
end

VerticalFlux(n::Int) = VerticalFlux(zeros(n), zeros(n), zeros(n), zeros(n))

"""
Requirements:

* Must be positive: precipitation, evaporation, infiltration, drainage
* Index points to a Basin
* volume, area, level must all be positive and monotonic increasing.

Type parameter D indicates the content backing the StructVector, which can be a NamedTuple
of vectors or Arrow Tables, and is added to avoid type instabilities.
"""
@kwdef struct Basin{CD, D} <: AbstractParameterNode
    node_id::Vector{NodeID}
    inflow_ids::Vector{Vector{NodeID}} = [NodeID[]]
    outflow_ids::Vector{Vector{NodeID}} = [NodeID[]]
    # Vertical fluxes
    vertical_flux::VerticalFlux = VerticalFlux(length(node_id))
    # Initial_storage
    storage0::Vector{Float64} = zeros(length(node_id))
    # Storage at previous saveat without storage0
    Δstorage_prev_saveat::Vector{Float64} = zeros(length(node_id))
    # Analytically integrated forcings
    cumulative_precipitation::Vector{Float64} = zeros(length(node_id))
    cumulative_drainage::Vector{Float64} = zeros(length(node_id))
    cumulative_precipitation_saveat::Vector{Float64} = zeros(length(node_id))
    cumulative_drainage_saveat::Vector{Float64} = zeros(length(node_id))
    # Cache this to avoid recomputation
    current_properties::CurrentBasinProperties = CurrentBasinProperties(length(node_id))
    # Discrete values for interpolation
    storage_to_level::Vector{
        LinearInterpolationIntInv{
            Vector{Float64},
            Vector{Float64},
            ScalarInterpolation,
            Float64,
            (1,),
        },
    }
    level_to_area::Vector{ScalarInterpolation}
    # Values for allocation if applicable
    demand::Vector{Float64} = zeros(length(node_id))
    allocated::Vector{Float64} = zeros(length(node_id))
    forcing::BasinForcing = BasinForcing()
    # Storage for each Basin at the previous time step
    storage_prev::Vector{Float64} = zeros(length(node_id))
    # Level for each Basin at the previous time step
    level_prev::Vector{Float64} = zeros(length(node_id))
    # Concentrations
    concentration_data::CD = nothing
    # Data source for concentration updates
    concentration_time::StructVector{BasinConcentrationV1, D, Int}
end

"""
    struct TabulatedRatingCurve

Rating curve from level to flow rate. The rating curve is a lookup table with linear
interpolation in between. Relations can be updated in time.

node_id: node ID of the TabulatedRatingCurve node
inflow_edge: incoming flow edge metadata
    The ID of the destination node is always the ID of the TabulatedRatingCurve node
outflow_edge: outgoing flow edge metadata
    The ID of the source node is always the ID of the TabulatedRatingCurve node
active: whether this node is active and thus contributes flows
max_downstream_level: The downstream level above which the TabulatedRatingCurve flow goes to zero
interpolations: All Q(h) relationships for the nodes over time
current_interpolation_index: Per node 1 lookup from t to an index in `interpolations`
control_mapping: dictionary from (node_id, control_state) to Q(h) and/or active state
"""
@kwdef struct TabulatedRatingCurve <: AbstractParameterNode
    node_id::Vector{NodeID}
    inflow_edge::Vector{EdgeMetadata}
    outflow_edge::Vector{EdgeMetadata}
    active::Vector{Bool}
    max_downstream_level::Vector{Float64} = fill(Inf, length(node_id))
    interpolations::Vector{ScalarInterpolation}
    current_interpolation_index::Vector{IndexLookup}
    control_mapping::Dict{Tuple{NodeID, String}, ControlStateUpdate}
end

"""
node_id: node ID of the LinearResistance node
inflow_edge: incoming flow edge metadata
    The ID of the destination node is always the ID of the LinearResistance node
outflow_edge: outgoing flow edge metadata
    The ID of the source node is always the ID of the LinearResistance node
active: whether this node is active and thus contributes flows
resistance: the resistance to flow; `Q_unlimited = Δh/resistance`
max_flow_rate: the maximum flow rate allowed through the node; `Q = clamp(Q_unlimited, -max_flow_rate, max_flow_rate)`
control_mapping: dictionary from (node_id, control_state) to resistance and/or active state
"""
@kwdef struct LinearResistance <: AbstractParameterNode
    node_id::Vector{NodeID}
    inflow_edge::Vector{EdgeMetadata}
    outflow_edge::Vector{EdgeMetadata}
    active::Vector{Bool}
    resistance::Vector{Float64}
    max_flow_rate::Vector{Float64}
    control_mapping::Dict{Tuple{NodeID, String}, ControlStateUpdate}
end

"""
This is a simple Manning-Gauckler reach connection.

node_id: node ID of the ManningResistance node
inflow_edge: incoming flow edge metadata
    The ID of the destination node is always the ID of the ManningResistance node
outflow_edge: outgoing flow edge metadata
    The ID of the source node is always the ID of the ManningResistance node
length: reach length
manning_n: roughness; Manning's n in (SI units).

The profile is described by a trapezoid:

         \\            /  ^
          \\          /   |
           \\        /    | dz
    bottom  \\______/     |
    ^               <--->
    |                 dy
    |        <------>
    |          width
    |
    |
    + datum (e.g. MSL)

With `profile_slope = dy / dz`.
A rectangular profile requires a slope of 0.0.

Requirements:

* from: must be (Basin,) node
* to: must be (Basin,) node
* length > 0
* manning_n > 0
* profile_width >= 0
* profile_slope >= 0
* (profile_width == 0) xor (profile_slope == 0)
"""
@kwdef struct ManningResistance <: AbstractParameterNode
    node_id::Vector{NodeID}
    inflow_edge::Vector{EdgeMetadata}
    outflow_edge::Vector{EdgeMetadata}
    active::Vector{Bool}
    length::Vector{Float64}
    manning_n::Vector{Float64}
    profile_width::Vector{Float64}
    profile_slope::Vector{Float64}
    upstream_bottom::Vector{Float64}
    downstream_bottom::Vector{Float64}
    control_mapping::Dict{Tuple{NodeID, String}, ControlStateUpdate}
end

"""
node_id: node ID of the LevelBoundary node
active: whether this node is active
level: the fixed level of this 'infinitely big Basin'
concentration: matrix with boundary concentrations for each Basin and substance
concentration_time: Data source for concentration updates
"""
@kwdef struct LevelBoundary{C} <: AbstractParameterNode
    node_id::Vector{NodeID}
    active::Vector{Bool}
    level::Vector{ScalarInterpolation}
    concentration::Matrix{Float64}
    concentration_time::StructVector{LevelBoundaryConcentrationV1, C, Int}
end

"""
node_id: node ID of the FlowBoundary node
outflow_edges: The outgoing flow edge metadata
active: whether this node is active and thus contributes flow
cumulative_flow: The exactly integrated cumulative boundary flow since the start of the simulation
cumulative_flow_saveat: The exactly integrated cumulative boundary flow since the last saveat
flow_rate: flow rate (exact)
concentration: matrix with boundary concentrations for each Basin and substance
concentration_time: Data source for concentration updates
"""
@kwdef struct FlowBoundary{C} <: AbstractParameterNode
    node_id::Vector{NodeID}
    outflow_edges::Vector{Vector{EdgeMetadata}}
    active::Vector{Bool}
    cumulative_flow::Vector{Float64} = zeros(length(node_id))
    cumulative_flow_saveat::Vector{Float64} = zeros(length(node_id))
    flow_rate::Vector{ScalarInterpolation}
    concentration::Matrix{Float64}
    concentration_time::StructVector{FlowBoundaryConcentrationV1, C, Int}
end

"""
node_id: node ID of the Pump node
inflow_edge: incoming flow edge metadata
    The ID of the destination node is always the ID of the Pump node
outflow_edge: outgoing flow edge metadata
    The ID of the source node is always the ID of the Pump node
active: whether this node is active and thus contributes flow
flow_rate: target flow rate
min_flow_rate: The minimal flow rate of the pump
max_flow_rate: The maximum flow rate of the pump
min_upstream_level: The upstream level below which the Pump flow goes to zero
max_downstream_level: The downstream level above which the Pump flow goes to zero
control_mapping: dictionary from (node_id, control_state) to target flow rate
continuous_control_type: one of None, ContinuousControl, PidControl
"""
@kwdef struct Pump <: AbstractParameterNode
    node_id::Vector{NodeID}
    inflow_edge::Vector{EdgeMetadata} = []
    outflow_edge::Vector{EdgeMetadata} = []
    active::Vector{Bool} = fill(true, length(node_id))
    flow_rate::Cache = cache(length(node_id))
    min_flow_rate::Vector{Float64} = zeros(length(node_id))
    max_flow_rate::Vector{Float64} = fill(Inf, length(node_id))
    min_upstream_level::Vector{Float64} = fill(-Inf, length(node_id))
    max_downstream_level::Vector{Float64} = fill(Inf, length(node_id))
    control_mapping::Dict{Tuple{NodeID, String}, ControlStateUpdate}
    continuous_control_type::Vector{ContinuousControlType.T} =
        fill(ContinuousControlType.None, length(node_id))

    function Pump(
        node_id,
        inflow_edge,
        outflow_edge,
        active,
        flow_rate,
        min_flow_rate,
        max_flow_rate,
        min_upstream_level,
        max_downstream_level,
        control_mapping,
        continuous_control_type,
    )
        if valid_flow_rates(node_id, flow_rate[Float64[]], control_mapping)
            return new(
                node_id,
                inflow_edge,
                outflow_edge,
                active,
                flow_rate,
                min_flow_rate,
                max_flow_rate,
                min_upstream_level,
                max_downstream_level,
                control_mapping,
                continuous_control_type,
            )
        else
            error("Invalid Pump flow rate(s).")
        end
    end
end

"""
node_id: node ID of the Outlet node
inflow_edge: incoming flow edge metadata.
    The ID of the destination node is always the ID of the Outlet node
outflow_edge: outgoing flow edge metadata.
    The ID of the source node is always the ID of the Outlet node
active: whether this node is active and thus contributes flow
flow_rate: target flow rate
min_flow_rate: The minimal flow rate of the outlet
max_flow_rate: The maximum flow rate of the outlet
min_upstream_level: The upstream level below which the Outlet flow goes to zero
max_downstream_level: The downstream level above which the Outlet flow goes to zero
control_mapping: dictionary from (node_id, control_state) to target flow rate
continuous_control_type: one of None, ContinuousControl, PidControl
"""
@kwdef struct Outlet <: AbstractParameterNode
    node_id::Vector{NodeID}
    inflow_edge::Vector{EdgeMetadata} = []
    outflow_edge::Vector{EdgeMetadata} = []
    active::Vector{Bool} = fill(true, length(node_id))
    flow_rate::Cache = cache(length(node_id))
    min_flow_rate::Vector{Float64} = zeros(length(node_id))
    max_flow_rate::Vector{Float64} = fill(Inf, length(node_id))
    min_upstream_level::Vector{Float64} = fill(-Inf, length(node_id))
    max_downstream_level::Vector{Float64} = fill(Inf, length(node_id))
    control_mapping::Dict{Tuple{NodeID, String}, ControlStateUpdate} = Dict()
    continuous_control_type::Vector{ContinuousControlType.T} =
        fill(ContinuousControlType.None, length(node_id))

    function Outlet(
        node_id,
        inflow_edge,
        outflow_edge,
        active,
        flow_rate,
        min_flow_rate,
        max_flow_rate,
        min_upstream_level,
        max_downstream_level,
        control_mapping,
        continuous_control_type,
    )
        if valid_flow_rates(node_id, flow_rate[Float64[]], control_mapping)
            return new(
                node_id,
                inflow_edge,
                outflow_edge,
                active,
                flow_rate,
                min_flow_rate,
                max_flow_rate,
                min_upstream_level,
                max_downstream_level,
                control_mapping,
                continuous_control_type,
            )
        else
            error("Invalid Outlet flow rate(s).")
        end
    end
end

"""
node_id: node ID of the Terminal node
"""
@kwdef struct Terminal <: AbstractParameterNode
    node_id::Vector{NodeID}
end

"""
A variant on `Base.Ref` where the source array is a vector that is possibly wrapped in a ForwardDiff.LazyBufferCache,
or a reference to the state derivative vector du.
Retrieve value with get_value(ref::PreallocationRef, val) where `val` determines the return type.
"""
struct PreallocationRef
    vector::Cache
    idx::Int
    from_du::Bool
    function PreallocationRef(vector::Cache, idx::Int; from_du = false)
        new(vector, idx, from_du)
    end
end

get_value(ref::PreallocationRef, du) =
    ref.from_du ? du[ref.idx] : ref.vector[parent(du)][ref.idx]

function set_value!(ref::PreallocationRef, value, du)::Nothing
    ref.vector[parent(du)][ref.idx] = value
    return nothing
end

"""
The data for a single compound variable
node_id:: The ID of the DiscreteControl that listens to this variable
subvariables: data for one single subvariable
greater_than: the thresholds this compound variable will be
    compared against (in the case of DiscreteControl)
"""
@kwdef struct CompoundVariable
    node_id::NodeID
    subvariables::Vector{
        @NamedTuple{
            listen_node_id::NodeID,
            variable_ref::PreallocationRef,
            variable::String,
            weight::Float64,
            look_ahead::Float64,
        }
    }
    greater_than::Vector{Float64}
end

"""
node_id: node ID of the DiscreteControl node
controlled_nodes: The IDs of the nodes controlled by the DiscreteControl node
compound_variables: The compound variables the DiscreteControl node listens to
truth_state: Memory allocated for storing the truth state
control_state: The current control state of the DiscreteControl node
control_state_start: The start time of the  current control state
logic_mapping: Dictionary: truth state => control state for the DiscreteControl node
control_mapping: dictionary node type => control mapping for that node type
record: Namedtuple with discrete control information for results
"""
@kwdef struct DiscreteControl <: AbstractParameterNode
    node_id::Vector{NodeID}
    controlled_nodes::Vector{Vector{NodeID}}
    compound_variables::Vector{Vector{CompoundVariable}}
    truth_state::Vector{Vector{Bool}}
    control_state::Vector{String} = fill("undefined_state", length(node_id))
    control_state_start::Vector{Float64} = zeros(length(node_id))
    logic_mapping::Vector{Dict{Vector{Bool}, String}}
    control_mappings::Dict{NodeType.T, Dict{Tuple{NodeID, String}, ControlStateUpdate}} =
        Dict{NodeType.T, Dict{Tuple{NodeID, String}, ControlStateUpdate}}()
    record::@NamedTuple{
        time::Vector{Float64},
        control_node_id::Vector{Int32},
        truth_state::Vector{String},
        control_state::Vector{String},
    } = (;
        time = Float64[],
        control_node_id = Int32[],
        truth_state = String[],
        control_state = String[],
    )
end

@kwdef struct ContinuousControl <: AbstractParameterNode
    node_id::Vector{NodeID}
    compound_variable::Vector{CompoundVariable}
    controlled_variable::Vector{String}
    target_ref::Vector{PreallocationRef}
    func::Vector{ScalarInterpolation}
end

"""
PID control currently only supports regulating basin levels.

node_id: node ID of the PidControl node
active: whether this node is active and thus sets flow rates
controlled_node_id: The node that is being controlled
listen_node_id: the id of the basin being controlled
target: target level (possibly time dependent)
target_ref: reference to the controlled flow_rate value
proportional: proportionality coefficient error
integral: proportionality coefficient error integral
derivative: proportionality coefficient error derivative
error: the current error; basin_target - current_level
dictionary from (node_id, control_state) to target flow rate
"""
@kwdef struct PidControl <: AbstractParameterNode
    node_id::Vector{NodeID}
    active::Vector{Bool}
    listen_node_id::Vector{NodeID}
    target::Vector{ScalarInterpolation}
    target_ref::Vector{PreallocationRef}
    proportional::Vector{ScalarInterpolation}
    integral::Vector{ScalarInterpolation}
    derivative::Vector{ScalarInterpolation}
    error::Cache = cache(length(node_id))
    controlled_basins::Vector{NodeID}
    control_mapping::Dict{Tuple{NodeID, String}, ControlStateUpdate}
end

"""
node_id: node ID of the UserDemand node
inflow_edge: incoming flow edge
    The ID of the destination node is always the ID of the UserDemand node
outflow_edge: outgoing flow edge metadata
    The ID of the source node is always the ID of the UserDemand node
active: whether this node is active and thus demands water
demand: water flux demand of UserDemand per demand priority (node_idx, demand_priority_idx)
    Each UserDemand has a demand for all demand priorities,
    which is 0.0 if it is not provided explicitly.
demand_reduced: the total demand reduced by allocated flows. This is used for goal programming,
    and requires separate memory from `demand` since demands can come from the BMI
demand_itp: Timeseries interpolation objects for demands
demand_from_timeseries: If false the demand comes from the BMI or is fixed
allocated: water flux currently allocated to UserDemand per demand priority (node_idx, demand_priority_idx)
return_factor: the factor in [0,1] of how much of the abstracted water is given back to the system
min_level: The level of the source Basin below which the UserDemand does not abstract
concentration: matrix with boundary concentrations for each Basin and substance
concentration_time: Data source for concentration updates
"""
@kwdef struct UserDemand{C} <: AbstractDemandNode
    node_id::Vector{NodeID}
    inflow_edge::Vector{EdgeMetadata} = []
    outflow_edge::Vector{EdgeMetadata} = []
    active::Vector{Bool} = fill(true, length(node_id))
    demand::Matrix{Float64}
    demand_reduced::Matrix{Float64}
    demand_itp::Vector{Vector{ScalarInterpolation}}
    demand_from_timeseries::Vector{Bool}
    allocated::Matrix{Float64}
    return_factor::Vector{ScalarInterpolation}
    min_level::Vector{Float64}
    concentration::Matrix{Float64}
    concentration_time::StructVector{UserDemandConcentrationV1, C, Int}
end

"""
node_id: node ID of the LevelDemand node
min_level: The minimum target level of the connected basin(s)
max_level: The maximum target level of the connected basin(s)
demand_priority: If in a shortage state, the priority of the demand of the connected basin(s)
"""
@kwdef struct LevelDemand <: AbstractDemandNode
    node_id::Vector{NodeID}
    min_level::Vector{ScalarInterpolation} = fill(-Inf, length(node_id))
    max_level::Vector{ScalarInterpolation} = fill(Inf, length(node_id))
    demand_priority::Vector{Int32}
end

"""
node_id: node ID of the FlowDemand node
demand_itp: The time interpolation of the demand of the node
demand: The current demand of the node
demand_priority: The priority of the demand of the node
"""
@kwdef struct FlowDemand <: AbstractDemandNode
    node_id::Vector{NodeID}
    demand_itp::Vector{ScalarInterpolation}
    demand::Vector{Float64}
    demand_priority::Vector{Int32}
end

"Subgrid linearly interpolates basin levels."
@kwdef struct Subgrid
    # current level of each subgrid (static and dynamic) ordered by subgrid_id
    level::Vector{Float64}

    # Static part
    # Static subgrid ids
    subgrid_id_static::Vector{Int32}
    # index into the basin.current_level vector for each static subgrid_id
    basin_index_static::Vector{Int}
    # index into the subgrid.level vector for each static subgrid_id
    level_index_static::Vector{Int}
    # per subgrid one relation
    interpolations_static::Vector{ScalarInterpolation}

    # Dynamic part
    # Dynamic subgrid ids
    subgrid_id_time::Vector{Int32}
    # index into the basin.current_level vector for each dynamic subgrid_id
    basin_index_time::Vector{Int}
    # index into the subgrid.level vector for each dynamic subgrid_id
    level_index_time::Vector{Int}
    # per subgrid n relations, n being the number of timesteps for that subgrid
    interpolations_time::Vector{ScalarInterpolation}
    # per subgrid 1 lookup from t to an index in interpolations_time
    current_interpolation_index::Vector{IndexLookup}
end

"""
The metadata of the graph (the fields of the NamedTuple) can be accessed
    e.g. using graph[].flow.
node_ids: mapping subnetwork ID -> node IDs in that subnetwork
edges_source: mapping subnetwork ID -> metadata of allocation
    source edges in that subnetwork
flow_edges: The metadata of all flow edges
    of the flow over that edge
saveat: The time interval between saves of output data (storage, flow, ...)
"""
const ModelGraph = MetaGraph{
    Int64,
    DiGraph{Int64},
    NodeID,
    NodeMetadata,
    EdgeMetadata,
    @NamedTuple{
        node_ids::Dict{Int32, Set{NodeID}},
        flow_edges::Vector{EdgeMetadata},
        saveat::Float64,
    },
    MetaGraphsNext.var"#11#13",
    Float64,
}

@kwdef mutable struct Parameters{C3, C4, C6, C7, C8, C9, C10, C11}
    const starttime::DateTime
    const graph::ModelGraph
    const allocation::Allocation
    const basin::Basin{C3, C4}
    const linear_resistance::LinearResistance
    const manning_resistance::ManningResistance
    const tabulated_rating_curve::TabulatedRatingCurve
    const level_boundary::LevelBoundary{C6}
    const flow_boundary::FlowBoundary{C7}
    const pump::Pump
    const outlet::Outlet
    const terminal::Terminal
    const discrete_control::DiscreteControl
    const continuous_control::ContinuousControl
    const pid_control::PidControl
    const user_demand::UserDemand{C8}
    const level_demand::LevelDemand
    const flow_demand::FlowDemand
    const subgrid::Subgrid
    # Per state the in- and outflow edges associated with that state (if they exist)
    const state_inflow_edge::C9 = ComponentVector()
    const state_outflow_edge::C10 = ComponentVector()
    all_nodes_active::Bool = false
    tprev::Float64 = 0.0
    # Sparse matrix for combining flows into storages
    const flow_to_storage::SparseMatrixCSC{Float64, Int64} = spzeros(1, 1)
    # Water balance tolerances
    const water_balance_abstol::Float64
    const water_balance_reltol::Float64
    # State at previous saveat
    const u_prev_saveat::C11 = ComponentVector()
end

# To opt-out of type checking for ForwardDiff
function DiffEqBase.anyeltypedual(::Parameters, ::Type{Val{counter}}) where {counter}
    Any
end
