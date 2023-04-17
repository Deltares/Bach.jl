"""
Generate JSON schemas for Ribasim input

Run with `julia --project=docs docs/gen_schema.jl`
"""

pushfirst!(LOAD_PATH, normpath(@__DIR__, "../core"))

using Ribasim
using JSON3
using Legolas
using InteractiveUtils
using Dates

jsontype(x) = jsontype(typeof(x))
jsontype(::Type{<:AbstractString}) = "string"
jsontype(::Type{<:Integer}) = "integer"
jsontype(::Type{<:AbstractFloat}) = "real"
jsontype(::Type{<:Number}) = "number"
jsontype(::Type{<:AbstractVector}) = "list"
jsontype(::Type{<:Bool}) = "boolean"
jsontype(::Type{<:Missing}) = "null"
jsontype(::Type{<:DateTime}) = "string"  # TODO: use unofficial date-time?
jsontype(::Type{<:Nothing}) = "null"
jsontype(::Type{<:Any}) = "object"
jsontype(T::Union) = unique(filter(!isequal("null"), jsontype.(Base.uniontypes(T))))

function strip_prefix(T::DataType)
    (p, v) = rsplit(string(T), 'V'; limit = 2)
    return string(last(rsplit(p, '.'; limit = 2)))
end

function gen_schema(T::DataType)
    name = strip_prefix(T)
    schema = Dict(
        "\$schema" => "https://json-schema.org/draft/2020-12/schema",
        "\$id" => "https://deltares.github.io/Ribasim/schema/$(name).schema.json",
        "title" => name,
        "description" => "A $(name) object based on $T",
        "type" => "object",
        "properties" => Dict{String, Dict}(),
        "required" => String[],
    )
    for (fieldname, fieldtype) in zip(fieldnames(T), fieldtypes(T))
        fieldname = string(fieldname)
        schema["properties"][fieldname] =
            Dict("description" => "$fieldname", "type" => jsontype(fieldtype))

        if !((fieldtype isa Union) && (fieldtype.a === Missing))
            push!(schema["required"], fieldname)
        end
    end
    open(normpath(@__DIR__, "schema", "$(name).schema.json"), "w") do io
        JSON3.pretty(io, schema)
        println(io)
    end
end

for T in subtypes(Legolas.AbstractRecord)
    gen_schema(T)
end
