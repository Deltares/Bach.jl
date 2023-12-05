import re
from sqlite3 import connect

import pandas as pd
import pytest
from pydantic import ValidationError
from ribasim import Model, Solver
from shapely import Point

from python.ribasim.ribasim.input_base import esc_id


def test_repr(basic):
    representation = repr(basic).split("\n")
    assert representation[0] == "ribasim.Model("


def test_solver():
    solver = Solver()
    assert solver.algorithm == "QNDF"  # default
    assert solver.saveat == []

    solver = Solver(saveat=3600.0)
    assert solver.saveat == 3600.0

    solver = Solver(saveat=[3600.0, 7200.0])
    assert solver.saveat == [3600.0, 7200.0]

    with pytest.raises(ValidationError):
        Solver(saveat="a")


@pytest.mark.xfail(reason="Needs refactor")
def test_invalid_node_type(basic):
    # Add entry with invalid node type
    basic.node.static = basic.node.df._append(
        {"type": "InvalidNodeType", "geometry": Point(0, 0)}, ignore_index=True
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


def test_invalid_node_id(basic):
    model = basic

    # Add entry with invalid node ID
    df = model.pump.static.df._append(
        {"flow_rate": 1, "node_id": -1, "remarks": "", "active": True},
        ignore_index=True,
    )
    # Currently can't handle mixed NaN and None in a DataFrame
    df = df.where(pd.notna(df), None)
    model.pump.static.df = df

    with pytest.raises(
        ValueError,
        match=re.escape("Node IDs must be positive integers, got [-1]."),
    ):
        model.validate_model_node_field_ids()


@pytest.mark.xfail(reason="Should be reimplemented by the .add() API.")
def test_node_id_duplicate(basic):
    model = basic

    # Add duplicate node ID
    df = model.pump.static.df._append(
        {"flow_rate": 1, "node_id": 1, "remarks": "", "active": True}, ignore_index=True
    )
    # Currently can't handle mixed NaN and None in a DataFrame
    df = df.where(pd.notna(df), None)
    model.pump.static.df = df
    with pytest.raises(
        ValueError,
        match=re.escape("These node IDs were assigned to multiple node types: [1]."),
    ):
        model.validate_model_node_field_ids()


def test_node_ids_misassigned(basic):
    model = basic

    # Misassign node IDs
    model.pump.static.df.loc[0, "node_id"] = 8
    model.fractional_flow.static.df.loc[1, "node_id"] = 7

    with pytest.raises(ValueError, match="The node IDs in the field static.+"):
        model.validate_model_node_ids()


def test_node_ids_unsequential(basic):
    model = basic

    basin = model.basin

    basin.profile = pd.DataFrame(
        data={
            "node_id": [1, 1, 3, 3, 6, 6, 1000, 1000],
            "area": [0.01, 1000.0] * 4,
            "level": [0.0, 1.0] * 4,
        }
    )

    basin.static.df["node_id"] = [1, 3, 6, 1000]

    with pytest.raises(ValueError) as excinfo:
        model.validate_model_node_field_ids()

    assert (
        "Expected node IDs from 1 to 17 (the number of rows in self.network.node.df). These node IDs are missing: {9}. These node IDs are unexpected: {1000}."
        in str(excinfo.value)
    )


def test_tabulated_rating_curve_model(tabulated_rating_curve, tmp_path):
    model_orig = tabulated_rating_curve
    model_orig.write(tmp_path / "tabulated_rating_curve/ribasim.toml")
    Model.read(tmp_path / "tabulated_rating_curve/ribasim.toml")


def test_plot(discrete_control_of_pid_control):
    discrete_control_of_pid_control.plot()


def test_write_adds_fid_in_tables(basic, tmp_path):
    model_orig = basic
    model_orig.write(tmp_path / "basic/ribasim.toml")
    with connect(tmp_path / "basic/database.gpkg") as connection:
        query = f"select * from {esc_id('Basin / profile')}"
        df = pd.read_sql_query(query, connection, parse_dates=["time"])
        assert "fid" in df.columns
        fids = df.get("fid")
        assert fids.equals(pd.Series(range(1, len(fids) + 1)))
