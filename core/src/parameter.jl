# EdgeType.flow and NodeType.FlowBoundary
@enumx EdgeType flow control none
@eval @enumx NodeType $(config.nodetypes...)
@enumx ContinuousControlType None Continuous PID

# Support creating a NodeType enum instance from a symbol or string
function NodeType.T(s::Symbol)::NodeType.T
    symbol_map = EnumX.symbol_map(NodeType.T)
    for (sym, val) in symbol_map
        sym == s && return NodeType.T(val)
    end
    throw(ArgumentError("Invalid value for NodeType: $s"))
end

NodeType.T(str::AbstractString) = NodeType.T(Symbol(str))

"""
    NodeID(type::Union{NodeType.T, Symbol, AbstractString}, value::Integer, idx::Int)
    NodeID(type::Union{NodeType.T, Symbol, AbstractString}, value::Integer, db::DB)
    NodeID(type::Union{NodeType.T, Symbol, AbstractString}, value::Integer, p::Parameters)

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

NodeID(type::Symbol, value::Integer, idx::Int) = NodeID(NodeType.T(type), value, idx)
NodeID(type::AbstractString, value::Integer, idx::Int) =
    NodeID(NodeType.T(type), value, idx)

function NodeID(type::Union{Symbol, AbstractString}, value::Integer, db::DB)::NodeID
    return NodeID(NodeType.T(type), value, db)
end

function NodeID(type::NodeType.T, value::Integer, db::DB)::NodeID
    node_type_string = string(type)
    # The index is equal to the number of nodes of the same type with a lower or equal ID
    idx = only(
        only(
            execute(
                columntable,
                db,
                "SELECT COUNT(*) FROM Node WHERE node_type == $(esc_id(node_type_string)) AND node_id <= $value",
            ),
        ),
    )
    @assert idx > 0
    return NodeID(type, value, idx)
end

Base.Int32(id::NodeID) = id.value
Base.convert(::Type{Int32}, id::NodeID) = id.value
Base.broadcastable(id::NodeID) = Ref(id)
Base.:(==)(id_1::NodeID, id_2::NodeID) = id_1.type == id_2.type && id_1.value == id_2.value
Base.show(io::IO, id::NodeID) = print(io, id.type, " #", id.value)

function Base.isless(id_1::NodeID, id_2::NodeID)::Bool
    if id_1.type != id_2.type
        error("Cannot compare NodeIDs of different types")
    end
    return id_1.value < id_2.value
end

Base.to_index(id::NodeID) = Int(id.value)

const ScalarInterpolation = LinearInterpolation{Vector{Float64}, Vector{Float64}, Float64}

"""
Store information for a subnetwork used for allocation.

subnetwork_id: The ID of this allocation network
capacity: The capacity per edge of the allocation network, as constrained by nodes that have a max_flow_rate
problem: The JuMP.jl model for solving the allocation problem
Δt_allocation: The time interval between consecutive allocation solves
"""
@kwdef struct AllocationModel
    subnetwork_id::Int32
    capacity::JuMP.Containers.SparseAxisArray{Float64, 2, Tuple{NodeID, NodeID}}
    problem::JuMP.Model
    Δt_allocation::Float64
end

"""
Object for all information about allocation
subnetwork_ids: The unique sorted allocation network IDs
allocation_models: The allocation models for the main network and subnetworks corresponding to
    subnetwork_ids
main_network_connections: (from_id, to_id) from the main network to the subnetwork per subnetwork
priorities: All used priority values.
subnetwork_demands: The demand of an edge from the main network to a subnetwork
subnetwork_allocateds: The allocated flow of an edge from the main network to a subnetwork
mean_input_flows: Flows averaged over Δt_allocation over edges that are allocation sources
mean_realized_flows: Flows averaged over Δt_allocation over edges that realize a demand
record_demand: A record of demands and allocated flows for nodes that have these
record_flow: A record of all flows computed by allocation optimization, eventually saved to
    output file
"""
@kwdef struct Allocation
    subnetwork_ids::Vector{Int32} = []
    allocation_models::Vector{AllocationModel} = []
    main_network_connections::Vector{Vector{Tuple{NodeID, NodeID}}} = []
    priorities::Vector{Int32}
    subnetwork_demands::Dict{Tuple{NodeID, NodeID}, Vector{Float64}} = Dict()
    subnetwork_allocateds::Dict{Tuple{NodeID, NodeID}, Vector{Float64}} = Dict()
    mean_input_flows::Dict{Tuple{NodeID, NodeID}, Float64}
    mean_realized_flows::Dict{Tuple{NodeID, NodeID}, Float64}
    record_demand::@NamedTuple{
        time::Vector{Float64},
        subnetwork_id::Vector{Int32},
        node_type::Vector{String},
        node_id::Vector{Int32},
        priority::Vector{Int32},
        demand::Vector{Float64},
        allocated::Vector{Float64},
        realized::Vector{Float64},
    } = (;
        time = Float64[],
        subnetwork_id = Int32[],
        node_type = String[],
        node_id = Int32[],
        priority = Int32[],
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
        priority::Vector{Int32},
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
        priority = Int32[],
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
flow_idx: Index in the vector of flows
type: type of the edge
subnetwork_id_source: ID of subnetwork where this edge is a source
  (0 if not a source)
edge: (from node ID, to node ID)
"""
@kwdef struct EdgeMetadata
    id::Int32
    flow_idx::Int
    type::EdgeType.T
    subnetwork_id_source::Int32
    edge::Tuple{NodeID, NodeID}
end

"""
The update of an parameter given by a value and a reference to the target
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
The parameter update associated with a certain control state
for discrete control
"""
@kwdef struct ControlStateUpdate
    active::ParameterUpdate{Bool}
    scalar_update::Vector{ParameterUpdate{Float64}} = []
    itp_update::Vector{ParameterUpdate{ScalarInterpolation}} = []
end

abstract type AbstractParameterNode end

abstract type AbstractDemandNode <: AbstractParameterNode end

"""
In-memory storage of saved mean flows for writing to results.

- `flow`: The mean flows on all edges
- `inflow`: The sum of the mean flows coming into each basin
- `outflow`: The sum of the mean flows going out of each basin
"""
@kwdef struct SavedFlow
    flow::Vector{Float64}
    inflow::Vector{Float64}
    outflow::Vector{Float64}
end

"""
Requirements:

* Must be positive: precipitation, evaporation, infiltration, drainage
* Index points to a Basin
* volume, area, level must all be positive and monotonic increasing.

Type parameter C indicates the content backing the StructVector, which can be a NamedTuple
of vectors or Arrow Tables, and is added to avoid type instabilities.

if autodiff
    T = DiffCache{Vector{Float64}}
else
    T = Vector{Float64}
end
"""
@kwdef struct Basin{T, C, V1, V2, V3} <: AbstractParameterNode
    node_id::Vector{NodeID}
    inflow_ids::Vector{Vector{NodeID}} = [NodeID[]]
    outflow_ids::Vector{Vector{NodeID}} = [NodeID[]]
    # Vertical fluxes
    vertical_flux_from_input::V1 = zeros(length(node_id))
    vertical_flux::V2 = zeros(length(node_id))
    vertical_flux_prev::V3 = zeros(length(node_id))
    vertical_flux_integrated::V3 = zeros(length(node_id))
    vertical_flux_bmi::V3 = zeros(length(node_id))
    # Cache this to avoid recomputation
    current_level::T = zeros(length(node_id))
    current_area::T = zeros(length(node_id))
    # Discrete values for interpolation
    storage_to_level::Vector{
        LinearInterpolationIntInv{Vector{Float64}, Vector{Float64}, Float64},
    }
    level_to_area::Vector{ScalarInterpolation}
    # Demands for allocation if applicable
    demand::Vector{Float64}
    # Data source for parameter updates
    time::StructVector{BasinTimeV1, C, Int}
end

"""
    struct TabulatedRatingCurve{C}

Rating curve from level to flow rate. The rating curve is a lookup table with linear
interpolation in between. Relation can be updated in time, which is done by moving data from
the `time` field into the `tables`, which is done in the `update_tabulated_rating_curve`
callback.

Type parameter C indicates the content backing the StructVector, which can be a NamedTuple
of Vectors or Arrow Primitives, and is added to avoid type instabilities.

node_id: node ID of the TabulatedRatingCurve node
inflow_edge: incoming flow edge metadata
    The ID of the destination node is always the ID of the TabulatedRatingCurve node
outflow_edges: outgoing flow edges metadata
    The ID of the source node is always the ID of the TabulatedRatingCurve node
active: whether this node is active and thus contributes flows
table: The current Q(h) relationships
time: The time table used for updating the tables
control_mapping: dictionary from (node_id, control_state) to Q(h) and/or active state
"""
@kwdef struct TabulatedRatingCurve{C} <: AbstractParameterNode
    node_id::Vector{NodeID}
    inflow_edge::Vector{EdgeMetadata}
    outflow_edges::Vector{Vector{EdgeMetadata}}
    active::Vector{Bool}
    table::Vector{ScalarInterpolation}
    time::StructVector{TabulatedRatingCurveTimeV1, C, Int}
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
level: the fixed level of this 'infinitely big basin'
"""
@kwdef struct LevelBoundary <: AbstractParameterNode
    node_id::Vector{NodeID}
    active::Vector{Bool}
    level::Vector{ScalarInterpolation}
end

"""
node_id: node ID of the FlowBoundary node
outflow_edges: The outgoing flow edge metadata
active: whether this node is active and thus contributes flow
flow_rate: target flow rate
"""
@kwdef struct FlowBoundary <: AbstractParameterNode
    node_id::Vector{NodeID}
    outflow_edges::Vector{Vector{EdgeMetadata}}
    active::Vector{Bool}
    flow_rate::Vector{ScalarInterpolation}
end

"""
node_id: node ID of the Pump node
inflow_edge: incoming flow edge metadata
    The ID of the destination node is always the ID of the Pump node
outflow_edges: outgoing flow edges metadata
    The ID of the source node is always the ID of the Pump node
active: whether this node is active and thus contributes flow
flow_rate: target flow rate
min_flow_rate: The minimal flow rate of the pump
max_flow_rate: The maximum flow rate of the pump
control_mapping: dictionary from (node_id, control_state) to target flow rate
continuous_control_type: one of None, ContinuousControl, PidControl
"""
@kwdef struct Pump{T} <: AbstractParameterNode
    node_id::Vector{NodeID}
    inflow_edge::Vector{EdgeMetadata} = []
    outflow_edges::Vector{Vector{EdgeMetadata}} = []
    active::Vector{Bool} = fill(true, length(node_id))
    flow_rate::T
    min_flow_rate::Vector{Float64} = zeros(length(node_id))
    max_flow_rate::Vector{Float64} = fill(Inf, length(node_id))
    control_mapping::Dict{Tuple{NodeID, String}, ControlStateUpdate}
    continuous_control_type::Vector{ContinuousControlType.T} =
        fill(ContinuousControlType.None, length(node_id))

    function Pump(
        node_id,
        inflow_edge,
        outflow_edges,
        active,
        flow_rate::T,
        min_flow_rate,
        max_flow_rate,
        control_mapping,
        continuous_control_type,
    ) where {T}
        if valid_flow_rates(node_id, get_tmp(flow_rate, 0), control_mapping)
            return new{T}(
                node_id,
                inflow_edge,
                outflow_edges,
                active,
                flow_rate,
                min_flow_rate,
                max_flow_rate,
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
outflow_edges: outgoing flow edges metadata.
    The ID of the source node is always the ID of the Outlet node
active: whether this node is active and thus contributes flow
flow_rate: target flow rate
min_flow_rate: The minimal flow rate of the outlet
max_flow_rate: The maximum flow rate of the outlet
control_mapping: dictionary from (node_id, control_state) to target flow rate
continuous_control_type: one of None, ContinuousControl, PidControl
"""
@kwdef struct Outlet{T} <: AbstractParameterNode
    node_id::Vector{NodeID}
    inflow_edge::Vector{EdgeMetadata} = []
    outflow_edges::Vector{Vector{EdgeMetadata}} = []
    active::Vector{Bool} = fill(true, length(node_id))
    flow_rate::T
    min_flow_rate::Vector{Float64} = zeros(length(node_id))
    max_flow_rate::Vector{Float64} = fill(Inf, length(node_id))
    min_crest_level::Vector{Float64} = fill(-Inf, length(node_id))
    control_mapping::Dict{Tuple{NodeID, String}, ControlStateUpdate} = Dict()
    continuous_control_type::Vector{ContinuousControlType.T} =
        fill(ContinuousControlType.None, length(node_id))

    function Outlet(
        node_id,
        inflow_id,
        outflow_ids,
        active,
        flow_rate::T,
        min_flow_rate,
        max_flow_rate,
        min_crest_level,
        control_mapping,
        continuous_control_type,
    ) where {T}
        if valid_flow_rates(node_id, get_tmp(flow_rate, 0), control_mapping)
            return new{T}(
                node_id,
                inflow_id,
                outflow_ids,
                active,
                flow_rate,
                min_flow_rate,
                max_flow_rate,
                min_crest_level,
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
A variant on `Base.Ref` where the source array is a vector that is possibly wrapped in a ForwardDiff.DiffCache.
Retrieve value with get_value(ref::PreallocationRef, val) where `val` determines the return type.
"""
struct PreallocationRef{T}
    vector::T
    idx::Int
end

get_value(ref::PreallocationRef, val) = get_tmp(ref.vector, val)[ref.idx]

function set_value!(ref::PreallocationRef, value)::Nothing
    get_tmp(ref.vector, value)[ref.idx] = value
    return nothing
end

"""
The data for a single compound variable
node_id:: The ID of the DiscreteControl that listens to this variable
subvariables: data for one single subvariable
greater_than: the thresholds this compound variable will be
    compared against (in the case of DiscreteControl)
"""
@kwdef struct CompoundVariable{T}
    node_id::NodeID
    subvariables::Vector{
        @NamedTuple{
            listen_node_id::NodeID,
            variable_ref::PreallocationRef{T},
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
@kwdef struct DiscreteControl{T} <: AbstractParameterNode
    node_id::Vector{NodeID}
    controlled_nodes::Vector{Vector{NodeID}}
    compound_variables::Vector{Vector{CompoundVariable{T}}}
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

@kwdef struct ContinuousControl{T} <: AbstractParameterNode
    node_id::Vector{NodeID}
    compound_variable::Vector{CompoundVariable{T}}
    controlled_variable::Vector{String}
    target_ref::Vector{PreallocationRef{T}}
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
@kwdef struct PidControl{T} <: AbstractParameterNode
    node_id::Vector{NodeID}
    active::Vector{Bool}
    listen_node_id::Vector{NodeID}
    target::Vector{ScalarInterpolation}
    target_ref::Vector{PreallocationRef{T}}
    proportional::Vector{ScalarInterpolation}
    integral::Vector{ScalarInterpolation}
    derivative::Vector{ScalarInterpolation}
    error::T
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
realized_bmi: Cumulative inflow volume, for read or reset by BMI only
demand: water flux demand of UserDemand per priority (node_idx, priority_idx)
    Each UserDemand has a demand for all priorities,
    which is 0.0 if it is not provided explicitly.
demand_reduced: the total demand reduced by allocated flows. This is used for goal programming,
    and requires separate memory from `demand` since demands can come from the BMI
demand_itp: Timeseries interpolation objects for demands
demand_from_timeseries: If false the demand comes from the BMI or is fixed
allocated: water flux currently allocated to UserDemand per priority (node_idx, priority_idx)
return_factor: the factor in [0,1] of how much of the abstracted water is given back to the system
min_level: The level of the source basin below which the UserDemand does not abstract
"""
@kwdef struct UserDemand <: AbstractDemandNode
    node_id::Vector{NodeID}
    inflow_edge::Vector{EdgeMetadata} = []
    outflow_edge::Vector{EdgeMetadata} = []
    active::Vector{Bool} = fill(true, length(node_id))
    realized_bmi::Vector{Float64} = zeros(length(node_id))
    demand::Matrix{Float64}
    demand_reduced::Matrix{Float64}
    demand_itp::Vector{Vector{ScalarInterpolation}}
    demand_from_timeseries::Vector{Bool}
    allocated::Matrix{Float64}
    return_factor::Vector{Float64}
    min_level::Vector{Float64}
end

"""
node_id: node ID of the LevelDemand node
min_level: The minimum target level of the connected basin(s)
max_level: The maximum target level of the connected basin(s)
priority: If in a shortage state, the priority of the demand of the connected basin(s)
"""
@kwdef struct LevelDemand <: AbstractDemandNode
    node_id::Vector{NodeID}
    min_level::Vector{ScalarInterpolation} = fill(-Inf, length(node_id))
    max_level::Vector{ScalarInterpolation} = fill(Inf, length(node_id))
    priority::Vector{Int32}
end

"""
node_id: node ID of the FlowDemand node
demand_itp: The time interpolation of the demand of the node
demand: The current demand of the node
priority: The priority of the demand of the node
"""
@kwdef struct FlowDemand <: AbstractDemandNode
    node_id::Vector{NodeID}
    demand_itp::Vector{ScalarInterpolation}
    demand::Vector{Float64}
    priority::Vector{Int32}
end

"Subgrid linearly interpolates basin levels."
@kwdef struct Subgrid
    subgrid_id::Vector{Int32}
    basin_index::Vector{Int32}
    interpolations::Vector{ScalarInterpolation}
    level::Vector{Float64}
end

"""
The metadata of the graph (the fields of the NamedTuple) can be accessed
    e.g. using graph[].flow.
node_ids: mapping subnetwork ID -> node IDs in that subnetwork
edges_source: mapping subnetwork ID -> metadata of allocation
    source edges in that subnetwork
flow_edges: The metadata of all flow edges
flow dict: mapping (source ID, destination ID) -> index in the flow vector
    of the flow over that edge
flow: Flow per flow edge in the order prescribed by flow_dict
flow_prev: The flow vector of the previous timestep, used for integration
flow_integrated: Flow integrated over time, used for mean flow computation
    over saveat intervals
saveat: The time interval between saves of output data (storage, flow, ...)
"""
const ModelGraph{T} = MetaGraph{
    Int64,
    DiGraph{Int64},
    NodeID,
    NodeMetadata,
    EdgeMetadata,
    @NamedTuple{
        node_ids::Dict{Int32, Set{NodeID}},
        edges_source::Dict{Int32, Set{EdgeMetadata}},
        flow_edges::Vector{EdgeMetadata},
        flow_dict::Dict{Tuple{NodeID, NodeID}, Int},
        flow::T,
        flow_prev::Vector{Float64},
        flow_integrated::Vector{Float64},
        saveat::Float64,
    },
    MetaGraphsNext.var"#11#13",
    Float64,
} where {T}

@kwdef struct Parameters{T, C1, C2, V1, V2, V3}
    starttime::DateTime
    graph::ModelGraph{T}
    allocation::Allocation
    basin::Basin{T, C1, V1, V2, V3}
    linear_resistance::LinearResistance
    manning_resistance::ManningResistance
    tabulated_rating_curve::TabulatedRatingCurve{C2}
    level_boundary::LevelBoundary
    flow_boundary::FlowBoundary
    pump::Pump{T}
    outlet::Outlet{T}
    terminal::Terminal
    discrete_control::DiscreteControl{T}
    continuous_control::ContinuousControl{T}
    pid_control::PidControl{T}
    user_demand::UserDemand
    level_demand::LevelDemand
    flow_demand::FlowDemand
    subgrid::Subgrid
end
