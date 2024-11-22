"""
    module config

Ribasim.config is a submodule of [`Ribasim`](@ref) to handle the configuration of a Ribasim model.
It is implemented using the [Configurations](https://configurations.rogerluo.dev/stable/) package.
A full configuration is represented by [`Config`](@ref), which is the main API.
Ribasim.config is a submodule mainly to avoid name clashes between the configuration sections and the rest of Ribasim.
"""
module config

using Configurations: Configurations, @option, from_toml, @type_alias
using DataInterpolations: LinearInterpolation, PCHIPInterpolation, CubicHermiteSpline
using DataStructures: DefaultDict
using Dates: DateTime
using Logging: LogLevel, Debug, Info, Warn, Error
using ..Ribasim: Ribasim, isnode, nodetype
using OrdinaryDiffEqCore: OrdinaryDiffEqAlgorithm, OrdinaryDiffEqNewtonAdaptiveAlgorithm
using OrdinaryDiffEqNonlinearSolve: NLNewton
using OrdinaryDiffEqLowOrderRK: Euler, RK4
using OrdinaryDiffEqTsit5: Tsit5
using OrdinaryDiffEqSDIRK: ImplicitEuler, KenCarp4, TRBDF2
using OrdinaryDiffEqBDF: FBDF, QNDF
using OrdinaryDiffEqRosenbrock: Rosenbrock23, Rodas4P, Rodas5P

export Config, Solver, Results, Logging, Toml
export algorithm,
    camel_case,
    convert_dt,
    convert_saveat,
    database_path,
    input_path,
    interpolation_method,
    nodetypes,
    results_path,
    snake_case

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
# Terminal has no tables
nodekinds[:Terminal] = Symbol[]

"Convert a string from CamelCase to snake_case."
function snake_case(str::AbstractString)::String
    under_scored = replace(str, r"(?<!^)(?=[A-Z])" => "_")
    return lowercase(under_scored)
end

snake_case(sym::Symbol)::Symbol = Symbol(snake_case(String(sym)))

"Convert a string from snake_case to CamelCase."
function camel_case(snake_case::AbstractString)::String
    camel_case = replace(snake_case, r"_([a-z])" => s -> uppercase(s[2]))
    camel_case = uppercase(first(camel_case)) * camel_case[2:end]
    return camel_case
end

camel_case(sym::Symbol)::Symbol = Symbol(camel_case(String(sym)))

"""
Add fieldnames with Union{String, Nothing} type to struct expression. Requires @option use before it.
"""
macro addfields(typ::Expr, fieldnames)
    for fieldname in fieldnames
        push!(
            typ.args[3].args,
            Expr(:(=), Expr(:(::), fieldname, Union{String, Nothing}), nothing),
        )
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
    saveat::Float64 = 86400.0
    dt::Union{Float64, Nothing} = nothing
    dtmin::Float64 = 0.0
    dtmax::Union{Float64, Nothing} = nothing
    force_dtmin::Bool = false
    abstol::Float64 = 1e-7
    reltol::Float64 = 1e-7
    water_balance_abstol::Float64 = 1e-3
    water_balance_reltol::Float64 = 1e-2
    maxiters::Int = 1e9
    sparse::Bool = true
    autodiff::Bool = false
    evaporate_mass::Bool = true
end

# Separate struct, as basin clashes with nodetype
@option struct Results <: TableOption
    outstate::Union{String, Nothing} = nothing
    compression::Bool = true
    compression_level::Int = 6
    subgrid::Bool = false
end

@option struct Logging <: TableOption
    verbosity::LogLevel = Info
end

@option struct Allocation <: TableOption
    timestep::Float64 = 86400
    use_allocation::Bool = false
end

@option struct Interpolation <: TableOption
    tabulated_rating_curve::String = "LinearInterpolation"
end

@option struct Experimental <: TableOption
    concentration::Bool = false
end

# For logging enabled experimental features
function Base.iterate(exp::Experimental, state = 0)
    state >= nfields(exp) && return
    return Base.getfield(exp, state + 1), state + 1
end
function Base.show(io::IO, exp::Experimental)
    fields = (field for field in fieldnames(typeof(exp)) if getfield(exp, field))
    print(io, join(fields, " "))
end

@option @addnodetypes struct Toml <: TableOption
    starttime::DateTime
    endtime::DateTime
    crs::String
    ribasim_version::String
    input_dir::String
    results_dir::String
    allocation::Allocation = Allocation()
    solver::Solver = Solver()
    interpolation::Interpolation = Interpolation()
    logging::Logging = Logging()
    results::Results = Results()
    experimental::Experimental = Experimental()
end

struct Config
    toml::Toml
    dir::String
end

Config(toml::Toml) = Config(toml, ".")

"""
    Config(config_path::AbstractString; kwargs...)

Parse a TOML file to a Config. Keys can be overruled using keyword arguments. To overrule
keys from a subsection, e.g. `dt` from the `solver` section, use underscores: `solver_dt`.
"""
function Config(config_path::AbstractString; kwargs...)::Config
    toml = from_toml(Toml, config_path; kwargs...)
    dir = dirname(normpath(config_path))
    Config(toml, dir)
end

Base.getproperty(config::Config, sym::Symbol) = getproperty(getfield(config, :toml), sym)

Base.dirname(config::Config) = getfield(config, :dir)

"Construct a path relative to both the TOML directory and the optional `input_dir`"
function input_path(config::Config, path::String)
    return normpath(dirname(config), config.input_dir, path)
end

"Construct the database path relative to both the TOML directory and the optional `input_dir`"
function database_path(config::Config)
    return normpath(dirname(config), config.input_dir, "database.gpkg")
end

"Construct a path relative to both the TOML directory and the optional `results_dir`"
function results_path(config::Config, path::String)
    return normpath(dirname(config), config.results_dir, path)
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

"""
    const algorithms::Dict{String, Type}

Map from config string to a supported algorithm type from [OrdinaryDiffEq](https://docs.sciml.ai/DiffEqDocs/stable/solvers/ode_solve/).

Supported algorithms:

- `QNDF`
- `FBDF`
- `Rosenbrock23`
- `TRBDF2`
- `Rodas4P`
- `Rodas5P`
- `KenCarp4`
- `Tsit5`
- `RK4`
- `ImplicitEuler`
- `Euler`
"""
const algorithms = Dict{String, Type}(
    "QNDF" => QNDF,
    "FBDF" => FBDF,
    "Rosenbrock23" => Rosenbrock23,
    "TRBDF2" => TRBDF2,
    "Rodas4P" => Rodas4P,
    "Rodas5P" => Rodas5P,
    "KenCarp4" => KenCarp4,
    "Tsit5" => Tsit5,
    "RK4" => RK4,
    "ImplicitEuler" => ImplicitEuler,
    "Euler" => Euler,
)

# PCHIPInterpolation is only a function, creates a CubicHermiteSpline
const interpolation_methods =
    Dict{String, @NamedTuple{type::Type, constructor::Union{Function, Type}}}(
        "LinearInterpolation" =>
            (type = LinearInterpolation, constructor = LinearInterpolation),
        "PCHIPInterpolation" =>
            (type = CubicHermiteSpline, constructor = PCHIPInterpolation),
    )

interpolation_method(method) = get(interpolation_methods, method, nothing)

"""
Check whether the given function has a method that accepts the given kwarg.
Note that it is possible that methods exist that accept :a and :b individually,
but not both.
"""
function function_accepts_kwarg(f, kwarg)::Bool
    for method in methods(f)
        kwarg in Base.kwarg_decl(method) && return true
    end
    return false
end

"Create an OrdinaryDiffEqAlgorithm from solver config"
function algorithm(solver::Solver; u0 = [])::OrdinaryDiffEqAlgorithm
    algotype = get(algorithms, solver.algorithm, nothing)
    if algotype === nothing
        options = join(keys(algorithms), ", ")
        error("Given solver algorithm $(solver.algorithm) not supported.\n\
            Available options are: ($(options)).")
    end
    kwargs = Dict{Symbol, Any}()

    if algotype <: OrdinaryDiffEqNewtonAdaptiveAlgorithm
        kwargs[:nlsolve] = NLNewton(;
            relax = Ribasim.MonitoredBackTracking(; z_tmp = copy(u0), dz_tmp = copy(u0)),
        )
    end

    if function_accepts_kwarg(algotype, :step_limiter!)
        kwargs[:step_limiter!] = Ribasim.limit_flow!
    end

    if function_accepts_kwarg(algotype, :autodiff)
        kwargs[:autodiff] = solver.autodiff
    end

    algotype(; kwargs...)
end

"Convert the saveat Float64 from our Config to SciML's saveat"
function convert_saveat(saveat::Float64, t_end::Float64)::Union{Float64, Vector{Float64}}
    errors = false
    if iszero(saveat)
        # every step
        saveat = Float64[]
    elseif saveat == Inf
        # only the start and end
        saveat = [0.0, t_end]
    elseif isfinite(saveat)
        # every saveat seconds
        if saveat !== round(saveat)
            errors = true
            @error "A finite saveat must be an integer number of seconds." saveat
        end
    else
        errors = true
        @error "Invalid saveat" saveat
    end

    errors && error("Invalid saveat")
    return saveat
end

"Convert the dt from our Config to SciML stepsize control arguments"
function convert_dt(dt::Union{Float64, Nothing})::Tuple{Bool, Float64}
    # In SciML dt represents the initial timestep if adaptive is true.
    # We don't support setting the initial timestep, so we don't need the adaptive flag.
    # The solver will give a clear error message if the algorithm is not adaptive.
    if isnothing(dt)
        # adaptive step size
        adaptive = true
        dt = 0.0
    elseif 0 < dt < Inf
        # fixed step size
        adaptive = false
    else
        @error "Invalid dt" dt
        error("Invalid dt")
    end
    adaptive, dt
end

end  # module
