from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd
import pytest
import ribasim
import tomli
from pandas import DataFrame
from pandas.testing import assert_frame_equal
from pydantic import ValidationError
from ribasim import Model, Node, Solver
from ribasim.nodes import basin, flow_boundary, flow_demand, pump, user_demand
from ribasim.utils import UsedIDs
from shapely.geometry import Point


def __assert_equal(a: DataFrame, b: DataFrame) -> None:
    """Lenient version of pandas.testing.assert_frame_equal."""
    if a is None and b is None:
        return
    elif a is None or b is None:
        assert False

    a = a.reset_index(drop=True)
    b = b.reset_index(drop=True)

    assert_frame_equal(a, b)


def test_basic(basic, tmp_path):
    model_orig = basic
    toml_path = tmp_path / "basic/ribasim.toml"
    assert model_orig.filepath is None
    model_orig.write(toml_path)
    assert model_orig.filepath == toml_path
    model_loaded = Model.read(toml_path)
    assert model_loaded.filepath == toml_path

    with open(toml_path, "rb") as f:
        toml_dict = tomli.load(f)

    assert toml_dict["ribasim_version"] == ribasim.__version__

    __assert_equal(model_orig.edge.df, model_loaded.edge.df)
    __assert_equal(model_orig.node_table().df, model_loaded.node_table().df)
    assert model_loaded.basin.time.df is None


def test_basic_arrow(basic_arrow, tmp_path):
    model_orig = basic_arrow
    model_orig.write(tmp_path / "basic_arrow/ribasim.toml")
    model_loaded = Model.read(tmp_path / "basic_arrow/ribasim.toml")

    __assert_equal(model_orig.basin.profile.df, model_loaded.basin.profile.df)


def test_basic_transient(basic_transient, tmp_path):
    model_orig = basic_transient
    model_orig.write(tmp_path / "basic_transient/ribasim.toml")
    model_loaded = Model.read(tmp_path / "basic_transient/ribasim.toml")

    __assert_equal(model_orig.edge.df, model_loaded.edge.df)

    time = model_loaded.basin.time
    assert model_orig.basin.time.df.time.iloc[0] == time.df.time.iloc[0]
    assert time.df.node_id.dtype == "int32[pyarrow]"
    __assert_equal(model_orig.basin.time.df, time.df)
    assert time.df.shape == (1468, 6)


@pytest.mark.xfail(reason="Needs implementation")
def test_pydantic():
    pass
    # static_data_bad = pd.DataFrame(data={"node_id": [1, 2, 3]})
    # test that it throws on missing flow_rate


def test_repr():
    pump_static = pump.Static(flow_rate=[1.0, -1.0, 0.0])

    assert repr(pump_static).startswith("Pump / static")
    # Ensure _repr_html doesn't error
    assert isinstance(pump_static._repr_html_(), str)


def test_extra_columns():
    pump_static = pump.Static(meta_id=[-1], flow_rate=[1.2])
    assert "meta_id" in pump_static.df.columns
    assert pump_static.df.meta_id.iloc[0] == -1

    with pytest.raises(ValidationError):
        # Extra column "extra" needs "meta_" prefix
        pump.Static(extra=[-2], flow_rate=[1.2])


def test_index_tables():
    p = pump.Static(flow_rate=[1.2])
    assert p.df.index.name == "fid"
    # Index name is applied by _name_index
    df = p.df.reset_index(drop=True)
    assert df.index.name is None
    p.df = df
    assert p.df.index.name == "fid"


def test_extra_spatial_columns():
    model = Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
        solver=Solver(algorithm="Tsit5"),
    )

    model.basin.add(
        Node(1, Point(0, 0), meta_id=1),
        [basin.Profile(area=1000.0, level=[0.0, 1.0]), basin.State(level=[1.0])],
    )
    node = Node(2, Point(1, 0.5, 3.0), meta_id=2)
    assert not node.geometry.has_z
    model.user_demand.add(
        node,
        [
            user_demand.Static(
                demand=[1e-4], return_factor=0.9, min_level=0.9, demand_priority=1
            )
        ],
    )

    model.edge.add(model.basin[1], model.user_demand[2], meta_foo=1)
    assert "meta_foo" in model.edge.df.columns
    assert "meta_id" in model.node_table().df.columns

    with pytest.raises(ValidationError):
        model.basin.add(
            Node(3, Point(0, 0), foo=1),
            [basin.Profile(area=1000.0, level=[0.0, 1.0]), basin.State(level=[1.0])],
        )
    with pytest.raises(ValidationError):
        model.user_demand.add(
            Node(4, Point(1, -0.5), meta_id=3),
            [
                user_demand.Static(
                    demand=[1e-4], return_factor=0.9, min_level=0.9, demand_priority=1
                )
            ],
        )
        model.edge.add(model.basin[1], model.user_demand[4], foo=1)


def test_edge_autoincrement(basic):
    model = basic
    model.edge.df = model.edge.df.iloc[0:0]  # clear the table
    model.edge._used_edge_ids = UsedIDs()  # and reset the counter

    model.edge.add(model.basin[1], model.manning_resistance[2], edge_id=20)
    assert model.edge.df.index[-1] == 20

    model.edge.add(model.manning_resistance[2], model.basin[3])
    assert model.edge.df.index[-1] == 21

    # Can use any remaining positive integer
    model.edge.add(model.basin[3], model.tabulated_rating_curve[8], edge_id=1)
    assert model.edge.df.index[-1] == 1

    with pytest.raises(
        ValueError,
        match="Edge IDs have to be unique, but 1 already exists.",
    ):
        model.edge.add(
            model.linear_resistance[10],
            model.level_boundary[17],
            edge_id=1,
        )


def test_node_autoincrement():
    model = Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
        solver=Solver(algorithm="Tsit5"),
    )

    model.basin.add(Node(20, Point(0, 0)), [basin.State(level=[1.0])])
    with pytest.raises(
        ValueError, match="Node IDs have to be unique, but 20 already exists."
    ):
        model.user_demand.add(
            Node(20, Point(1, 0.5)),
            [
                user_demand.Static(
                    demand=[1e-4], return_factor=0.9, min_level=0.9, demand_priority=1
                )
            ],
        )

    nbasin = model.basin.add(Node(geometry=Point(0, 0)), [basin.State(level=[1.0])])
    assert nbasin.node_id == 21

    # Can use any remaining positive integer
    model.basin.add(Node(1, geometry=Point(0, 0)), [basin.State(level=[1.0])])
    nbasin = model.basin.add(Node(geometry=Point(0, 0)), [basin.State(level=[1.0])])
    assert nbasin.node_id == 22

    model.basin.add(Node(100, geometry=Point(0, 0)), [basin.State(level=[1.0])])

    nbasin = model.basin.add(Node(geometry=Point(0, 0)), [basin.State(level=[1.0])])
    assert nbasin.node_id == 101


def test_node_autoincrement_existing_model(basic, tmp_path):
    model = basic

    model.write(tmp_path / "ribasim.toml")
    nmodel = Model.read(tmp_path / "ribasim.toml")

    assert nmodel._used_node_ids.max_node_id == 17
    assert nmodel._used_node_ids.node_ids == set(range(1, 18)) - {13}

    assert nmodel.edge._used_edge_ids.max_node_id == 16
    assert nmodel.edge._used_edge_ids.node_ids == set(range(1, 17))


def test_node_empty_geometry():
    model = Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
    )

    with pytest.raises(ValueError, match="Node geometry must be a valid Point"):
        model.user_demand.add(
            Node(),
            [
                user_demand.Static(
                    demand=[1e-4], return_factor=0.9, min_level=0.9, demand_priority=1
                )
            ],
        )
    with pytest.raises(ValueError, match="Node geometry must be a valid Point"):
        model.user_demand.add(
            Node(2),
            [
                user_demand.Static(
                    demand=[1e-4], return_factor=0.9, min_level=0.9, demand_priority=1
                )
            ],
        )


def test_sort(level_range, tmp_path):
    model = level_range
    table = model.discrete_control.condition
    edge = model.edge

    # apply a wrong sort, then call the sort method to restore order
    table.df.sort_values("greater_than", ascending=False, inplace=True)
    assert table.df.iloc[0]["greater_than"] == 15.0
    assert table._sort_keys == [
        "node_id",
        "compound_variable_id",
        "greater_than",
    ]
    table.sort()
    assert table.df.iloc[0]["greater_than"] == 5.0

    # The edge table is not sorted
    assert edge.df.iloc[1]["from_node_id"] == 3

    # re-apply wrong sort, then check if it gets sorted on write
    table.df.sort_values("greater_than", ascending=False, inplace=True)
    model.write(tmp_path / "basic/ribasim.toml")
    # write sorts the model in place
    assert table.df.iloc[0]["greater_than"] == 5.0
    model_loaded = ribasim.Model.read(filepath=tmp_path / "basic/ribasim.toml")
    table_loaded = model_loaded.discrete_control.condition
    edge_loaded = model_loaded.edge
    assert table_loaded.df.iloc[0]["greater_than"] == 5.0
    assert edge.df.iloc[1]["from_node_id"] == 3
    __assert_equal(table.df, table_loaded.df)
    __assert_equal(edge.df, edge_loaded.df)


def test_roundtrip(trivial, tmp_path):
    model1 = trivial
    # set custom Edge index
    model1.edge.df.index = pd.Index([15, 12], name="edge_id")
    model1dir = tmp_path / "model1"
    model2dir = tmp_path / "model2"
    # read a model and then write it to a different path
    model1.write(model1dir / "ribasim.toml")
    model2 = Model.read(model1dir / "ribasim.toml")
    model2.write(model2dir / "ribasim.toml")

    assert (model1dir / "database.gpkg").is_file()
    assert (model2dir / "database.gpkg").is_file()

    assert (model1dir / "ribasim.toml").read_text() == (
        model2dir / "ribasim.toml"
    ).read_text()

    # check if custom Edge indexes are retained (sorted)
    assert (model1.edge.df.index == [12, 15]).all()
    assert (model2.edge.df.index == [12, 15]).all()

    # check if all tables are the same
    __assert_equal(model1.node_table().df, model2.node_table().df)
    __assert_equal(model1.edge.df, model2.edge.df)
    for node1, node2 in zip(model1._nodes(), model2._nodes()):
        for table1, table2 in zip(node1._tables(), node2._tables()):
            __assert_equal(table1.df, table2.df)


def test_datetime_timezone():
    # Due to a pydantic issue, a time zone was added.
    # https://github.com/Deltares/Ribasim/issues/1282
    model = ribasim.Model(
        starttime="2000-01-01", endtime="2001-01-01 00:00:00", crs="EPSG:28992"
    )
    assert isinstance(model.starttime, datetime)
    assert isinstance(model.endtime, datetime)
    assert model.starttime.tzinfo is None
    assert model.endtime.tzinfo is None


def test_minimal_toml():
    # Check if the TOML used in QGIS tests is still valid.
    toml_path = Path(__file__).parents[3] / "ribasim_qgis/tests/data/simple_valid.toml"
    (toml_path.parent / "database.gpkg").touch()  # database file must exist for `read`
    model = ribasim.Model.read(toml_path)
    assert model.crs == "EPSG:28992"


def test_closed_model(basic, tmp_path):
    # Test whether we can write to a just opened model
    # implicitly testing that the database is closed after read
    toml_path = tmp_path / "basic/ribasim.toml"
    basic.write(toml_path)
    model = ribasim.Model.read(toml_path)
    model.write(toml_path)


def test_arrow_dtype():
    # Below millisecond precision is not supported
    with pytest.raises(ValidationError):
        flow_boundary.Time(
            time=["2021-01-01 00:00:00.1234"],
            flow_rate=np.ones(1),
        )

    # Extra columns don't get coerced to Arrow types
    df = flow_boundary.Time(
        time=["2021-01-01 00:00:00.123", "2021-01-01 00:00:00.456"],
        flow_rate=[1, 2.2],
        meta_obj=["foo", "bar"],
        meta_str=pd.Series(["a", pd.NA], dtype="string[pyarrow]"),
    ).df

    assert (df["node_id"] == 0).all()
    assert df["node_id"].dtype == "int32[pyarrow]"
    assert df["time"].dtype == "timestamp[ms][pyarrow]"
    assert df["time"].dt.tz is None
    assert df["time"].diff().iloc[1] == pd.Timedelta("333ms")
    assert df["flow_rate"].dtype == "double[pyarrow]"
    assert df["meta_obj"].dtype == object
    assert df["meta_str"].dtype == "string[pyarrow]"
    assert df["meta_str"].isna().iloc[1]

    # Check a string column that is part of the schema and a boolean column
    df = pump.Static(
        flow_rate=np.ones(2),
        control_state=["foo", pd.NA],
        active=[None, False],
    ).df

    assert df["control_state"].dtype == "string[pyarrow]"
    assert df["active"].dtype == "bool[pyarrow]"
    assert df["active"].isna().iloc[0]

    # Optional integer column
    df = flow_demand.Static(
        demand=[1, 2.2],
        demand_priority=[1, pd.NA],
    ).df

    assert df["demand_priority"].dtype == "int32[pyarrow]"
    assert df["demand_priority"].isna().iloc[1]

    # Missing optional integer column
    df = flow_demand.Static(
        demand=[1, 2.2],
    ).df

    assert df["demand_priority"].dtype == "int32[pyarrow]"
    assert df["demand_priority"].isna().all()
