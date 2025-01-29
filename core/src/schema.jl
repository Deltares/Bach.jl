# These schemas define the name of database tables and the configuration file structure
# The identifier is parsed as ribasim.nodetype.kind, no capitals or underscores are allowed.
@schema "ribasim.basin.concentration" BasinConcentration
@schema "ribasim.basin.concentrationexternal" BasinConcentrationExternal
@schema "ribasim.basin.concentrationstate" BasinConcentrationState
@schema "ribasim.basin.profile" BasinProfile
@schema "ribasim.basin.state" BasinState
@schema "ribasim.basin.static" BasinStatic
@schema "ribasim.basin.subgrid" BasinSubgrid
@schema "ribasim.basin.subgridtime" BasinSubgridTime
@schema "ribasim.basin.time" BasinTime
@schema "ribasim.continuouscontrol.function" ContinuousControlFunction
@schema "ribasim.continuouscontrol.variable" ContinuousControlVariable
@schema "ribasim.discretecontrol.condition" DiscreteControlCondition
@schema "ribasim.discretecontrol.logic" DiscreteControlLogic
@schema "ribasim.discretecontrol.variable" DiscreteControlVariable
@schema "ribasim.flowboundary.concentration" FlowBoundaryConcentration
@schema "ribasim.flowboundary.static" FlowBoundaryStatic
@schema "ribasim.flowboundary.time" FlowBoundaryTime
@schema "ribasim.flowdemand.static" FlowDemandStatic
@schema "ribasim.flowdemand.time" FlowDemandTime
@schema "ribasim.levelboundary.concentration" LevelBoundaryConcentration
@schema "ribasim.levelboundary.static" LevelBoundaryStatic
@schema "ribasim.levelboundary.time" LevelBoundaryTime
@schema "ribasim.leveldemand.static" LevelDemandStatic
@schema "ribasim.leveldemand.time" LevelDemandTime
@schema "ribasim.linearresistance.static" LinearResistanceStatic
@schema "ribasim.manningresistance.static" ManningResistanceStatic
@schema "ribasim.outlet.static" OutletStatic
@schema "ribasim.pidcontrol.static" PidControlStatic
@schema "ribasim.pidcontrol.time" PidControlTime
@schema "ribasim.pump.static" PumpStatic
@schema "ribasim.tabulatedratingcurve.static" TabulatedRatingCurveStatic
@schema "ribasim.tabulatedratingcurve.time" TabulatedRatingCurveTime
@schema "ribasim.userdemand.concentration" UserDemandConcentration
@schema "ribasim.userdemand.static" UserDemandStatic
@schema "ribasim.userdemand.time" UserDemandTime

# This schema is not specific to a node type
@schema "ribasim.allocationsourceorder" AllocationSourceOrder

const delimiter = " / "
tablename(sv::Type{SchemaVersion{T, N}}) where {T, N} = tablename(sv())
tablename(sv::SchemaVersion{T, N}) where {T, N} =
    join(filter(!isnothing, nodetype(sv)), delimiter)
isnode(sv::Type{SchemaVersion{T, N}}) where {T, N} = isnode(sv())
isnode(::SchemaVersion{T, N}) where {T, N} = length(split(string(T), '.'; limit = 3)) == 3
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
    node = last(split(string(Symbol(record)), '.'; limit = 3))

    type_string = string(T)
    elements = split(type_string, '.'; limit = 3)
    last_element = last(elements)
    # Special case last elements that need an underscore
    if startswith(last_element, "concentration") && length(last_element) > 13
        elements[end] = "concentration_$(last_element[14:end])"
    elseif last_element == "subgridtime"
        elements[end] = "subgrid_time"
    end
    if isnode(sv)
        n = elements[2]
        k = Symbol(elements[3])
    else
        n = last(elements)
        k = nothing
    end

    return Symbol(node[begin:length(n)]), k
end

@version AllocationSourceOrderV1 begin
    subnetwork_id::Int32
    node_id::Int32
    source_priority::Int32
end

@version PumpStaticV1 begin
    node_id::Int32
    active::Union{Missing, Bool}
    flow_rate::Float64
    min_flow_rate::Union{Missing, Float64}
    max_flow_rate::Union{Missing, Float64}
    min_upstream_level::Union{Missing, Float64}
    max_downstream_level::Union{Missing, Float64}
    control_state::Union{Missing, String}
end

@version OutletStaticV1 begin
    node_id::Int32
    active::Union{Missing, Bool}
    flow_rate::Float64
    min_flow_rate::Union{Missing, Float64}
    max_flow_rate::Union{Missing, Float64}
    min_upstream_level::Union{Missing, Float64}
    max_downstream_level::Union{Missing, Float64}
    control_state::Union{Missing, String}
end

@version BasinStaticV1 begin
    node_id::Int32
    drainage::Union{Missing, Float64}
    potential_evaporation::Union{Missing, Float64}
    infiltration::Union{Missing, Float64}
    precipitation::Union{Missing, Float64}
end

@version BasinTimeV1 begin
    node_id::Int32
    time::DateTime
    drainage::Union{Missing, Float64}
    potential_evaporation::Union{Missing, Float64}
    infiltration::Union{Missing, Float64}
    precipitation::Union{Missing, Float64}
end

@version BasinConcentrationV1 begin
    node_id::Int32
    time::DateTime
    substance::String
    drainage::Union{Missing, Float64}
    precipitation::Union{Missing, Float64}
end

@version BasinConcentrationExternalV1 begin
    node_id::Int32
    time::DateTime
    substance::String
    concentration::Union{Missing, Float64}
end

@version BasinProfileV1 begin
    node_id::Int32
    area::Float64
    level::Float64
end

@version BasinStateV1 begin
    node_id::Int32
    level::Float64
end

@version BasinConcentrationStateV1 begin
    node_id::Int32
    substance::String
    concentration::Union{Missing, Float64}
end

@version BasinSubgridV1 begin
    subgrid_id::Int32
    node_id::Int32
    basin_level::Float64
    subgrid_level::Float64
end

@version BasinSubgridTimeV1 begin
    subgrid_id::Int32
    node_id::Int32
    time::DateTime
    basin_level::Float64
    subgrid_level::Float64
end

@version LevelBoundaryStaticV1 begin
    node_id::Int32
    active::Union{Missing, Bool}
    level::Float64
end

@version LevelBoundaryTimeV1 begin
    node_id::Int32
    time::DateTime
    level::Float64
end

@version LevelBoundaryConcentrationV1 begin
    node_id::Int32
    time::DateTime
    substance::String
    concentration::Float64
end

@version FlowBoundaryStaticV1 begin
    node_id::Int32
    active::Union{Missing, Bool}
    flow_rate::Float64
end

@version FlowBoundaryTimeV1 begin
    node_id::Int32
    time::DateTime
    flow_rate::Float64
end

@version FlowBoundaryConcentrationV1 begin
    node_id::Int32
    time::DateTime
    substance::String
    concentration::Float64
end

@version LinearResistanceStaticV1 begin
    node_id::Int32
    active::Union{Missing, Bool}
    resistance::Float64
    max_flow_rate::Union{Missing, Float64}
    control_state::Union{Missing, String}
end

@version ManningResistanceStaticV1 begin
    node_id::Int32
    active::Union{Missing, Bool}
    length::Float64
    manning_n::Float64
    profile_width::Float64
    profile_slope::Float64
    control_state::Union{Missing, String}
end

@version TabulatedRatingCurveStaticV1 begin
    node_id::Int32
    active::Union{Missing, Bool}
    level::Float64
    flow_rate::Float64
    max_downstream_level::Union{Missing, Float64}
    control_state::Union{Missing, String}
end

@version TabulatedRatingCurveTimeV1 begin
    node_id::Int32
    time::DateTime
    level::Float64
    flow_rate::Float64
    max_downstream_level::Union{Missing, Float64}
end

@version DiscreteControlVariableV1 begin
    node_id::Int32
    compound_variable_id::Int32
    listen_node_id::Int32
    variable::String
    weight::Union{Missing, Float64}
    look_ahead::Union{Missing, Float64}
end

@version DiscreteControlConditionV1 begin
    node_id::Int32
    compound_variable_id::Int32
    greater_than::Float64
end

@version DiscreteControlLogicV1 begin
    node_id::Int32
    truth_state::String
    control_state::String
end

@version ContinuousControlVariableV1 begin
    node_id::Int32
    listen_node_id::Int32
    variable::String
    weight::Union{Missing, Float64}
    look_ahead::Union{Missing, Float64}
end

@version ContinuousControlFunctionV1 begin
    node_id::Int32
    input::Float64
    output::Float64
    controlled_variable::String
end

@version PidControlStaticV1 begin
    node_id::Int32
    active::Union{Missing, Bool}
    listen_node_id::Int32
    target::Float64
    proportional::Float64
    integral::Float64
    derivative::Float64
    control_state::Union{Missing, String}
end

@version PidControlTimeV1 begin
    node_id::Int32
    listen_node_id::Int32
    time::DateTime
    target::Float64
    proportional::Float64
    integral::Float64
    derivative::Float64
    control_state::Union{Missing, String}
end

@version UserDemandStaticV1 begin
    node_id::Int32
    active::Union{Missing, Bool}
    demand::Union{Missing, Float64}
    return_factor::Float64
    min_level::Float64
    demand_priority::Union{Missing, Int32}
end

@version UserDemandTimeV1 begin
    node_id::Int32
    time::DateTime
    demand::Float64
    return_factor::Float64
    min_level::Float64
    demand_priority::Union{Missing, Int32}
end

@version UserDemandConcentrationV1 begin
    node_id::Int32
    time::DateTime
    substance::String
    concentration::Float64
end

@version LevelDemandStaticV1 begin
    node_id::Int32
    min_level::Union{Missing, Float64}
    max_level::Union{Missing, Float64}
    demand_priority::Union{Missing, Int32}
end

@version LevelDemandTimeV1 begin
    node_id::Int32
    time::DateTime
    min_level::Union{Missing, Float64}
    max_level::Union{Missing, Float64}
    demand_priority::Union{Missing, Int32}
end

@version FlowDemandStaticV1 begin
    node_id::Int
    demand::Float64
    demand_priority::Union{Missing, Int32}
end

@version FlowDemandTimeV1 begin
    node_id::Int
    time::DateTime
    demand::Float64
    demand_priority::Union{Missing, Int32}
end
