module Ribasim

import BasicModelInterface as BMI

using Arrow: Arrow, Table
using Configurations: Configurations, Maybe, @option, from_toml, from_dict
using DataFrames
using DataInterpolations: LinearInterpolation
using Dates
using DBInterface: execute
using Dictionaries
using DiffEqCallbacks
using DifferentialEquations
using Graphs
using Legolas: Legolas, @schema, @version, validate
using OrdinaryDiffEq
using SciMLBase
using SparseArrays
using SQLite: SQLite, DB, Query
using Tables: columntable
using TimerOutputs

const to = TimerOutput()
TimerOutputs.complement!()

include("config.jl")
include("io.jl")
# include("validation.jl")
include("utils.jl")
include("lib.jl")
include("solve.jl")
include("create.jl")
include("construction.jl")
include("bmi.jl")

end  # module Ribasim
