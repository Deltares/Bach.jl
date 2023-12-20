from copy import deepcopy
from typing import Any

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import pandera as pa
import shapely
from matplotlib.axes import Axes
from numpy.typing import NDArray
from pandera.typing import Series
from pandera.typing.geopandas import GeoSeries
from shapely.geometry import LineString

from ribasim.input_base import SpatialTableModel

__all__ = ("Edge",)


class EdgeSchema(pa.SchemaModel):
    name: Series[str] = pa.Field(default="")
    from_node_id: Series[int] = pa.Field(default=0, coerce=True)
    to_node_id: Series[int] = pa.Field(default=0, coerce=True)
    allocation_network_id: Series[pd.Int64Dtype] = pa.Field(
        default=pd.NA, nullable=True, coerce=True
    )
    geometry: GeoSeries[Any] = pa.Field(default=None, nullable=True)

    class Config:
        add_missing_columns = True


class Edge(SpatialTableModel[EdgeSchema]):
    """
    Defines the connections between nodes.

    Parameters
    ----------
    static : pandas.DataFrame
        Table describing the flow connections.
    """

    def translate_spacially(
        self, offset_spacial: tuple[float, float], inplace: bool = True
    ) -> "Edge":
        if inplace:
            edge = self
        else:
            edge = deepcopy(self)

        edge.df.geometry = edge.df.geometry.apply(
            lambda linestring: LineString(
                [
                    (point[0] + offset_spacial[0], point[1] + offset_spacial[1])
                    for point in linestring.coords
                ]
            )
        )
        return edge

    def offset_allocation_network_ids(
        self, offset_allocation_network_id: int, inplace: bool = True
    ) -> "Edge":
        if inplace:
            edge = self
        else:
            edge = deepcopy(self)

        edge.df.allocation_network_id += offset_allocation_network_id
        return edge

    def get_where_edge_type(self, edge_type: str) -> NDArray[np.bool_]:
        return (self.df.edge_type == edge_type).to_numpy()

    def plot(self, **kwargs) -> Axes:
        ax = kwargs.get("ax", None)
        color_flow = kwargs.get("color_flow", None)
        color_control = kwargs.get("color_control", None)

        if ax is None:
            _, ax = plt.subplots()
            ax.axis("off")
            kwargs["ax"] = ax

        kwargs_flow = kwargs.copy()
        kwargs_control = kwargs.copy()

        if color_flow is None:
            color_flow = "#3690c0"  # lightblue
            kwargs_flow["color"] = color_flow
            kwargs_flow["label"] = "Flow edge"
        else:
            color_flow = kwargs["color_flow"]
            del kwargs_flow["color_flow"], kwargs_control["color_flow"]

        if color_control is None:
            color_control = "grey"
            kwargs_control["color"] = color_control
            kwargs_control["label"] = "Control edge"
        else:
            color_control = kwargs["color_flow"]
            del kwargs_flow["color_control"], kwargs_control["color_control"]

        where_flow = self.get_where_edge_type("flow")
        where_control = self.get_where_edge_type("control")

        self.df[where_flow].plot(**kwargs_flow)

        if where_control.any():
            self.df[where_control].plot(**kwargs_control)

        # Determine the angle for every caret marker and where to place it.
        coords = shapely.get_coordinates(self.df.geometry).reshape(-1, 2, 2)
        x, y = np.mean(coords, axis=1).T
        dx, dy = np.diff(coords, axis=1)[:, 0, :].T
        angle = np.degrees(np.arctan2(dy, dx)) - 90

        # A faster alternative may be ax.quiver(). However, getting the scaling
        # right is tedious.
        color = []

        for i in range(len(self.df)):
            if where_flow[i]:
                color.append(color_flow)
            elif where_control[i]:
                color.append(color_control)
            else:
                color.append("k")

        for m_x, m_y, m_angle, c in zip(x, y, angle, color):
            ax.plot(
                m_x,
                m_y,
                marker=(3, 0, m_angle),
                markersize=5,
                linestyle="None",
                c=c,
            )

        return ax
