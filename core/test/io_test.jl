@testitem "relativepath" begin
    using Dates

    # relative to tomldir
    toml = Ribasim.Toml(;
        starttime = now(),
        endtime = now(),
        database = "path/to/file",
        input_dir = ".",
        results_dir = "results",
        ribasim_version = string(Ribasim.pkgversion(Ribasim)),
    )
    config = Ribasim.Config(toml, "model")
    @test Ribasim.input_path(config, "path/to/file") ==
          normpath("model", "path", "to", "file")

    # also relative to inputdir
    toml = Ribasim.Toml(;
        starttime = now(),
        endtime = now(),
        database = "path/to/file",
        input_dir = "input",
        results_dir = "results",
        ribasim_version = string(Ribasim.pkgversion(Ribasim)),
    )
    config = Ribasim.Config(toml, "model")
    @test Ribasim.input_path(config, "path/to/file") ==
          normpath("model", "input", "path", "to", "file")

    # absolute path
    toml = Ribasim.Toml(;
        starttime = now(),
        endtime = now(),
        database = "/path/to/file",
        input_dir = ".",
        results_dir = "results",
        ribasim_version = string(Ribasim.pkgversion(Ribasim)),
    )
    config = Ribasim.Config(toml)
    @test Ribasim.input_path(config, "/path/to/file") == abspath("/path/to/file")
end

@testitem "time" begin
    using Dates

    t0 = DateTime(2020)
    @test Ribasim.datetime_since(0.0, t0) === t0
    @test Ribasim.datetime_since(1.0, t0) === t0 + Second(1)
    @test Ribasim.datetime_since(pi, t0) === DateTime("2020-01-01T00:00:03.142")
    @test Ribasim.seconds_since(t0, t0) === 0.0
    @test Ribasim.seconds_since(t0 + Second(1), t0) === 1.0
    @test Ribasim.seconds_since(DateTime("2020-01-01T00:00:03.142"), t0) ≈ 3.142
end

@testitem "findlastgroup" begin
    using Ribasim: NodeID, findlastgroup

    @test findlastgroup(NodeID(:Pump, 2), NodeID.(:Pump, [5, 4, 2, 2, 5, 2, 2, 2, 1])) ===
          6:8
    @test findlastgroup(NodeID(:Pump, 2), NodeID.(:Pump, [2])) === 1:1
    @test findlastgroup(NodeID(:Pump, 3), NodeID.(:Pump, [5, 4, 2, 2, 5, 2, 2, 2, 1])) ===
          1:0
end

@testitem "table sort" begin
    import Arrow
    import Legolas
    using StructArrays: StructVector
    import SQLite
    import Tables

    "Convert an in-memory table to a memory mapped Arrow table"
    function to_arrow_table(
        path,
        table::StructVector{T},
    )::StructVector{T} where {T <: Legolas.AbstractRecord}
        open(path; write = true) do io
            Arrow.write(io, table)
        end
        table = Arrow.Table(path)
        nt = Tables.columntable(table)
        return StructVector{T}(nt)
    end

    toml_path =
        normpath(@__DIR__, "../../generated_testmodels/basic_transient/ribasim.toml")
    config = Ribasim.Config(toml_path)
    db_path = Ribasim.input_path(config, config.database)
    db = SQLite.DB(db_path)

    # load a sorted table
    table = Ribasim.load_structvector(db, config, Ribasim.BasinTimeV1)
    by = Ribasim.sort_by_function(table)
    @test by == Ribasim.sort_by_time_id
    # reverse it so it needs sorting
    reversed_table = sort(table; by, rev = true)
    @test issorted(table; by)
    @test !issorted(reversed_table; by)
    # create arrow memory mapped copies
    # TODO support cleanup, see https://github.com/apache/arrow-julia/issues/61
    arrow_table = to_arrow_table(tempname(; cleanup = false), table)
    reversed_arrow_table = to_arrow_table(tempname(; cleanup = false), reversed_table)

    @test table.node_id[1] == 1
    @test reversed_table.node_id[1] == 9
    # sorted_table! sorts reversed_table
    Ribasim.sorted_table!(reversed_table)
    @test reversed_table.node_id[1] == 1

    # arrow_table is already sorted, stays memory mapped
    Ribasim.sorted_table!(arrow_table)
    @test_throws ReadOnlyMemoryError arrow_table.node_id[1] = 0
    # reversed_arrow_table throws an AssertionError
    @test_throws "not sorted as required" Ribasim.sorted_table!(reversed_arrow_table)
end

@testitem "results" begin
    using SciMLBase: successful_retcode
    import Arrow

    toml_path = normpath(@__DIR__, "../../generated_testmodels/bucket/ribasim.toml")
    @test ispath(toml_path)
    config = Ribasim.Config(toml_path)
    model = Ribasim.run(config)
    @test successful_retcode(model)

    path = Ribasim.results_path(config, Ribasim.RESULTS_FILENAME.basin)
    bytes = read(path)
    tbl = Arrow.Table(bytes)
    ribasim_version = string(pkgversion(Ribasim))
    @test Arrow.getmetadata(tbl) ===
          Base.ImmutableDict("ribasim_version" => ribasim_version)
end
