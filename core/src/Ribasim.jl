"""
    module Ribasim

Ribasim is a water resources model.
The computational core is implemented in Julia in the Ribasim package.
It is currently mainly designed to be used as an application.
To run a simulation from Julia, use [`Ribasim.run`](@ref).

For more granular access, see:
- [`Config`](@ref)
- [`Model`](@ref)
- [`solve!`](@ref)
- [`write_results`](@ref)
"""
module Ribasim

# Algorithms for solving ODEs.
using OrdinaryDiffEqCore: OrdinaryDiffEqCore, get_du, AbstractNLSolver
using DiffEqBase: DiffEqBase, calculate_residuals!
using OrdinaryDiffEqNonlinearSolve: OrdinaryDiffEqNonlinearSolve, relax!, _compute_rhs!
using LineSearches: BackTracking

# Interface for defining and solving the ODE problem of the physical layer.
using SciMLBase:
    init,
    solve!,
    step!,
    check_error!,
    SciMLBase,
    successful_retcode,
    CallbackSet,
    ODEFunction,
    ODEProblem,
    get_proposed_dt,
    DEIntegrator

# Automatically detecting the sparsity pattern of the Jacobian of water_balance!
# through operator overloading
using SparseConnectivityTracer: TracerSparsityDetector, jacobian_sparsity, GradientTracer

# For efficient sparse computations
using SparseArrays: SparseMatrixCSC, spzeros

# Linear algebra
using LinearAlgebra: mul!

# PreallocationTools is used because the RHS function (water_balance!) gets called with different input types
# for u, du:
# - Float64 for normal calls
# - Dual numbers for automatic differentiation with ForwardDiff
# - GradientTracer for automatic Jacobian sparsity detection with SparseConnectivityTracer
# The computations inside the rhs go trough preallocated arrays of the required type which are created by LazyBufferCache.
# Retrieving a cache from a LazyBufferCache looks like indexing: https://docs.sciml.ai/PreallocationTools/stable/#LazyBufferCache
using PreallocationTools: LazyBufferCache

# Interpolation functionality, used for e.g.
# basin profiles and TabulatedRatingCurve. See also the node
# references in the docs.
using DataInterpolations:
    ConstantInterpolation,
    LinearInterpolation,
    LinearInterpolationIntInv,
    invert_integral,
    derivative,
    integral,
    AbstractInterpolation
using DataInterpolations.ExtrapolationType: Constant, Linear

# Modeling language for Mathematical Optimization.
# Used for allocation, see the docs: https://ribasim.org/dev/allocation.html
import JuMP
# The optimization backend of JuMP.
import HiGHS

# The BMI is a standard for interacting with a Ribasim model,
# see the docs: https://ribasim.org/dev/bmi.html
import BasicModelInterface as BMI

# Reading and writing optionally compressed Arrow tables
using Arrow: Arrow, Table
import TranscodingStreams
using CodecZstd: ZstdCompressor
# Reading GeoPackage files, which are SQLite databases with spatial data
using SQLite: SQLite, DB, Query, esc_id
using DBInterface: execute

# Logging to both the console and a file
using Logging: Logging, with_logger, @logmsg, LogLevel, AbstractLogger
import LoggingExtras
using TerminalLoggers: TerminalLogger

# Convenience wrapper around arrays, divides vectors in
# separate sections which can be indexed individually.
# Used for e.g. Basin forcing and the state vector.
using ComponentArrays: ComponentVector, ComponentArray, Axis, getaxes

# Date and time handling; externally we use the proleptic Gregorian calendar,
# internally we use a Float64; seconds since the start of the simulation.
using Dates: Dates, DateTime, Millisecond, @dateformat_str

# Callbacks are used to trigger function calls at specific points in the similation.
# E.g. after each timestep for discrete control,
# or at each saveat for saving storage and flow results.
using DiffEqCallbacks:
    FunctionCallingCallback, PresetTimeCallback, SavedValues, SavingCallback

# The network defined by the Node and Link table is converted to a graph internally.
using Graphs: DiGraph, edges, inneighbors, outneighbors, induced_subgraph, is_connected
# Convenience functionality built on top of Graphs. Used to store e.g. node and edge metadata
# alongside the graph. Extra metadata is stored in a NamedTuple retrieved as graph[].
using MetaGraphsNext: MetaGraphsNext, MetaGraph, label_for, code_for, labels

# Improved enumeration type compared to Base, used for e.g. node types.
using EnumX: EnumX, @enumx

# Easily change an immutable field of an object.
using Accessors: @set, @reset

# Iteration utilities, used to partition and group tables.
import IterTools

# Define and validate the schemas of the input tables.
using Legolas: Legolas, @schema, @version, validate, SchemaVersion, declared

# Tables interface that works with either SQLite or Arrow tables.
using Tables: Tables, AbstractRow, columntable

# Wrapper around a vector of structs to easily retrieve the same field from all elements.
using StructArrays: StructVector

# OrderedSet is used to store the order of the substances in the network.
# OrderedDict is used to store the order of the sources in a subnetwork.
using DataStructures: OrderedSet, OrderedDict, counter, inc!

export libribasim

include("schema.jl")
include("config.jl")
using .config
include("parameter.jl")
include("validation.jl")
include("solve.jl")
include("logging.jl")
include("allocation_init.jl")
include("allocation_optim.jl")
include("util.jl")
include("graph.jl")
include("model.jl")
include("read.jl")
include("write.jl")
include("bmi.jl")
include("callback.jl")
include("concentration.jl")
include("main.jl")
include("libribasim.jl")

# Define names used in Makie extension
function plot_basin_data end
function plot_basin_data! end
function plot_flow end
function plot_flow! end

end  # module Ribasim
