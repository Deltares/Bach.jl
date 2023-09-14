module config

using Configurations: Configurations, Maybe, @option, from_toml, @type_alias
using DataStructures: DefaultDict
using Dates
using Legolas: Legolas, record_type
using Logging: LogLevel, Debug, Info, Warn, Error
using ..Ribasim: Ribasim, isnode, nodetype
using OrdinaryDiffEq

export Config, Solver, Output, Logging
export algorithm, snake_case, zstd, lz4

const schemas =
    getfield.(
        Ref(Ribasim),
        filter!(x -> endswith(string(x), "SchemaVersion"), names(Ribasim; all = true)),
    )

# Find all nodetypes and possible nodekinds
nodekinds = DefaultDict{Symbol, Vector{Symbol}}(() -> Symbol[])  # require lambda to avoid sharing
nodeschemas = filter(isnode, schemas)
for sv in nodeschemas
    node, kind = nodetype(sv)
    push!(nodekinds[node], kind)
end

"Convert a string from CamelCase to snake_case."
function snake_case(str::AbstractString)::String
    under_scored = replace(str, r"(?<!^)(?=[A-Z])" => "_")
    return lowercase(under_scored)
end

snake_case(sym::Symbol)::Symbol = Symbol(snake_case(String(sym)))

"""
Add fieldnames with Maybe{String} type to struct expression. Requires @option use before it.
"""
macro addfields(typ::Expr, fieldnames)
    for fieldname in fieldnames
        push!(typ.args[3].args, Expr(:(=), Expr(:(::), fieldname, Maybe{String}), nothing))
    end
    return esc(typ)
end

"""
Add all TableOption subtypes as fields to struct expression. Requires @option use before it.
"""
macro addnodetypes(typ::Expr)
    for nodetype in nodetypes
        node_type = snake_case(nodetype)
        push!(
            typ.args[3].args,
            Expr(:(=), Expr(:(::), node_type, node_type), Expr(:call, node_type)),
        )
    end
    return esc(typ)
end

# Generate structs for each nodetype for use in Config
abstract type TableOption end
for (T, kinds) in pairs(nodekinds)
    T = snake_case(T)
    @eval @option @addfields struct $T <: TableOption end $kinds
end
const nodetypes = collect(keys(nodekinds))

@option struct Solver <: TableOption
    algorithm::String = "QNDF"
    saveat::Union{Float64, Vector{Float64}} = Float64[]
    adaptive::Bool = true
    dt::Float64 = 0.0
    abstol::Float64 = 1e-6
    reltol::Float64 = 1e-3
    maxiters::Int = 1e9
    sparse::Bool = true
    autodiff::Bool = true
end

@enum Compression begin
    zstd
    lz4
end

function Base.convert(::Type{Compression}, str::AbstractString)
    i = findfirst(==(Symbol(str)) ∘ Symbol, instances(Compression))
    if i === nothing
        throw(
            ArgumentError(
                "Compression algorithm $str not supported, choose one of: $(join(instances(Compression), " ")).",
            ),
        )
    end
    return Compression(i - 1)
end

# Separate struct, as basin clashes with nodetype
@option struct Output <: TableOption
    basin::String = "output/basin.arrow"
    flow::String = "output/flow.arrow"
    control::String = "output/control.arrow"
    outstate::Maybe{String}
    compression::Compression = "zstd"
    compression_level::Int = 6
end

@option struct Logging <: TableOption
    verbosity::LogLevel = Info
    timing::Bool = false
end

@option @addnodetypes struct Config <: TableOption
    starttime::DateTime
    endtime::DateTime

    # [s] Δt for periodic update frequency, including user horizons
    update_timestep::Float64 = 60 * 60 * 24.0

    # optional, when Config is created from a TOML file, this is its directory
    relative_dir::String = "."  # ignored(!)
    input_dir::String = "."
    output_dir::String = "."

    # input, required
    geopackage::String

    # output, required
    output::Output = Output()

    solver::Solver = Solver()

    logging::Logging = Logging()
end

function Configurations.from_dict(::Type{Logging}, ::Type{LogLevel}, level::AbstractString)
    level == "debug" && return Debug
    level == "info" && return Info
    level == "warn" && return Warn
    level == "error" && return Error
    throw(
        ArgumentError(
            "verbosity $level not supported, choose one of: debug info warn error.",
        ),
    )
end

# [] in TOML is parsed as a Vector{Union{}}
function Configurations.from_dict(::Type{Solver}, t::Type, saveat::Vector{Union{}})
    return Float64[]
end

# TODO Use with proper alignment
function Base.show(io::IO, c::Config)
    println(io, "Ribasim Config")
    for field in fieldnames(typeof(c))
        f = getfield(c, field)
        f === nothing || println(io, "\t$field\t= $f")
    end
end

function Base.show(io::IO, c::TableOption)
    first = true
    for field in fieldnames(typeof(c))
        f = getfield(c, field)
        if f !== nothing
            first && (first = false; println(io))
            println(io, "\t\t$field\t= $f")
        end
    end
end

"Map from config string to supported algorithm type"
const algorithms = Dict{String, Type}(
    "QNDF" => QNDF,
    "Rosenbrock23" => Rosenbrock23,
    "TRBDF2" => TRBDF2,
    "Rodas5" => Rodas5,
    "KenCarp4" => KenCarp4,
    "Tsit5" => Tsit5,
    "RK4" => RK4,
    "ImplicitEuler" => ImplicitEuler,
    "Euler" => Euler,
)

"Create an OrdinaryDiffEqAlgorithm from solver config"
function algorithm(solver::Solver)::OrdinaryDiffEqAlgorithm
    algotype = get(algorithms, solver.algorithm, nothing)
    if algotype === nothing
        options = join(keys(algorithms), ", ")
        error("Given solver algorithm $(solver.algorithm) not supported.\n\
            Available options are: ($(options)).")
    end
    # not all algorithms support this keyword
    try
        algotype(; solver.autodiff)
    catch
        algotype()
    end
end

end  # module
