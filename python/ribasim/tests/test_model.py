import re
from sqlite3 import connect

import numpy as np
import pandas as pd
import pytest
import xugrid
from pydantic import ValidationError
from pyproj import CRS
from ribasim import Node
from ribasim.config import Solver
from ribasim.geometry.edge import NodeData
from ribasim.input_base import esc_id
from ribasim.model import Model
from ribasim.nodes import (
    basin,
    level_boundary,
    outlet,
    pid_control,
    pump,
)
from ribasim_testmodels import (
    basic_model,
    outlet_model,
    pid_control_equation_model,
    trivial_model,
)
from shapely import Point


def test_repr(basic):
    representation = repr(basic).split("\n")
    assert representation[0] == "ribasim.Model("


def test_solver():
    solver = Solver()
    assert solver.algorithm == "QNDF"  # default
    assert solver.saveat == 86400.0

    solver = Solver(saveat=3600.0)
    assert solver.saveat == 3600.0

    solver = Solver(saveat=float("inf"))
    assert solver.saveat == float("inf")

    solver = Solver(saveat=0)
    assert solver.saveat == 0

    with pytest.raises(ValidationError):
        Solver(saveat="a")


@pytest.mark.xfail(reason="Needs refactor")
def test_invalid_node_type(basic):
    # Add entry with invalid node type
    basic.node.static = basic.node.df._append(
        {"node_type": "InvalidNodeType", "geometry": Point(0, 0)}, ignore_index=True
    )

    with pytest.raises(
        TypeError,
        match=re.escape("Invalid node types detected: [InvalidNodeType].") + ".+",
    ):
        basic.validate_model_node_types()


def test_parent_relationship(basic):
    model = basic
    assert model.pump._parent == model
    assert model.pump._parent_field == "pump"


def test_exclude_unset(basic):
    model = basic
    model.solver.saveat = 86400.0
    d = model.model_dump(exclude_unset=True, exclude_none=True, by_alias=True)
    assert "solver" in d
    assert d["solver"]["saveat"] == 86400.0


def test_invalid_node_id():
    with pytest.raises(
        ValueError,
        match=r".* Input should be greater than or equal to 0 .*",
    ):
        Node(-1, Point(7.0, 7.0))


def test_tabulated_rating_curve_model(tabulated_rating_curve, tmp_path):
    model_orig = tabulated_rating_curve
    model_orig.set_crs(model_orig.crs)
    basin_area = tabulated_rating_curve.basin.area.df
    assert basin_area is not None
    assert basin_area.geometry.geom_type.iloc[0] == "MultiPolygon"
    assert basin_area.crs == CRS.from_epsg(28992)
    model_orig.write(tmp_path / "tabulated_rating_curve/ribasim.toml")
    model_new = Model.read(tmp_path / "tabulated_rating_curve/ribasim.toml")
    pd.testing.assert_series_equal(
        model_orig.tabulated_rating_curve.time.df.time,
        model_new.tabulated_rating_curve.time.df.time,
    )


def test_plot(discrete_control_of_pid_control):
    discrete_control_of_pid_control.plot()


def test_write_adds_fid_in_tables(basic, tmp_path):
    model_orig = basic
    # for node an explicit index was provided
    nrow = len(model_orig.basin.node.df)
    assert model_orig.basin.node.df.index.name == "node_id"

    # for edge an explicit index was provided
    nrow = len(model_orig.edge.df)
    assert model_orig.edge.df.index.name == "edge_id"
    assert model_orig.edge.df.index.equals(pd.RangeIndex(1, nrow + 1))

    model_orig.write(tmp_path / "basic/ribasim.toml")
    with connect(tmp_path / "basic/database.gpkg") as connection:
        query = f"select * from {esc_id('Basin / profile')}"
        df = pd.read_sql_query(query, connection)
        assert "fid" in df.columns

        query = "select node_id from Node"
        df = pd.read_sql_query(query, connection)
        assert "node_id" in df.columns

        query = "select edge_id from Edge"
        df = pd.read_sql_query(query, connection)
        assert "edge_id" in df.columns


def test_node_table(basic):
    model = basic
    node = model.node_table()
    df = node.df
    assert df.geometry.is_unique
    assert df.index.dtype == np.int32
    assert df.subnetwork_id.dtype == pd.Int32Dtype()
    assert df.node_type.iloc[0] == "Basin"
    assert df.node_type.iloc[-1] == "LevelBoundary"
    assert df.crs == CRS.from_epsg(28992)


def test_edge_table(basic):
    model = basic
    df = model.edge.df
    assert df.geometry.is_unique
    assert df.from_node_id.dtype == np.int32
    assert df.subnetwork_id.dtype == pd.Int32Dtype()
    assert df.crs == CRS.from_epsg(28992)


def test_duplicate_edge(basic):
    model = basic
    with pytest.raises(
        ValueError,
        match=re.escape(
            "Edges have to be unique, but edge with from_node_id 16 to_node_id 1 already exists."
        ),
    ):
        model.edge.add(
            model.flow_boundary[16],
            model.basin[1],
            name="duplicate",
        )


def test_connectivity(trivial):
    model = trivial
    with pytest.raises(
        ValueError,
        match=re.escape(
            "Node of type Basin cannot be upstream of node of type Terminal"
        ),
    ):
        model.edge.add(model.basin[6], model.terminal[2147483647])


def test_maximum_flow_neighbor(outlet):
    model = outlet
    with pytest.raises(
        ValueError,
        match=re.escape("Node 2 can have at most 1 flow edge outneighbor(s) (got 1)"),
    ):
        model.basin.add(
            Node(4, Point(1.0, 1.0)),
            [
                basin.Profile(area=[1000.0, 1000.0], level=[0.0, 1.0]),
                basin.State(level=[0.0]),
            ],
        )
        model.edge.add(model.outlet[2], model.basin[4])

    with pytest.raises(
        ValueError,
        match=re.escape("Node 2 can have at most 1 flow edge inneighbor(s) (got 1)"),
    ):
        model.level_boundary.add(
            Node(5, Point(0.0, 1.0)),
            [level_boundary.Static(level=[3.0])],
        )
        model.edge.add(model.level_boundary[5], model.outlet[2])


def test_maximum_control_neighbor(pid_control_equation):
    model = pid_control_equation
    with pytest.raises(
        ValueError,
        match=re.escape("Node 2 can have at most 1 control edge inneighbor(s) (got 1)"),
    ):
        model.pid_control.add(
            Node(5, Point(0.5, -1.0)),
            [
                pid_control.Static(
                    listen_node_id=[1],
                    target=10.0,
                    proportional=-2.5,
                    integral=-0.001,
                    derivative=10.0,
                )
            ],
        )
        model.edge.add(
            model.pid_control[5],
            model.pump[2],
        )
    with pytest.raises(
        ValueError,
        match=re.escape(
            "Node 4 can have at most 1 control edge outneighbor(s) (got 1)"
        ),
    ):
        model.pump.add(Node(6, Point(-1.0, 0)), [pump.Static(flow_rate=[0.0])])
        model.edge.add(
            model.pid_control[4],
            model.pump[6],
        )


def test_minimum_flow_neighbor():
    model = Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
        solver=Solver(),
    )

    model.basin.add(
        Node(3, Point(2.0, 0.0)),
        [
            basin.Profile(area=[1000.0, 1000.0], level=[0.0, 1.0]),
            basin.State(level=[0.0]),
        ],
    )
    model.outlet.add(
        Node(2, Point(1.0, 0.0)),
        [outlet.Static(flow_rate=[1e-3], min_crest_level=[2.0])],
    )
    model.terminal.add(Node(4, Point(3.0, -2.0)))

    with pytest.raises(
        ValueError,
        match=re.escape("Minimum inneighbor or outneighbor unsatisfied"),
    ):
        model.edge.add(model.basin[3], model.outlet[2])
        model.write("test.toml")


def test_indexing(basic):
    model = basic

    result = model.basin[1]
    assert isinstance(result, NodeData)

    # Also test with a numpy type
    result = model.basin[np.int32(1)]
    assert isinstance(result, NodeData)

    with pytest.raises(TypeError, match="Basin index must be an integer, not list"):
        model.basin[[1, 3, 6]]

    result = model.basin.static[1]
    assert isinstance(result, pd.DataFrame)

    result = model.basin.static[[1, 3, 6]]
    assert isinstance(result, pd.DataFrame)

    with pytest.raises(
        IndexError, match=re.escape("Basin / static does not contain node_id: [2]")
    ):
        model.basin.static[2]

    with pytest.raises(
        ValueError,
        match=re.escape("Cannot index into Basin / time: it contains no data."),
    ):
        model.basin.time[1]


@pytest.mark.parametrize(
    "model",
    [basic_model(), outlet_model(), pid_control_equation_model(), trivial_model()],
)
def test_xugrid(model, tmp_path):
    uds = model.to_xugrid(add_flow=False)
    assert isinstance(uds, xugrid.UgridDataset)
    assert uds.grid.edge_dimension == "ribasim_nEdges"
    assert uds.grid.node_dimension == "ribasim_nNodes"
    assert uds.grid.crs == CRS.from_epsg(28992)
    assert uds.node_id.dtype == np.int32
    uds.ugrid.to_netcdf(tmp_path / "ribasim.nc")
    uds = xugrid.open_dataset(tmp_path / "ribasim.nc")
    assert uds.attrs["Conventions"] == "CF-1.9 UGRID-1.0"

    with pytest.raises(FileNotFoundError, match="Model must be written to disk"):
        model.to_xugrid(add_flow=True)

    model.write(tmp_path / "ribasim.toml")
    with pytest.raises(FileNotFoundError, match="Cannot find results"):
        model.to_xugrid(add_flow=True)
    with pytest.raises(FileNotFoundError, match="or allocation is not used"):
        model.to_xugrid(add_flow=False, add_allocation=True)
    with pytest.raises(ValueError, match="Cannot add both allocation and flow results"):
        model.to_xugrid(add_flow=True, add_allocation=True)


def test_to_crs(bucket: Model):
    model = bucket

    # Reproject to World Geodetic System 1984
    model.to_crs("EPSG:4326")

    # Assert that the bucket is still at Deltares' headquarter
    assert model.basin.node.df["geometry"].iloc[0].x == pytest.approx(4.38, abs=0.1)
    assert model.basin.node.df["geometry"].iloc[0].y == pytest.approx(51.98, abs=0.1)


def test_styles(tabulated_rating_curve: Model, tmp_path):
    model = tabulated_rating_curve

    model.write(tmp_path / "basic" / "ribasim.toml")
    with connect(tmp_path / "basic" / "database.gpkg") as conn:
        assert conn.execute("SELECT COUNT(*) FROM layer_styles").fetchone()[0] == 3
