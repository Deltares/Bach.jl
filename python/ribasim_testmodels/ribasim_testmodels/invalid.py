from typing import Any

from ribasim.config import Allocation, Node, Solver
from ribasim.input_base import TableModel
from ribasim.model import Model
from ribasim.nodes import (
    basin,
    discrete_control,
    flow_boundary,
    flow_demand,
    level_boundary,
    level_demand,
    pump,
    tabulated_rating_curve,
    user_demand,
)
from shapely.geometry import Point


def invalid_qh_model() -> Model:
    """
    Invalid TabulatedRatingCurve Q(h) table.

    - levels must be unique
    - flow_rate must start at 0
    - flow_rate must not be decreasing
    """
    model = Model(
        starttime="2020-01-01",
        endtime="2020-12-01",
        crs="EPSG:28992",
        use_validation=False,
    )

    model.tabulated_rating_curve.add(
        Node(1, Point(0, 0)),
        [tabulated_rating_curve.Static(level=[0, 0, 1], flow_rate=[1, 2, 1.5])],
    )

    return model


def invalid_discrete_control_model() -> Model:
    model = Model(
        starttime="2020-01-01",
        endtime="2020-12-01",
        crs="EPSG:28992",
        use_validation=False,
    )

    basin_shared: list[TableModel[Any]] = [
        basin.Profile(area=[0.01, 1.0], level=[0.0, 1.0]),
        basin.State(level=[1.4112729908597084]),
    ]
    model.basin.add(Node(1, Point(0, 0)), basin_shared)
    # Invalid: DiscreteControl node #4 with control state 'foo'
    # points to this pump but this control state is not defined for
    # this pump. The pump having a control state that is not defined
    # for DiscreteControl node #4 is fine.
    model.pump.add(
        Node(2, Point(1, 0)), [pump.Static(control_state="bar", flow_rate=[0.5 / 3600])]
    )
    model.basin.add(Node(3, Point(2, 0)), basin_shared)
    model.flow_boundary.add(
        Node(4, Point(3, 0)),
        [
            flow_boundary.Time(
                time=["2020-01-01", "2020-11-01"],
                flow_rate=[1.0, 2.0],
            )
        ],
    )
    model.discrete_control.add(
        Node(5, Point(1, 1)),
        [
            discrete_control.Variable(
                listen_node_id=[1, 4, 4],
                variable=["level", "flow_rate", "flow_rate"],
                # Invalid: look_ahead can only be specified for timeseries variables.
                # Invalid: this look_ahead will go past the provided timeseries during simulation.
                # Invalid: look_ahead must be non-negative.
                look_ahead=[100.0, 40 * 24 * 60 * 60, -10.0],
                compound_variable_id=[1, 2, 3],
            ),
            discrete_control.Condition(
                greater_than=[0.5, 1.5, 1.5],
                compound_variable_id=[1, 2, 3],
            ),
            # Invalid: DiscreteControl node #4 has 2 conditions so
            # truth states have to be of length 2
            discrete_control.Logic(truth_state=["FFFF"], control_state=["foo"]),
        ],
    )

    model.edge.add(
        model.basin[1],
        model.pump[2],
    )
    model.edge.add(
        model.pump[2],
        model.basin[3],
    )
    model.edge.add(
        model.flow_boundary[4],
        model.basin[3],
    )
    model.edge.add(
        model.discrete_control[5],
        model.pump[2],
    )

    return model


def invalid_edge_types_model() -> Model:
    """Set up a minimal model with invalid edge types."""
    model = Model(
        starttime="2020-01-01",
        endtime="2020-12-01",
        crs="EPSG:28992",
        use_validation=False,
    )

    basin_shared: list[TableModel[Any]] = [
        basin.Profile(area=[0.01, 1000.0], level=[0.0, 1.0]),
        basin.State(level=[0.04471158417652035]),
    ]

    model.basin.add(Node(1, Point(0, 0)), basin_shared)
    model.pump.add(Node(2, Point(1, 0)), [pump.Static(flow_rate=[0.5 / 3600])])
    model.basin.add(Node(3, Point(2, 0)), basin_shared)

    model.edge.add(
        model.basin[1],
        model.pump[2],
    )
    model.edge.add(
        model.pump[2],
        model.basin[3],
    )

    assert model.edge.df is not None
    model.edge.df["edge_type"] = ["foo", "bar"]

    return model


def invalid_unstable_model() -> Model:
    """Model with several extremely quickly emptying basins."""
    model = Model(
        starttime="2020-01-01",
        endtime="2021-01-01",
        crs="EPSG:28992",
        solver=Solver(dtmin=60.0),
        use_validation=False,
    )
    id_shift = 10
    for i in range(6):
        model.basin.add(
            Node(1 + id_shift * i, Point(i, 0)),
            [basin.Profile(area=1000.0, level=[0.0, 1.0]), basin.State(level=[1.0])],
        )
        flow_rate = 1.0 if (i % 2 == 0) else 1e10
        model.pump.add(
            Node(2 + id_shift * i, Point(i, 1)), [pump.Static(flow_rate=[flow_rate])]
        )
        model.terminal.add(Node(3 + id_shift * i, Point(i, 2)))

        model.edge.add(model.basin[1 + id_shift * i], model.pump[2 + id_shift * i])
        model.edge.add(model.pump[2 + id_shift * i], model.terminal[3 + id_shift * i])
    return model


def invalid_priorities_model() -> Model:
    """Model with allocation active but missing demand_priority parameter(s)."""
    model = Model(
        starttime="2020-01-01 00:00:00",
        endtime="2021-01-01 00:00:00",
        crs="EPSG:28992",
        allocation=Allocation(use_allocation=True, timestep=1e5),
        use_validation=False,
    )

    model.tabulated_rating_curve.add(
        Node(2, Point(1, 0), subnetwork_id=2),
        [tabulated_rating_curve.Static(level=[0.0, 1.0], flow_rate=[0.0, 2e-3])],
    )

    model.level_boundary.add(
        Node(1, Point(0, 0), subnetwork_id=2),
        [level_boundary.Static(node_id=[1], level=[1.0])],
    )

    model.basin.add(
        Node(3, Point(2, 0), subnetwork_id=2),
        [basin.Profile(area=1e3, level=[0.0, 1.0]), basin.State(level=[1.0])],
    )

    model.user_demand.add(
        Node(4, Point(3, 0), subnetwork_id=2),
        [user_demand.Static(demand=[1e-3], return_factor=1.0, min_level=0.2)],
    )

    model.level_demand.add(
        Node(6, Point(2, -1), subnetwork_id=2),
        [level_demand.Static(min_level=[1.0], max_level=1.5)],
    )

    model.flow_demand.add(
        Node(5, Point(1, -1), subnetwork_id=2),
        [flow_demand.Static(demand=[2e-3])],
    )

    model.edge.add(
        model.level_boundary[1],
        model.tabulated_rating_curve[2],
    )
    model.edge.add(model.tabulated_rating_curve[2], model.basin[3])
    model.edge.add(model.basin[3], model.user_demand[4])
    model.edge.add(model.level_demand[6], model.basin[3])
    model.edge.add(model.flow_demand[5], model.tabulated_rating_curve[2])

    return model
