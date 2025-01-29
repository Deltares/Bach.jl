from typing import Any

import numpy as np
import pandas as pd
from ribasim.config import Allocation, Experimental, Node, Solver
from ribasim.input_base import TableModel
from ribasim.model import Model
from ribasim.nodes import (
    basin,
    flow_boundary,
    flow_demand,
    level_boundary,
    level_demand,
    linear_resistance,
    outlet,
    pump,
    tabulated_rating_curve,
    user_demand,
)
from shapely.geometry import Point


def user_demand_model() -> Model:
    """Create a UserDemand test model with static and dynamic UserDemand on the same basin."""
    model = Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
        solver=Solver(algorithm="Tsit5"),
        experimental=Experimental(concentration=True),
    )

    model.basin.add(
        Node(1, Point(0, 0)),
        [basin.Profile(area=1000.0, level=[0.0, 1.0]), basin.State(level=[1.0])],
    )
    model.user_demand.add(
        Node(2, Point(1, 0.5)),
        [
            user_demand.Static(
                demand=[1e-4], return_factor=0.9, min_level=0.9, demand_priority=1
            )
        ],
    )
    model.user_demand.add(
        Node(3, Point(1, -0.5)),
        [
            user_demand.Time(
                time=[
                    "2020-06-01 00:00:00",
                    "2020-06-01 01:00:00",
                    "2020-07-01 00:00:00",
                    "2020-07-01 01:00:00",
                ],
                demand=[0.0, 3e-4, 3e-4, 0.0],
                return_factor=0.4,
                min_level=0.5,
                demand_priority=1,
            )
        ],
    )
    model.user_demand.add(
        Node(4, Point(1, 0)),
        [
            user_demand.Time(
                time=[
                    "2020-08-01 00:00:00",
                    "2020-09-01 00:00:00",
                    "2020-10-01 00:00:00",
                    "2020-11-01 00:00:00",
                ],
                min_level=0.0,
                demand=[0.0, 1e-4, 2e-4, 0.0],
                return_factor=[0.0, 0.1, 0.2, 0.3],
                demand_priority=1,
            )
        ],
    )
    model.terminal.add(Node(5, Point(2, 0)))

    model.edge.add(model.basin[1], model.user_demand[2])
    model.edge.add(model.basin[1], model.user_demand[3])
    model.edge.add(model.basin[1], model.user_demand[4])
    model.edge.add(model.user_demand[2], model.terminal[5])
    model.edge.add(model.user_demand[3], model.terminal[5])
    model.edge.add(model.user_demand[4], model.terminal[5])

    return model


def subnetwork_model() -> Model:
    """Create a UserDemand testmodel representing a subnetwork.

    This model is merged into main_network_with_subnetworks_model.
    """
    model = Model(
        starttime="2020-01-01",
        endtime="2020-04-01",
        crs="EPSG:28992",
        allocation=Allocation(use_allocation=True, timestep=86400),
        experimental=Experimental(concentration=True),
    )

    basin_data: list[TableModel[Any]] = [
        basin.Profile(area=100000.0, level=[0.0, 1.0]),
        basin.State(level=[10.0]),
    ]
    outlet_data: list[TableModel[Any]] = [
        outlet.Static(flow_rate=[3.0], max_flow_rate=3.0)
    ]

    model.flow_boundary.add(
        Node(1, Point(3, 1), subnetwork_id=2),
        [
            flow_boundary.Time(
                time=pd.date_range(start="2020-01", end="2020-05", freq="MS"),
                flow_rate=np.arange(10, 0, -2),
            )
        ],
    )
    model.basin.add(Node(2, Point(2, 1), subnetwork_id=2), basin_data)
    model.outlet.add(Node(3, Point(1, 1), subnetwork_id=2), outlet_data)
    model.terminal.add(Node(4, Point(0, 1), subnetwork_id=2))
    model.pump.add(
        Node(5, Point(2, 2), subnetwork_id=2),
        [pump.Static(flow_rate=[4.0], max_flow_rate=4.0)],
    )
    model.basin.add(Node(6, Point(2, 3), subnetwork_id=2), basin_data)
    model.outlet.add(Node(7, Point(1, 3), subnetwork_id=2), outlet_data)
    model.basin.add(Node(8, Point(0, 3), subnetwork_id=2), basin_data)
    model.terminal.add(Node(9, Point(2, 5), subnetwork_id=2))
    model.user_demand.add(
        Node(10, Point(2, 0), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[4.0], return_factor=0.9, min_level=0.9, demand_priority=2
            )
        ],
    )
    model.user_demand.add(
        Node(11, Point(3, 3), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[5.0], return_factor=0.5, min_level=0.9, demand_priority=1
            )
        ],
    )
    model.user_demand.add(
        Node(12, Point(0, 4), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[3.0], return_factor=0.9, min_level=0.9, demand_priority=2
            )
        ],
    )
    model.outlet.add(Node(13, Point(2, 4), subnetwork_id=2), outlet_data)

    model.edge.add(model.flow_boundary[1], model.basin[2])
    model.edge.add(model.basin[2], model.outlet[3])
    model.edge.add(model.outlet[3], model.terminal[4])
    model.edge.add(model.basin[2], model.user_demand[10])
    model.edge.add(model.basin[2], model.pump[5])
    model.edge.add(model.pump[5], model.basin[6])
    model.edge.add(model.basin[6], model.outlet[7])
    model.edge.add(model.outlet[7], model.basin[8])
    model.edge.add(model.basin[6], model.user_demand[11])
    model.edge.add(model.basin[8], model.user_demand[12])
    model.edge.add(model.basin[6], model.outlet[13])
    model.edge.add(model.outlet[13], model.terminal[9])
    model.edge.add(model.user_demand[10], model.basin[2])
    model.edge.add(model.user_demand[11], model.basin[6])
    model.edge.add(model.user_demand[12], model.basin[8])

    return model


def looped_subnetwork_model() -> Model:
    """Create a UserDemand testmodel representing a subnetwork containing a loop in the topology.

    This model is merged into main_network_with_subnetworks_model.
    """
    model = Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
        allocation=Allocation(use_allocation=True, timestep=86400),
        experimental=Experimental(concentration=True),
    )

    basin_data: list[TableModel[Any]] = [
        basin.Profile(area=1000.0, level=[0.0, 1.0]),
        basin.State(level=[1.0]),
    ]
    tabulated_rating_curve_data = tabulated_rating_curve.Static(
        level=[0.0, 1.0], flow_rate=[0.0, 2.0]
    )
    outlet_data = outlet.Static(flow_rate=[3e-3], max_flow_rate=3.0)

    model.user_demand.add(
        Node(1, Point(0, 0), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=2
            )
        ],
    )
    model.basin.add(Node(2, Point(0, 1), subnetwork_id=2), basin_data)
    model.outlet.add(Node(3, Point(-1, 1), subnetwork_id=2), [outlet_data])
    model.terminal.add(Node(4, Point(-2, 1), subnetwork_id=2))
    model.flow_boundary.add(
        Node(5, Point(2, 1), subnetwork_id=2),
        [flow_boundary.Static(flow_rate=[4.5e-3])],
    )
    model.pump.add(
        Node(6, Point(0, 2), subnetwork_id=2),
        [pump.Static(flow_rate=[4e-3], max_flow_rate=4e-3)],
    )
    model.basin.add(Node(7, Point(-2, 3), subnetwork_id=2), basin_data)
    model.outlet.add(Node(8, Point(-1, 3), subnetwork_id=2), [outlet_data])
    model.basin.add(Node(9, Point(0, 3), subnetwork_id=2), basin_data)
    model.outlet.add(Node(10, Point(1, 3), subnetwork_id=2), [outlet_data])
    model.basin.add(Node(11, Point(2, 3), subnetwork_id=2), basin_data)
    model.user_demand.add(
        Node(12, Point(-2, 4), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=1
            )
        ],
    )
    model.tabulated_rating_curve.add(
        Node(13, Point(0, 4), subnetwork_id=2), [tabulated_rating_curve_data]
    )
    model.tabulated_rating_curve.add(
        Node(14, Point(2, 4), subnetwork_id=2), [tabulated_rating_curve_data]
    )
    model.basin.add(Node(15, Point(0, 5), subnetwork_id=2), basin_data)
    model.pump.add(
        Node(16, Point(1, 5), subnetwork_id=2),
        [pump.Static(flow_rate=[4e-3], max_flow_rate=4e-3)],
    )
    model.basin.add(Node(17, Point(2, 5), subnetwork_id=2), basin_data)
    model.user_demand.add(
        Node(18, Point(-1, 6), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=3
            )
        ],
    )
    model.tabulated_rating_curve.add(
        Node(19, Point(0, 6), subnetwork_id=2), [tabulated_rating_curve_data]
    )
    model.user_demand.add(
        Node(20, Point(2, 6), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=3
            )
        ],
    )
    model.basin.add(Node(21, Point(0, 7), subnetwork_id=2), basin_data)
    model.outlet.add(Node(22, Point(0, 8), subnetwork_id=2), [outlet_data])
    model.terminal.add(Node(23, Point(0, 9), subnetwork_id=2))
    model.user_demand.add(
        Node(24, Point(3, 3), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=2
            )
        ],
    )

    model.edge.add(model.flow_boundary[5], model.basin[2])
    model.edge.add(model.basin[2], model.outlet[3])
    model.edge.add(model.outlet[3], model.terminal[4])
    model.edge.add(model.basin[2], model.user_demand[1])
    model.edge.add(model.basin[2], model.pump[6])
    model.edge.add(model.pump[6], model.basin[9])
    model.edge.add(model.basin[9], model.outlet[8])
    model.edge.add(model.outlet[8], model.basin[7])
    model.edge.add(model.basin[7], model.user_demand[12])
    model.edge.add(model.basin[9], model.tabulated_rating_curve[13])
    model.edge.add(model.tabulated_rating_curve[13], model.basin[15])
    model.edge.add(model.basin[15], model.pump[16])
    model.edge.add(model.pump[16], model.basin[17])
    model.edge.add(model.basin[17], model.user_demand[20])
    model.edge.add(model.basin[15], model.tabulated_rating_curve[19])
    model.edge.add(model.tabulated_rating_curve[19], model.basin[21])
    model.edge.add(model.basin[15], model.user_demand[18])
    model.edge.add(model.user_demand[18], model.basin[21])
    model.edge.add(model.basin[21], model.outlet[22])
    model.edge.add(model.outlet[22], model.terminal[23])
    model.edge.add(model.basin[9], model.outlet[10])
    model.edge.add(model.outlet[10], model.basin[11])
    model.edge.add(model.basin[11], model.tabulated_rating_curve[14])
    model.edge.add(model.tabulated_rating_curve[14], model.basin[17])
    model.edge.add(model.user_demand[1], model.basin[2])
    model.edge.add(model.user_demand[12], model.basin[7])
    model.edge.add(model.user_demand[20], model.basin[17])
    model.edge.add(model.basin[11], model.user_demand[24])
    model.edge.add(model.user_demand[24], model.basin[11])

    return model


def minimal_subnetwork_model() -> Model:
    """Create a subnetwork that is minimal with non-trivial allocation."""
    model = Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
        allocation=Allocation(use_allocation=True, timestep=86400),
        experimental=Experimental(concentration=True),
    )

    basin_data: list[TableModel[Any]] = [
        basin.Profile(area=1000.0, level=[0.0, 1.0]),
        basin.State(level=[1.0]),
    ]

    model.flow_boundary.add(
        Node(1, Point(0, 0), subnetwork_id=2),
        [flow_boundary.Static(flow_rate=[2.0e-3])],
    )
    model.basin.add(Node(2, Point(0, 1), subnetwork_id=2), basin_data)
    model.pump.add(
        Node(3, Point(0, 2), subnetwork_id=2),
        [pump.Static(flow_rate=[4e-3], max_flow_rate=4e-3)],
    )
    model.basin.add(Node(4, Point(0, 3), subnetwork_id=2), basin_data)
    model.user_demand.add(
        Node(5, Point(-1, 4), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=1
            )
        ],
    )
    model.user_demand.add(
        Node(6, Point(1, 4), subnetwork_id=2),
        [
            user_demand.Time(
                time=["2020-01-01", "2021-01-01"],
                demand=[1e-3, 2e-3],
                return_factor=0.9,
                min_level=0.9,
                demand_priority=1,
            )
        ],
    )

    model.edge.add(model.flow_boundary[1], model.basin[2])
    model.edge.add(model.basin[2], model.pump[3])
    model.edge.add(model.pump[3], model.basin[4])
    model.edge.add(model.basin[4], model.user_demand[5])
    model.edge.add(model.basin[4], model.user_demand[6])
    model.edge.add(model.user_demand[5], model.basin[4])
    model.edge.add(model.user_demand[6], model.basin[4])

    return model


def allocation_example_model() -> Model:
    """Generate a model that is used as an example of allocation in the docs."""
    model = Model(
        starttime="2020-01-01",
        endtime="2020-01-20",
        crs="EPSG:28992",
        allocation=Allocation(use_allocation=True, timestep=86400),
        experimental=Experimental(concentration=True),
    )

    basin_data: list[TableModel[Any]] = [
        basin.Profile(area=300_000.0, level=[0.0, 1.0]),
        basin.State(level=[1.0]),
    ]

    model.flow_boundary.add(
        Node(1, Point(0, 0), subnetwork_id=2), [flow_boundary.Static(flow_rate=[2.0])]
    )
    model.basin.add(Node(2, Point(1, 0), subnetwork_id=2), basin_data)
    model.user_demand.add(
        Node(3, Point(1, 1), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[1.5], return_factor=0.0, min_level=-1.0, demand_priority=1
            )
        ],
    )
    model.linear_resistance.add(
        Node(4, Point(2, 0), subnetwork_id=2),
        [linear_resistance.Static(resistance=[0.06])],
    )
    model.basin.add(Node(5, Point(3, 0), subnetwork_id=2), basin_data)
    model.user_demand.add(
        Node(6, Point(3, 1), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[1.0], return_factor=0.0, min_level=-1.0, demand_priority=3
            )
        ],
    )
    model.tabulated_rating_curve.add(
        Node(7, Point(4, 0), subnetwork_id=2),
        [
            tabulated_rating_curve.Static(
                level=[0.0, 0.5, 1.0], flow_rate=[0.0, 0.0, 2.0]
            )
        ],
    )
    model.terminal.add(Node(8, Point(5, 0), subnetwork_id=2))

    model.edge.add(model.flow_boundary[1], model.basin[2])
    model.edge.add(model.basin[2], model.user_demand[3])
    model.edge.add(model.basin[2], model.linear_resistance[4])
    model.edge.add(model.linear_resistance[4], model.basin[5])
    model.edge.add(model.basin[5], model.user_demand[6])
    model.edge.add(model.basin[5], model.tabulated_rating_curve[7])
    model.edge.add(model.tabulated_rating_curve[7], model.terminal[8])
    model.edge.add(model.user_demand[3], model.basin[2])
    model.edge.add(model.user_demand[6], model.basin[5])

    return model


def main_network_with_subnetworks_model() -> Model:
    """Generate a model which consists of a main network and multiple connected subnetworks."""
    model = Model(
        starttime="2020-01-01",
        endtime="2020-03-01",
        crs="EPSG:28992",
        allocation=Allocation(use_allocation=True, timestep=86400),
        experimental=Experimental(concentration=True),
    )

    basin_data: list[TableModel[Any]] = [
        basin.Profile(area=1000.0, level=[0.0, 1.0]),
        basin.State(level=[1.0]),
    ]
    large_basin_data: list[TableModel[Any]] = [
        basin.Profile(area=100000.0, level=[0.0, 1.0]),
        basin.State(level=[10.0]),
    ]

    model.flow_boundary.add(
        Node(1, Point(0, -1), subnetwork_id=1), [flow_boundary.Static(flow_rate=[1.0])]
    )
    model.basin.add(Node(2, Point(3, 1), subnetwork_id=1), basin_data)
    model.linear_resistance.add(
        Node(3, Point(6, -1), subnetwork_id=1),
        [linear_resistance.Static(resistance=[0.001])],
    )
    model.basin.add(Node(4, Point(9, 1), subnetwork_id=1), basin_data)
    model.linear_resistance.add(
        Node(5, Point(12, -1), subnetwork_id=1),
        [linear_resistance.Static(resistance=[0.001])],
    )
    model.basin.add(Node(6, Point(15, 1), subnetwork_id=1), basin_data)
    model.linear_resistance.add(
        Node(7, Point(18, -1), subnetwork_id=1),
        [linear_resistance.Static(resistance=[0.001])],
    )
    model.basin.add(Node(8, Point(21, 1), subnetwork_id=1), basin_data)
    model.linear_resistance.add(
        Node(9, Point(24, -1), subnetwork_id=1),
        [linear_resistance.Static(resistance=[0.001])],
    )
    model.basin.add(Node(10, Point(27, 1), subnetwork_id=1), basin_data)
    model.pump.add(
        Node(11, Point(3, 4), subnetwork_id=3),
        [pump.Static(flow_rate=[1e-3], max_flow_rate=10.0)],
    )
    model.basin.add(Node(12, Point(2, 4), subnetwork_id=3), large_basin_data)
    model.outlet.add(
        Node(13, Point(1, 4), subnetwork_id=3),
        [outlet.Static(flow_rate=[3.0], max_flow_rate=3.0)],
    )
    model.terminal.add(Node(14, Point(0, 4), subnetwork_id=3))
    model.pump.add(
        Node(15, Point(2, 5), subnetwork_id=3),
        [pump.Static(flow_rate=[4.0], max_flow_rate=4.0)],
    )
    model.basin.add(Node(16, Point(2, 6), subnetwork_id=3), large_basin_data)
    model.outlet.add(
        Node(17, Point(1, 6), subnetwork_id=3),
        [outlet.Static(flow_rate=[3.0], max_flow_rate=3.0)],
    )
    model.basin.add(Node(18, Point(0, 6), subnetwork_id=3), large_basin_data)
    model.terminal.add(Node(19, Point(2, 8), subnetwork_id=3))
    model.user_demand.add(
        Node(20, Point(2, 3), subnetwork_id=3),
        [
            user_demand.Static(
                demand=[4.0], return_factor=0.9, min_level=0.9, demand_priority=2
            )
        ],
    )
    model.user_demand.add(
        Node(21, Point(3, 6), subnetwork_id=3),
        [
            user_demand.Static(
                demand=[5.0], return_factor=0.9, min_level=0.9, demand_priority=1
            )
        ],
    )
    model.user_demand.add(
        Node(22, Point(0, 7), subnetwork_id=3),
        [
            user_demand.Static(
                demand=[3.0], return_factor=0.9, min_level=0.9, demand_priority=2
            )
        ],
    )
    model.outlet.add(
        Node(23, Point(2, 7), subnetwork_id=3),
        [outlet.Static(flow_rate=[3.0], max_flow_rate=3.0)],
    )
    model.pump.add(
        Node(24, Point(14, 3), subnetwork_id=5),
        [pump.Static(flow_rate=[1e-3], max_flow_rate=1.0)],
    )
    model.basin.add(Node(25, Point(14, 4), subnetwork_id=5), basin_data)
    model.tabulated_rating_curve.add(
        Node(26, Point(14, 5), subnetwork_id=5),
        [tabulated_rating_curve.Static(level=[0.0, 1.0], flow_rate=[0.0, 1e-4])],
    )
    model.basin.add(Node(31, Point(16, 7), subnetwork_id=5), basin_data)
    model.user_demand.add(
        Node(32, Point(17, 8), subnetwork_id=5),
        [
            user_demand.Time(
                time=["2020-01-01", "2021-01-01"],
                demand=[1e-3, 2e-3],
                return_factor=0.9,
                min_level=0.9,
                demand_priority=1,
            )
        ],
    )
    model.user_demand.add(
        Node(34, Point(26, 3), subnetwork_id=7),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=2
            )
        ],
    )
    model.basin.add(Node(35, Point(26, 4), subnetwork_id=7), basin_data)
    model.outlet.add(
        Node(36, Point(25, 4), subnetwork_id=7),
        [outlet.Static(flow_rate=[0.003], max_flow_rate=3.0)],
    )
    model.terminal.add(Node(37, Point(24, 4), subnetwork_id=7))
    model.pump.add(
        Node(38, Point(28, 4), subnetwork_id=7),
        [pump.Static(flow_rate=[1e-3], max_flow_rate=1.0)],
    )
    model.pump.add(
        Node(39, Point(26, 5), subnetwork_id=7),
        [pump.Static(flow_rate=[4e-3], max_flow_rate=0.004)],
    )
    model.basin.add(Node(40, Point(24, 6), subnetwork_id=7), basin_data)
    model.outlet.add(
        Node(41, Point(25, 6), subnetwork_id=7),
        [outlet.Static(flow_rate=[0.003], max_flow_rate=3.0)],
    )
    model.basin.add(Node(42, Point(26, 6), subnetwork_id=7), basin_data)
    model.outlet.add(
        Node(43, Point(27, 6), subnetwork_id=7),
        [outlet.Static(flow_rate=[0.003], max_flow_rate=3.0)],
    )
    model.basin.add(Node(44, Point(28, 6), subnetwork_id=7), basin_data)
    model.user_demand.add(
        Node(45, Point(24, 7), subnetwork_id=7),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=1
            )
        ],
    )
    model.tabulated_rating_curve.add(
        Node(46, Point(26, 7), subnetwork_id=7),
        [tabulated_rating_curve.Static(level=[0.0, 1.0], flow_rate=[0.0, 2.0])],
    )
    model.tabulated_rating_curve.add(
        Node(47, Point(28, 7), subnetwork_id=7),
        [tabulated_rating_curve.Static(level=[0.0, 1.0], flow_rate=[0.0, 2.0])],
    )
    model.basin.add(Node(48, Point(26, 8), subnetwork_id=7), basin_data)
    model.pump.add(
        Node(49, Point(27, 8), subnetwork_id=7),
        [pump.Static(flow_rate=[4e-3], max_flow_rate=0.004)],
    )
    model.basin.add(Node(50, Point(28, 8), subnetwork_id=7), basin_data)
    model.user_demand.add(
        Node(51, Point(25, 9), subnetwork_id=7),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=3
            )
        ],
    )
    model.tabulated_rating_curve.add(
        Node(52, Point(26, 9), subnetwork_id=7),
        [tabulated_rating_curve.Static(level=[0.0, 1.0], flow_rate=[0.0, 2.0])],
    )
    model.user_demand.add(
        Node(53, Point(28, 9), subnetwork_id=7),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=3
            )
        ],
    )
    model.basin.add(Node(54, Point(26, 10), subnetwork_id=7), basin_data)
    model.outlet.add(
        Node(55, Point(26, 11), subnetwork_id=7),
        [outlet.Static(flow_rate=[0.003], max_flow_rate=3.0)],
    )
    model.terminal.add(Node(56, Point(26, 12), subnetwork_id=7))
    model.user_demand.add(
        Node(57, Point(29, 6), subnetwork_id=7),
        [
            user_demand.Static(
                demand=[1e-3], return_factor=0.9, min_level=0.9, demand_priority=2
            )
        ],
    )

    # Missing demand
    model.user_demand.add(
        Node(60, Point(21, -1), subnetwork_id=1),
        [user_demand.Static(return_factor=[0.9], demand_priority=2, min_level=0.0)],
    )

    model.edge.add(model.flow_boundary[1], model.basin[2])
    model.edge.add(model.basin[2], model.linear_resistance[3])
    model.edge.add(model.linear_resistance[3], model.basin[4])
    model.edge.add(model.basin[4], model.linear_resistance[5])
    model.edge.add(model.linear_resistance[5], model.basin[6])
    model.edge.add(model.basin[6], model.linear_resistance[7])
    model.edge.add(model.linear_resistance[7], model.basin[8])
    model.edge.add(model.basin[8], model.linear_resistance[9])
    model.edge.add(model.linear_resistance[9], model.basin[10])
    model.edge.add(model.pump[11], model.basin[12])
    model.edge.add(model.basin[12], model.outlet[13])
    model.edge.add(model.outlet[13], model.terminal[14])
    model.edge.add(model.basin[12], model.user_demand[20])
    model.edge.add(model.basin[12], model.pump[15])
    model.edge.add(model.pump[15], model.basin[16])
    model.edge.add(model.basin[16], model.outlet[17])
    model.edge.add(model.outlet[17], model.basin[18])
    model.edge.add(model.basin[16], model.user_demand[21])
    model.edge.add(model.basin[18], model.user_demand[22])
    model.edge.add(model.basin[16], model.outlet[23])
    model.edge.add(model.outlet[23], model.terminal[19])
    model.edge.add(model.user_demand[20], model.basin[12])
    model.edge.add(model.user_demand[21], model.basin[16])
    model.edge.add(model.user_demand[22], model.basin[18])
    model.edge.add(model.pump[24], model.basin[25])
    model.edge.add(model.basin[25], model.tabulated_rating_curve[26])
    model.edge.add(model.tabulated_rating_curve[26], model.basin[31])
    model.edge.add(model.basin[31], model.user_demand[32])
    model.edge.add(model.user_demand[32], model.basin[31])
    model.edge.add(model.pump[38], model.basin[35])
    model.edge.add(model.basin[35], model.outlet[36])
    model.edge.add(model.outlet[36], model.terminal[37])
    model.edge.add(model.basin[35], model.user_demand[34])
    model.edge.add(model.basin[35], model.pump[39])
    model.edge.add(model.pump[39], model.basin[42])
    model.edge.add(model.basin[42], model.outlet[41])
    model.edge.add(model.outlet[41], model.basin[40])
    model.edge.add(model.basin[40], model.user_demand[45])
    model.edge.add(model.basin[42], model.tabulated_rating_curve[46])
    model.edge.add(model.tabulated_rating_curve[46], model.basin[48])
    model.edge.add(model.basin[48], model.pump[49])
    model.edge.add(model.pump[49], model.basin[50])
    model.edge.add(model.basin[50], model.user_demand[53])
    model.edge.add(model.basin[48], model.tabulated_rating_curve[52])
    model.edge.add(model.tabulated_rating_curve[52], model.basin[54])
    model.edge.add(model.basin[48], model.user_demand[51])
    model.edge.add(model.user_demand[51], model.basin[54])
    model.edge.add(model.basin[54], model.outlet[55])
    model.edge.add(model.outlet[55], model.terminal[56])
    model.edge.add(model.basin[42], model.outlet[43])
    model.edge.add(model.outlet[43], model.basin[44])
    model.edge.add(model.basin[44], model.tabulated_rating_curve[47])
    model.edge.add(model.tabulated_rating_curve[47], model.basin[50])
    model.edge.add(model.user_demand[34], model.basin[35])
    model.edge.add(model.user_demand[45], model.basin[40])
    model.edge.add(model.user_demand[53], model.basin[50])
    model.edge.add(model.basin[44], model.user_demand[57])
    model.edge.add(model.user_demand[57], model.basin[44])
    model.edge.add(model.basin[2], model.pump[11])
    model.edge.add(model.basin[6], model.pump[24])
    model.edge.add(model.basin[10], model.pump[38])
    model.edge.add(model.basin[8], model.user_demand[60])
    model.edge.add(model.user_demand[60], model.basin[8])

    return model


def subnetworks_with_sources_model() -> Model:
    """Generate a model with subnetworks which contain sources."""
    model = main_network_with_subnetworks_model()

    model.flow_boundary.add(
        Node(58, Point(3, 5), subnetwork_id=3),
        [flow_boundary.Static(flow_rate=[0.003])],
    )
    model.flow_boundary.add(
        Node(59, Point(28, 5), subnetwork_id=7),
        [flow_boundary.Static(flow_rate=[0.003])],
    )

    model.edge.add(model.flow_boundary[58], model.basin[16])
    model.edge.add(model.flow_boundary[59], model.basin[44])

    return model


def level_demand_model() -> Model:
    """Small model with LevelDemand nodes."""
    model = Model(
        starttime="2020-01-01",
        endtime="2020-02-01",
        crs="EPSG:28992",
        allocation=Allocation(use_allocation=True, timestep=1e5),
        experimental=Experimental(concentration=True),
    )
    model.flow_boundary.add(
        Node(1, Point(0, 0), subnetwork_id=2), [flow_boundary.Static(flow_rate=[1e-3])]
    )
    model.basin.add(
        Node(2, Point(1, 0), subnetwork_id=2),
        [
            basin.Profile(area=1000.0, level=[0.0, 1.0]),
            basin.Time(
                time=["2020-01-01", "2020-01-16"],
                precipitation=[1e-6, 0.0],
            ),
            basin.State(level=[0.5]),
        ],
    )
    model.user_demand.add(
        Node(3, Point(2, 0), subnetwork_id=2),
        [
            user_demand.Static(
                demand=[1.5e-3], return_factor=0.2, min_level=0.2, demand_priority=2
            )
        ],
    )
    model.level_demand.add(
        Node(4, Point(1, -1), subnetwork_id=2),
        [level_demand.Static(min_level=[1.0], max_level=1.5, demand_priority=1)],
    )
    model.basin.add(
        Node(5, Point(2, -1), subnetwork_id=2),
        [basin.Profile(area=1000.0, level=[0.0, 1.0]), basin.State(level=[0.5])],
    )

    # Isolated LevelDemand + Basin pair to test optional min_level
    model.level_demand.add(
        Node(6, Point(3, -1), subnetwork_id=3),
        [level_demand.Static(max_level=[1.0], demand_priority=1)],
    )
    model.basin.add(
        Node(7, Point(3, 0), subnetwork_id=3),
        [basin.Profile(area=1000.0, level=[0.0, 1.0]), basin.State(level=[2.0])],
    )

    model.edge.add(model.flow_boundary[1], model.basin[2])
    model.edge.add(model.basin[2], model.user_demand[3])
    model.edge.add(model.level_demand[4], model.basin[2])
    model.edge.add(model.user_demand[3], model.basin[5])
    model.edge.add(model.level_demand[4], model.basin[5])

    model.edge.add(model.level_demand[6], model.basin[7])

    return model


def flow_demand_model() -> Model:
    """Small model with a FlowDemand."""
    model = Model(
        starttime="2020-01-01 00:00:00",
        endtime="2021-01-01 00:00:00",
        crs="EPSG:28992",
        allocation=Allocation(use_allocation=True, timestep=1e5),
        experimental=Experimental(concentration=True),
    )

    model.tabulated_rating_curve.add(
        Node(2, Point(1, 0), subnetwork_id=2),
        [tabulated_rating_curve.Static(level=[0.0, 2.0], flow_rate=[0.0, 2e-3])],
    )

    model.level_boundary.add(
        Node(1, Point(0, 0), subnetwork_id=2),
        [level_boundary.Static(node_id=[1], level=[2.0])],
    )

    model.basin.add(
        Node(3, Point(2, 0), subnetwork_id=2),
        [basin.Profile(area=1e3, level=[0.0, 1.0]), basin.State(level=[1.0])],
    )
    model.basin.add(
        Node(7, Point(3, -1), subnetwork_id=2),
        [basin.Profile(area=1e3, level=[0.0, 1.0]), basin.State(level=[1.0])],
    )

    model.user_demand.add(
        Node(4, Point(3, 0), subnetwork_id=2),
        [
            user_demand.Static(
                demand_priority=[3], demand=1e-3, return_factor=1.0, min_level=0.2
            )
        ],
    )
    model.user_demand.add(
        Node(6, Point(2, -1), subnetwork_id=2),
        [
            user_demand.Static(
                demand_priority=[1], demand=1e-3, return_factor=1.0, min_level=0.2
            )
        ],
    )
    model.user_demand.add(
        Node(8, Point(3, -2), subnetwork_id=2),
        [
            user_demand.Static(
                demand_priority=[4], demand=2e-3, return_factor=1.0, min_level=0.2
            )
        ],
    )

    model.flow_demand.add(
        Node(5, Point(1, -1), subnetwork_id=2),
        [flow_demand.Static(demand=2e-3, demand_priority=[2])],
    )

    model.edge.add(
        model.level_boundary[1],
        model.tabulated_rating_curve[2],
    )
    model.edge.add(model.tabulated_rating_curve[2], model.basin[3])
    model.edge.add(model.basin[3], model.user_demand[4])
    model.edge.add(model.user_demand[4], model.basin[7])
    model.edge.add(model.basin[7], model.user_demand[8])
    model.edge.add(model.user_demand[8], model.basin[7])
    model.edge.add(model.basin[3], model.user_demand[6])
    model.edge.add(model.user_demand[6], model.basin[7])
    model.edge.add(model.flow_demand[5], model.tabulated_rating_curve[2])

    return model


def linear_resistance_demand_model():
    """Small model with a FlowDemand for a node with a max flow rate."""
    model = Model(
        starttime="2020-01-01 00:00:00",
        endtime="2021-01-01 00:00:00",
        crs="EPSG:28992",
        allocation=Allocation(use_allocation=True),
        experimental=Experimental(concentration=True),
    )

    model.basin.add(
        Node(1, Point(0, 0), subnetwork_id=2),
        [basin.Profile(area=1e3, level=[0.0, 1.0]), basin.State(level=[1.0])],
    )
    model.basin.add(
        Node(3, Point(2, 0), subnetwork_id=2),
        [basin.Profile(area=1e3, level=[0.0, 1.0]), basin.State(level=[1.0])],
    )

    model.linear_resistance.add(
        Node(2, Point(0, 1), subnetwork_id=2),
        [linear_resistance.Static(resistance=1.0, max_flow_rate=[2.0])],
    )

    model.flow_demand.add(
        Node(4, Point(1, 1), subnetwork_id=2),
        [flow_demand.Static(demand_priority=[1], demand=2.0)],
    )

    model.edge.add(model.basin[1], model.linear_resistance[2])
    model.edge.add(model.linear_resistance[2], model.basin[3])
    model.edge.add(model.flow_demand[4], model.linear_resistance[2])

    return model


def fair_distribution_model():
    """See the behavior of allocation with few restrictions within the graph."""
    model = Model(
        starttime="2020-01-01 00:00:00",
        endtime="2020-01-07 00:00:00",
        crs="EPSG:28992",
        allocation=Allocation(use_allocation=True),
        experimental=Experimental(concentration=True),
    )

    model.level_boundary.add(
        Node(1, Point(0, 0), subnetwork_id=1),
        [
            level_boundary.Static(
                level=[1.0],
            )
        ],
    )

    model.pump.add(
        Node(
            2,
            Point(1, 0),
            subnetwork_id=1,
        ),
        [pump.Static(flow_rate=9.0, max_flow_rate=[9.0])],
    )

    model.basin.add(
        Node(3, Point(2, 0), subnetwork_id=1),
        [basin.Profile(area=1e3, level=[0.0, 1.0]), basin.State(level=[1.0])],
    )

    model.linear_resistance.add(
        Node(4, Point(3, 0), subnetwork_id=1),
        [linear_resistance.Static(resistance=[1.0])],
    )

    model.basin.add(
        Node(5, Point(4, 0), subnetwork_id=1),
        [basin.Profile(area=1e3, level=[0.0, 1.0]), basin.State(level=[1.0])],
    )

    model.user_demand.add(
        Node(6, Point(2, 1), subnetwork_id=1),
        [
            user_demand.Static(
                demand_priority=[1], demand=1.0, return_factor=1.0, min_level=0.2
            )
        ],
    )

    model.user_demand.add(
        Node(7, Point(2, -1), subnetwork_id=1),
        [
            user_demand.Static(
                demand_priority=[1], demand=2.0, return_factor=1.0, min_level=0.2
            )
        ],
    )

    model.user_demand.add(
        Node(8, Point(4, 1), subnetwork_id=1),
        [
            user_demand.Static(
                demand_priority=[1], demand=3.0, return_factor=1.0, min_level=0.2
            )
        ],
    )

    model.user_demand.add(
        Node(9, Point(4, -1), subnetwork_id=1),
        [
            user_demand.Time(
                demand_priority=1,
                time=pd.date_range(start="2020-01", end="2021-01", freq="MS"),
                demand=np.linspace(1.0, 5.0, 13),
                return_factor=1.0,
                min_level=0.2,
            )
        ],
    )

    model.edge.add(model.level_boundary[1], model.pump[2])
    model.edge.add(model.pump[2], model.basin[3])
    model.edge.add(model.basin[3], model.linear_resistance[4])
    model.edge.add(model.linear_resistance[4], model.basin[5])
    model.edge.add(model.basin[3], model.user_demand[6])
    model.edge.add(model.basin[3], model.user_demand[7])
    model.edge.add(model.basin[5], model.user_demand[8])
    model.edge.add(model.basin[5], model.user_demand[9])
    model.edge.add(model.user_demand[6], model.basin[3])
    model.edge.add(model.user_demand[7], model.basin[3])
    model.edge.add(model.user_demand[8], model.basin[5])
    model.edge.add(model.user_demand[9], model.basin[5])

    return model


def allocation_training_model():
    model = Model(
        starttime="2022-01-01",
        endtime="2023-01-01",
        crs="EPSG:4326",
        allocation=Allocation(use_allocation=True),
        experimental=Experimental(concentration=True),
    )

    flow_boundary_times = pd.date_range(start="2022-01-01", end="2023-01-01", freq="MS")

    # Flow boundaries
    main = model.flow_boundary.add(
        Node(1, Point(0.0, 0.0), subnetwork_id=1, name="Main"),
        [
            flow_boundary.Time(
                time=flow_boundary_times,
                flow_rate=[
                    47.3,
                    156.7,
                    77.6,
                    47.8,
                    26.6,
                    23.1,
                    18.6,
                    15.6,
                    23.1,
                    35.6,
                    24.4,
                    20.0,
                    29.4,
                ],
            )
        ],
    )

    minor = model.flow_boundary.add(
        Node(2, Point(-3.0, 0.0), subnetwork_id=1, name="Minor"),
        [
            flow_boundary.Time(
                time=flow_boundary_times,
                flow_rate=[
                    0.2,
                    28.3,
                    16.0,
                    11.2,
                    8.5,
                    9.6,
                    9.2,
                    7.9,
                    7.5,
                    7.2,
                    7.4,
                    10.0,
                    8.3,
                ],
            )
        ],
    )

    level = model.level_demand.add(
        Node(11, Point(1, 1), subnetwork_id=1, name="test"),
        [
            level_demand.Static(
                min_level=[2],
                max_level=5,
                demand_priority=1,
            )
        ],
    )

    # Confluence
    conf = model.basin.add(
        Node(3, Point(-1.5, -1), subnetwork_id=1, name="confluence"),
        [
            basin.Profile(area=[672000, 5600000], level=[0, 6]),
            basin.State(level=[4]),
        ],
    )

    tbr_conf = model.tabulated_rating_curve.add(
        Node(4, Point(-1.5, -1.5), subnetwork_id=1, name="tbr_conf"),
        [
            tabulated_rating_curve.Static(
                level=[0.0, 2, 5],
                flow_rate=[0.0, 50, 200],
            )
        ],
    )

    # Irrigation
    irr = model.user_demand.add(
        Node(6, Point(-1.5, 0.5), subnetwork_id=1, name="irrigation"),
        [
            user_demand.Time(
                demand=[0.0, 0.0, 10, 12, 12, 0.0],
                return_factor=0,
                min_level=0,
                demand_priority=3,
                time=[
                    "2022-01-01",
                    "2022-03-31",
                    "2022-04-01",
                    "2022-07-01",
                    "2022-09-30",
                    "2022-10-01",
                ],
            )
        ],
    )

    # Reservoir
    reservoir = model.basin.add(
        Node(7, Point(-0.75, -0.5), subnetwork_id=1, name="reservoir"),
        [
            basin.Profile(area=[20000000, 32300000], level=[0, 7]),
            basin.State(level=[3.5]),
        ],
    )

    rsv_weir = model.tabulated_rating_curve.add(
        Node(8, Point(-1.125, -0.75), subnetwork_id=1, name="rsv_weir"),
        [
            tabulated_rating_curve.Static(
                level=[0.0, 1.5, 5],
                flow_rate=[0.0, 45, 200],
            )
        ],
    )

    # Public water use
    city = model.user_demand.add(
        Node(9, Point(-0.75, -1), subnetwork_id=1, name="city"),
        [
            user_demand.Time(
                # Total demand in m³/s
                demand=[2.0, 2.3, 2.3, 2.4, 3, 3, 4, 3, 2.5, 2.2, 2.0, 2.0],
                return_factor=0.4,
                min_level=0,
                demand_priority=2,
                time=pd.date_range(start="2022-01-01", periods=12, freq="MS"),
            )
        ],
    )

    # Industry
    industry = model.user_demand.add(
        Node(10, Point(0, -1.5), subnetwork_id=1, name="industry"),
        [
            user_demand.Time(
                # Total demand in m³/s
                demand=[4, 4, 4.5, 5, 5, 6, 7.5, 8, 5, 4, 3, 2.0],
                return_factor=0.5,
                min_level=0,
                demand_priority=1,
                time=pd.date_range(start="2022-01-01", periods=12, freq="MS"),
            )
        ],
    )

    sea = model.terminal.add(Node(5, Point(-1.5, -3.0), subnetwork_id=1, name="sea"))

    model.edge.add(main, reservoir, name="main")
    model.edge.add(minor, conf, name="minor")
    model.edge.add(reservoir, irr, name="irr supplied")
    model.edge.add(irr, conf, name="irr drain")
    model.edge.add(reservoir, city, name="city supplied")
    model.edge.add(city, conf, name="city returnflow")
    model.edge.add(reservoir, rsv_weir, name="rsv2weir")
    model.edge.add(rsv_weir, conf, name="weir2conf")
    model.edge.add(conf, tbr_conf, name="conf2tbr")
    model.edge.add(level, reservoir)
    model.edge.add(reservoir, industry, name="industry supplied")
    model.edge.add(industry, conf, name="ind2conf")
    model.edge.add(tbr_conf, sea, name="sea")

    return model
