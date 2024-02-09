using Configurations
using Dates
using InteractiveUtils
using Legolas
using OteraEngine
using Ribasim

pythontype(::Type{<:AbstractString}) = "Series[str]"
pythontype(::Type{<:Integer}) = "Series[int]"
pythontype(::Type{<:AbstractFloat}) = "Series[float]"
pythontype(::Type{<:Number}) = "Series[float]"
pythontype(::Type{<:Bool}) = "Series[pa.BOOL]" # pa.BOOL is a nullable boolean type, bool is not nullable
pythontype(::Type{<:Enum}) = "Series[str]"
pythontype(::Type{<:DateTime}) = "Series[Timestamp]"
pythontype(::Type{<:Any}) = "Series[Any]"
function pythontype(T::Union)
    nonmissingtypes = filter(x -> x != Missing, Base.uniontypes(T))
    return join(map(pythontype, nonmissingtypes), " | ")
end

isnullable(_) = "False"
isnullable(T::Union) = typeintersect(T, Missing) == Missing ? "True" : "False"

function strip_prefix(T::DataType)
    n = string(T)
    (p, _) = occursin('V', n) ? rsplit(n, 'V'; limit = 2) : (n, "")
    return string(last(rsplit(p, '.'; limit = 2)))
end

function get_models()
    """
    Set up models including field properties for all subtypes of Legolas.AbstractRecord.
    """
    [
        (
            name = strip_prefix(T),
            fields = zip(
                fieldnames(T),
                map(pythontype, fieldtypes(T)),
                map(isnullable, fieldtypes(T)),
            ),
        ) for T in subtypes(Legolas.AbstractRecord)
    ]
end

# Setup template with whitespace settings that mainly strips whitespace.
# See model.py.jinja for the layout of the template.
model_template = Template(
    normpath(@__DIR__, "templates", "model.py.jinja");
    config = Dict("trim_blocks" => true, "lstrip_blocks" => true, "autoescape" => false),
)

# Write schemas.py
open(normpath(@__DIR__, "..", "python", "ribasim", "ribasim", "schemas.py"), "w") do io
    init = Dict("models" => get_models())
    println(io, model_template(; init = init))
end
