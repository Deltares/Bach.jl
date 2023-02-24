function get_ids(db::DB)::Vector{Int}
    return only(execute(columntable, db, "select fid from Node"))
end

function get_ids(db::DB, nodetype)::Vector{Int}
    sql = "select fid from Node where type = '$nodetype'"
    return only(execute(columntable, db, sql))
end

tablenames(db::DB)::Vector{String} = [t.name for t in SQLite.tables(db)]

tablename(nodetype, kind) = string(nodetype, " / ", kind)

function split_tablename(tablename)
    parts = split(tablename, " / ")
    if length(parts) == 1
        nodetype = only(parts)
        kind = "static"
    else
        @assert length(parts) == 2 "Invalid table name"
        nodetype, kind = parts
    end
    return Symbol(nodetype), Symbol(kind)
end
