from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import ribasim
from ribasim.config import Node
from ribasim.input_base import TableModel
from ribasim.nodes import (
    basin,
    flow_boundary,
    fractional_flow,
    level_boundary,
    linear_resistance,
    manning_resistance,
    outlet,
    pump,
    tabulated_rating_curve,
)
from shapely.geometry import Point


def basic_model() -> ribasim.Model:
    # Setup model
    model = ribasim.Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
    )
    model.logging = ribasim.Logging(verbosity="debug")

    # Setup basins
    level = [0.0, 1.0]
    node_data: list[TableModel[Any]] = [
        basin.Profile(area=[0.01, 1000.0], level=level),
        basin.Static(
            potential_evaporation=[0.001 / 86400], precipitation=[0.002 / 86400]
        ),
        basin.State(level=[0.04471158417652035]),
    ]
    node_ids = [1, 3, 6, 9]
    node_geometries = [
        Point(0.0, 0.0),
        Point(2.0, 0.0),
        Point(3.0, 2.0),
        Point(5.0, 0.0),
    ]
    for node_id, node_geometry in zip(node_ids, node_geometries):
        model.basin.add(
            Node(node_id, node_geometry),
            [
                basin.Subgrid(
                    subgrid_id=[node_id] * 2, basin_level=level, subgrid_level=level
                ),
                *node_data,
            ],
        )

    # Setup linear resistance
    model.linear_resistance.add(
        Node(12, Point(2.0, 1.0)), [linear_resistance.Static(resistance=[5e3])]
    )
    model.linear_resistance.add(
        Node(10, Point(6.0, 0.0)),
        [linear_resistance.Static(resistance=[(3600.0 * 24) / 100.0])],
    )

    # Setup Manning resistance
    model.manning_resistance.add(
        Node(2, Point(1.0, 0.0)),
        [
            manning_resistance.Static(
                length=[900.0],
                manning_n=[0.04],
                profile_width=[1.0],
                profile_slope=[3.0],
            )
        ],
    )

    # Setup tabulated rating curve
    model.tabulated_rating_curve.add(
        Node(4, Point(3.0, 0.0)),
        [
            tabulated_rating_curve.Static(
                level=[0.0, 1.0],
                flow_rate=[
                    0.0,
                    1000.0 * 0.01 / 86400,
                ],  # Discharge: lose 1% of storage volume per day at storage = 1000.0.
            )
        ],
    )

    # Setup fractional flows
    model.fractional_flow.add(
        Node(5, Point(3.0, 1.0)), [fractional_flow.Static(fraction=[0.3])]
    )
    model.fractional_flow.add(
        Node(8, Point(4.0, 0.0)), [fractional_flow.Static(fraction=[0.6])]
    )
    model.fractional_flow.add(
        Node(13, Point(3.0, -1.0)), [fractional_flow.Static(fraction=[0.1])]
    )

    # Setup pump
    model.pump.add(Node(7, Point(4.0, 1.0)), [pump.Static(flow_rate=[0.5 / 3600])])

    # Setup flow boundary
    flow_boundary_data = [flow_boundary.Static(flow_rate=[1e-4])]
    model.flow_boundary.add(Node(15, Point(3.0, 3.0)), flow_boundary_data)
    model.flow_boundary.add(Node(16, Point(0.0, 1.0)), flow_boundary_data)

    # Setup level boundary
    model.level_boundary.add(
        Node(11, Point(2.0, 2.0)), [level_boundary.Static(level=[1.0])]
    )
    model.level_boundary.add(
        Node(17, Point(6.0, 1.0)), [level_boundary.Static(level=[1.5])]
    )

    # Setup terminal
    model.terminal.add(Node(14, Point(3.0, -2.0)))

    # Setup edges
    model.edge.add(model.basin[1], model.manning_resistance[2])
    model.edge.add(model.manning_resistance[2], model.basin[3])
    model.edge.add(
        model.basin[3],
        model.tabulated_rating_curve[4],
    )
    model.edge.add(
        model.tabulated_rating_curve[4],
        model.fractional_flow[5],
    )
    model.edge.add(
        model.tabulated_rating_curve[4],
        model.fractional_flow[8],
    )
    model.edge.add(model.fractional_flow[5], model.basin[6])
    model.edge.add(model.basin[6], model.pump[7])
    model.edge.add(model.fractional_flow[8], model.basin[9])
    model.edge.add(model.pump[7], model.basin[9])
    model.edge.add(model.basin[9], model.linear_resistance[10])
    model.edge.add(
        model.level_boundary[11],
        model.linear_resistance[12],
    )
    model.edge.add(
        model.linear_resistance[12],
        model.basin[3],
    )
    model.edge.add(
        model.tabulated_rating_curve[4],
        model.fractional_flow[13],
    )
    model.edge.add(
        model.fractional_flow[13],
        model.terminal[14],
    )
    model.edge.add(
        model.flow_boundary[15],
        model.basin[6],
    )
    model.edge.add(
        model.flow_boundary[16],
        model.basin[1],
    )
    model.edge.add(
        model.linear_resistance[10],
        model.level_boundary[17],
    )

    return model


def basic_arrow_model() -> ribasim.Model:
    model = basic_model()
    model.basin.profile.set_filepath(Path("profile.arrow"))
    model.input_dir = Path("input")
    return model


def basic_transient_model() -> ribasim.Model:
    """Update the basic model with transient forcing"""

    model = basic_model()
    time = pd.date_range(model.starttime, model.endtime)
    day_of_year = time.day_of_year.to_numpy()
    seconds_per_day = 24 * 60 * 60
    evaporation = (
        (-1.0 * np.cos(day_of_year / 365.0 * 2 * np.pi) + 1.0)
        * 0.0025
        / seconds_per_day
    )
    rng = np.random.default_rng(seed=0)
    precipitation = (
        rng.lognormal(mean=-1.0, sigma=1.7, size=time.size) * 0.001 / seconds_per_day
    )

    timeseries = pd.DataFrame(
        data={
            "node_id": 1,
            "time": time,
            "drainage": 0.0,
            "potential_evaporation": evaporation,
            "infiltration": 0.0,
            "precipitation": precipitation,
            "urban_runoff": 0.0,
        }
    )
    df = model.basin.static.df
    assert df is not None
    basin_ids = df["node_id"].to_numpy()
    forcing = (
        pd.concat(
            [timeseries.assign(node_id=id) for id in basin_ids], ignore_index=True
        )
        .sort_values("time")
        .reset_index(drop=True)
    )

    state = pd.DataFrame(
        data={
            "node_id": basin_ids,
            "level": 1.4,
        }
    )
    model.basin.time = forcing  # type: ignore # TODO: Fix implicit typing from pydantic. See TableModel.check_dataframe
    model.basin.state = state  # type: ignore # TODO: Fix implicit typing from pydantic. See TableModel.check_dataframe

    return model


def tabulated_rating_curve_model() -> ribasim.Model:
    """
    Set up a model where the upstream Basin has two TabulatedRatingCurve attached.
    They both flow to the same downstream Basin, but one has a static rating curve,
    and the other one a time-varying rating curve.
    Only the upstream Basin receives a (constant) precipitation.
    """

    # Setup a model:
    model = ribasim.Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
    )

    # Setup tabulated rating curve:
    model.tabulated_rating_curve.add(
        Node(2, Point(1.0, 1.0)),
        [
            tabulated_rating_curve.Static(
                level=[0.0, 1.0], flow_rate=[0.0, 10 / 86400]
            ),
        ],
    )
    model.tabulated_rating_curve.add(
        Node(3, Point(1.0, -1.0)),
        [
            tabulated_rating_curve.Time(
                time=[
                    # test subsecond precision
                    pd.Timestamp("2020-01-01 00:00:00.000001"),
                    pd.Timestamp("2020-01"),
                    pd.Timestamp("2020-02"),
                    pd.Timestamp("2020-02"),
                    pd.Timestamp("2020-03"),
                    pd.Timestamp("2020-03"),
                ],
                level=[0.0, 1.0, 0.0, 1.1, 0.0, 1.2],
                flow_rate=[0.0, 10 / 86400, 0.0, 10 / 86400, 0.0, 10 / 86400],
            ),
        ],
    )

    # Setup the basins
    node_data: list[TableModel[Any]] = [
        basin.Profile(area=[0.01, 1000.0], level=[0.0, 1.0]),
        basin.State(level=[0.04471158417652035]),
    ]
    basin_geometry_1 = Point(0.0, 0.0)
    model.basin.add(
        Node(1, basin_geometry_1),
        [
            basin.Static(precipitation=[0.002 / 86400]),
            basin.Area(geometry=[basin_geometry_1.buffer(1.0)]),
            *node_data,
        ],
    )
    basin_geometry_2 = Point(2.0, 0.0)
    model.basin.add(
        Node(4, basin_geometry_2),
        [
            basin.Static(precipitation=[0.0]),
            basin.Area(geometry=[basin_geometry_2.buffer(1.0)]),
            *node_data,
        ],
    )
    model.edge.add(
        model.basin[1],
        model.tabulated_rating_curve[2],
    )
    model.edge.add(
        model.basin[1],
        model.tabulated_rating_curve[3],
    )
    model.edge.add(
        model.tabulated_rating_curve[2],
        model.basin[4],
    )
    model.edge.add(
        model.tabulated_rating_curve[3],
        model.basin[4],
    )
    return model


def outlet_model():
    """Set up a basic model with an outlet that encounters various physical constraints."""
    model = ribasim.Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
        solver=ribasim.Solver(saveat=0),
    )

    # Set up the basins
    model.basin.add(
        Node(3, Point(2.0, 0.0)),
        [
            basin.Profile(area=[1000.0, 1000.0], level=[0.0, 1.0]),
            basin.State(level=[1e-3]),
        ],
    )

    # Set up the level boundary
    model.level_boundary.add(
        Node(1, Point(0.0, 0.0)),
        [
            level_boundary.Time(
                time=[
                    "2020-01-01",
                    "2020-06-01",
                    "2021-01-01",
                ],
                level=[1.0, 3.0, 3.0],
            )
        ],
    )

    # Setup the outlet
    model.outlet.add(
        Node(2, Point(1.0, 0.0)),
        [outlet.Static(flow_rate=[1e-3], min_crest_level=[2.0])],
    )

    # Setup the edges
    model.edge.add(model.level_boundary[1], model.outlet[2])
    model.edge.add(model.outlet[2], model.basin[3])

    return model
