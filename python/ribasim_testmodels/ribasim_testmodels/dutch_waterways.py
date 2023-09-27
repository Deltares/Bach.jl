import geopandas as gpd
import numpy as np
import pandas as pd
import ribasim


def dutch_waterways_model():
    """Set up a model that is representative of the main Dutch rivers."""

    # Setup the basins
    levels = np.array(
        [
            1.86,
            3.21,
            4.91,
            6.61,
            8.31,
            10.07,
            10.17,
            10.27,
            11.61,
            12.94,
            13.05,
            13.69,
            14.32,
            14.96,
            15.59,
        ]
    )

    totalwidth = np.array(
        [
            10.0,
            88.0,
            137.0,
            139.0,
            141.0,
            219.0,
            220.0,
            221.0,
            302.0,
            606.0,
            837.0,
            902.0,
            989.0,
            1008.0,
            1011.0,
        ]
    )

    basin_node_ids = np.array([2, 5, 6, 10, 12, 15], dtype=int)
    n_basins = len(basin_node_ids)

    length = 1e4

    profile = pd.DataFrame(
        data={
            "node_id": np.repeat(basin_node_ids, len(levels)),
            "level": np.tile(levels, n_basins),
            "area": np.tile(length * totalwidth, n_basins),
        }
    )

    static = pd.DataFrame(
        data={
            "node_id": basin_node_ids,
            "drainage": n_basins * [0.0],
            "potential_evaporation": n_basins * [0.0],
            "infiltration": n_basins * [0.0],
            "precipitation": n_basins * [0.0],
            "urban_runoff": n_basins * [0.0],
        }
    )

    state = pd.DataFrame(
        data={"node_id": basin_node_ids, "level": [8.31, 7.5, 7.5, 7.0, 6.0, 5.5]}
    )

    basin = ribasim.Basin(profile=profile, static=static, state=state)

    # Setup linear resistance:
    linear_resistance = ribasim.LinearResistance(
        static=pd.DataFrame(
            data={"node_id": [3, 4, 11, 18, 19], "resistance": 5 * [1e-2]}
        )
    )

    rating_curve = ribasim.TabulatedRatingCurve(
        static=pd.DataFrame(
            data={
                "control_state": [
                    "pump_low",
                    "pump_high",
                    "rating_curve",
                    "rating_curve",
                    None,
                    None,
                ],
                "node_id": [8, 8, 8, 8, 13, 13],
                "active": [False, False, True, True, None, None],
                "level": [
                    0.0,
                    0.0,
                    7.45,
                    7.46,
                    4.45,
                    4.46,
                ],  # The level and discharge for "pump_low", "pump_high" are irrelevant
                "discharge": [0.0, 0.0]
                + 2 * [418, 420.15],  # since the rating curve is not active here
            }
        )
    )

    # Setup pump
    pump = ribasim.Pump(
        static=pd.DataFrame(
            data={
                "node_id": 3 * [9] + [14],
                "active": [True, True, False, None],
                "control_state": ["pump_low", "pump_high", "rating_curve", None],
                "flow_rate": [15.0, 25.0, 1.0, 1.0],
                "flow_rate_min": 3 * [None] + [0.0],
                "flow_rate_max": 3 * [None] + [50.0],
            }
        )
    )

    # Setup flow boundary
    n_times = 250
    time = pd.date_range(
        start="2020-01-01 00:00:00", end="2021-01-01 00:00:00", periods=n_times
    ).astype("datetime64[s]")

    # Flow rate curve from sine series
    flow_rate = np.zeros(n_times)
    x = np.linspace(0, 1, n_times)
    n_terms = 5
    for i in np.arange(1, 2 * n_terms, 2):
        flow_rate += 4 / (i * np.pi) * np.sin(2 * i * np.pi * x)

    b = (250 + 800) / 2
    a = 800 - b

    # Scale to desired magnitude
    flow_rate = a * flow_rate + b

    flow_boundary = ribasim.FlowBoundary(
        time=pd.DataFrame(
            data={"node_id": n_times * [1], "time": time, "flow_rate": flow_rate}
        )
    )

    # Setup the level boundary
    level_boundary = ribasim.LevelBoundary(
        static=pd.DataFrame(data={"node_id": [7, 16], "level": 2 * [3.0]})
    )

    # Setup PID control
    pid_control = ribasim.PidControl(
        static=pd.DataFrame(
            data={
                "node_id": [20],
                "listen_node_id": [12],
                "target": [6.0],
                "proportional": [-0.005],
                "integral": [0.0],
                "derivative": [-0.002],
            }
        )
    )

    # Setup discrete control
    condition = pd.DataFrame(
        data={
            "node_id": 4 * [17],
            "listen_feature_id": 4 * [1],
            "variable": 4 * ["flow_rate"],
            "greater_than": [250, 275, 750, 800],
        }
    )

    logic = pd.DataFrame(
        data={
            "node_id": 5 * [17],
            "truth_state": ["FFFF", "U***", "T**F", "***D", "TTTT"],
            "control_state": [
                "pump_low",
                "pump_low",
                "pump_high",
                "rating_curve",
                "rating_curve",
            ],
        }
    )

    discrete_control = ribasim.DiscreteControl(condition=condition, logic=logic)

    # Set up the nodes:
    node_id, node_type = ribasim.Node.get_node_ids_and_types(
        basin,
        linear_resistance,
        pump,
        flow_boundary,
        level_boundary,
        rating_curve,
        pid_control,
        discrete_control,
    )

    xy = np.array(
        [
            (1310, 312),  # 1: LevelBoundary
            (1281, 278),  # 2: Basin
            (1283, 183),  # 3: LinearResistance
            (1220, 186),  # 4: LinearResistance
            (1342, 162),  # 5: Basin
            (1134, 184),  # 6: Basin
            (1383, 121),  # 7: LevelBoundary
            (1052, 201),  # 8: TabulatedRatingCurve
            (1043, 188),  # 9: Pump
            (920, 197),  # 10: Basin
            (783, 237),  # 11: LinearResistance
            (609, 186),  # 12: Basin
            (430, 176),  # 13: TabulatedRatingCurve
            (442, 164),  # 14: Pump
            (369, 185),  # 15: Basin
            (329, 202),  # 16: LevelBoundary
            (1187, 276),  # 17: DiscreteControl
            (1362, 142),  # 18: LinearResistance
            (349, 194),  # 19: LinearResistance
            (511, 126),  # 20: PidControl
        ]
    )

    node_xy = gpd.points_from_xy(x=xy[:, 0], y=405 - xy[:, 1])

    # Make sure the feature id starts at 1: explicitly give an index.
    node = ribasim.Node(
        static=gpd.GeoDataFrame(
            data={"type": node_type},
            index=pd.Index(node_id, name="fid"),
            geometry=node_xy,
            crs="EPSG:28992",
        )
    )

    # Setup the edges:
    from_id_flow = np.array(
        [1, 2, 3, 2, 4, 6, 9, 10, 11, 12, 14, 6, 8, 12, 13, 5, 18, 15, 19],
        dtype=np.int64,
    )
    to_id_flow = np.array(
        [2, 3, 5, 4, 6, 9, 10, 11, 12, 14, 15, 8, 10, 13, 15, 18, 7, 19, 16],
        dtype=np.int64,
    )

    from_id_control = np.array([20, 17, 17], dtype=np.int64)
    to_id_control = np.array([14, 8, 9], dtype=np.int64)

    from_id = np.concatenate([from_id_flow, from_id_control])
    to_id = np.concatenate([to_id_flow, to_id_control])

    lines = ribasim.utils.geometry_from_connectivity(node, from_id, to_id)
    edge = ribasim.Edge(
        static=gpd.GeoDataFrame(
            data={
                "from_node_id": from_id,
                "to_node_id": to_id,
                "edge_type": len(from_id_flow) * ["flow"]
                + len(from_id_control) * ["control"],
            },
            geometry=lines,
            crs="EPSG:28992",
        )
    )

    model = ribasim.Model(
        modelname="dutch_waterways",
        node=node,
        edge=edge,
        basin=basin,
        linear_resistance=linear_resistance,
        pump=pump,
        flow_boundary=flow_boundary,
        level_boundary=level_boundary,
        tabulated_rating_curve=rating_curve,
        pid_control=pid_control,
        discrete_control=discrete_control,
        starttime="2020-01-01 00:00:00",
        endtime="2021-01-01 00:00:00",
    )

    return model


if __name__ == "__main__":
    import matplotlib.pyplot as plt

    model = dutch_waterways_model()

    model.plot()

    df_flow = model.flow_boundary.time.pivot_table(index="time", values=["flow_rate"])
    df_flow.plot()

    plt.show()
