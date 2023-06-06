import datetime
import inspect
from pathlib import Path
from typing import Any, List, Optional, Type, cast

import matplotlib.pyplot as plt
import numpy as np
import tomli
import tomli_w
from pydantic import BaseModel

from ribasim import geometry, node_types
from ribasim.geometry.edge import Edge
from ribasim.geometry.node import Node

# Do not import from ribasim namespace: will create import errors.
# E.g. not: from ribasim import Basin
from ribasim.input_base import TableModel
from ribasim.node_types.basin import Basin
from ribasim.node_types.control import Control
from ribasim.node_types.flow_boundary import FlowBoundary
from ribasim.node_types.fractional_flow import FractionalFlow
from ribasim.node_types.level_boundary import LevelBoundary
from ribasim.node_types.linear_resistance import LinearResistance
from ribasim.node_types.manning_resistance import ManningResistance
from ribasim.node_types.pump import Pump
from ribasim.node_types.tabulated_rating_curve import TabulatedRatingCurve
from ribasim.node_types.terminal import Terminal
from ribasim.types import FilePath


class Solver(BaseModel):
    algorithm: Optional[str]
    autodiff: Optional[bool]
    saveat: Optional[List[float]]
    dt: Optional[float]
    abstol: Optional[float]
    reltol: Optional[float]
    maxiters: Optional[int]


class Model(BaseModel):
    """
    A full Ribasim model schematisation with all input.

    Ribasim model containing the location of the nodes, the edges between the
    nodes, and the node parametrization.

    Parameters
    ----------
    modelname : str
        Model name, used in TOML and GeoPackage file name.
    node : Node
        The ID, type and geometry of each node.
    edge : Edge
        How the nodes are connected.
    basin : Basin
        The waterbodies.
    fractional_flow : Optional[FractionalFlow]
        Split flows into fractions.
    level_boundary : Optional[LevelBoundary]
        Boundary condition specifying the water level.
    flow_boundary : Optional[FlowBoundary]
        Boundary conditions specifying the flow.
    linear_resistance: Optional[LinearResistance]
        Linear flow resistance.
    manning_resistance : Optional[ManningResistance]
        Flow resistance based on the Manning formula.
    tabulated_rating_curve : Optional[TabulatedRatingCurve]
        Tabulated rating curve describing flow based on the upstream water level.
    pump : Optional[Pump]
        Prescribed flow rate from one basin to the other.
    terminal : Optional[Terminal]
        Water sink without state or properties.
    control : Optional[Control]
        Control logic.
    starttime : Union[str, datetime.datetime]
        Starting time of the simulation.
    endtime : Union[str, datetime.datetime]
        End time of the simulation.
    solver : Optional[Solver]
        Solver settings.
    """

    modelname: str
    node: Node
    edge: Edge
    basin: Basin
    fractional_flow: Optional[FractionalFlow]
    level_boundary: Optional[LevelBoundary]
    flow_boundary: Optional[FlowBoundary]
    linear_resistance: Optional[LinearResistance]
    manning_resistance: Optional[ManningResistance]
    tabulated_rating_curve: Optional[TabulatedRatingCurve]
    pump: Optional[Pump]
    terminal: Optional[Terminal]
    control: Optional[Control]
    starttime: datetime.datetime
    endtime: datetime.datetime
    solver: Optional[Solver]

    class Config:
        validate_assignment = True

    @classmethod
    def fields(cls):
        """Returns the names of the fields contained in the Model."""
        return cls.__fields__.keys()

    def __repr__(self) -> str:
        first = []
        second = []
        for field in self.fields():
            attr = getattr(self, field)
            if isinstance(attr, TableModel):
                second.append(f"{field}: {repr(attr)}")
            else:
                first.append(f"{field}={repr(attr)}")
        content = ["<ribasim.Model>"] + first + second
        return "\n".join(content)

    def _repr_html(self):
        # Default to standard repr for now
        return self.__repr__()

    def _write_toml(self, directory: FilePath):
        directory = Path(directory)
        content = {
            "starttime": self.starttime,
            "endtime": self.endtime,
            "geopackage": f"{self.modelname}.gpkg",
        }
        if self.solver is not None:
            section = {k: v for k, v in self.solver.dict().items() if v is not None}
            content["solver"] = section

        with open(directory / f"{self.modelname}.toml", "wb") as f:
            tomli_w.dump(content, f)
        return

    def _write_tables(self, directory: FilePath) -> None:
        """
        Write the input to GeoPackage and Arrow tables.
        """
        # avoid adding tables to existing model
        directory = Path(directory)
        gpkg_path = directory / f"{self.modelname}.gpkg"
        gpkg_path.unlink(missing_ok=True)

        for name in self.fields():
            input_entry = getattr(self, name)
            if isinstance(input_entry, TableModel):
                input_entry.write(directory, self.modelname)
        return

    @staticmethod
    def get_node_types():
        node_names_all, node_cls_all = list(
            zip(*inspect.getmembers(node_types, inspect.isclass))
        )
        return node_names_all, node_cls_all

    def validate_model_node_types(self):
        """
        Checks whether all node types in the node field are valid
        """

        node_names_all, _ = Model.get_node_types()

        invalid_node_types = set()

        # Check node types
        for node_type in self.node.static["type"]:
            if node_type not in node_names_all:
                invalid_node_types.add(node_type)

        if len(invalid_node_types) > 0:
            invalid_node_types = ", ".join(invalid_node_types)
            raise TypeError(
                f"Invalid node types detected: [{invalid_node_types}]. Choose from: {', '.join(node_names_all)}."
            )

    def validate_model_node_field_IDs(self):
        """
        Checks whether the node IDs of the node_type fields are valid
        """
        _, node_cls_all = Model.get_node_types()

        node_names_all_snake_case = [cls.get_toml_key() for cls in node_cls_all]

        # Check node IDs of node fields
        node_IDs_all = []
        n_nodes = len(self.node.static)

        for name in self.fields():
            if name in node_names_all_snake_case:
                if node_field := getattr(self, name):
                    node_IDs_field = node_field.get_node_IDs()
                    node_IDs_all.append(list(node_IDs_field))

        node_IDs_all = np.concatenate(node_IDs_all)
        node_IDs_unique, node_ID_counts = np.unique(node_IDs_all, return_counts=True)

        node_IDs_positive_integers = np.greater(node_IDs_unique, 0) & np.equal(
            node_IDs_unique.astype(int), node_IDs_unique
        )

        if not node_IDs_positive_integers.all():
            raise ValueError(
                f"Node IDs must be positive integers, got {node_IDs_unique[~node_IDs_positive_integers]}."
            )

        if (node_ID_counts > 1).any():
            raise ValueError(
                f"These node IDs were assigned to multiple node types: {node_IDs_unique[(node_ID_counts > 1)]}."
            )

        if not np.array_equal(node_IDs_unique, np.arange(n_nodes) + 1):
            node_IDs_missing = set(np.arange(n_nodes) + 1) - set(node_IDs_unique)
            raise ValueError(
                f"Expected node IDs from 1 to {n_nodes} (the number of rows in self.node.static), but these node IDs are missing: {node_IDs_missing}."
            )

    def validate_model_node_IDs(self):
        """
        Checks whether the node IDs in the node field correspond to the node IDs on the node type fields
        """

        _, node_cls_all = Model.get_node_types()

        node_names_all_snake_case = [cls.get_toml_key() for cls in node_cls_all]

        error_messages = []

        for name in self.fields():
            if name in node_names_all_snake_case:
                if attr := getattr(self, name):
                    node_IDs_field = attr.get_node_IDs()
                    node_IDs_from_node_field = self.node.static.loc[
                        self.node.static["type"] == attr.get_input_type()
                    ].index

                    if not set(node_IDs_from_node_field) == set(node_IDs_field):
                        error_messages.append(
                            f"The node IDs in the field {name} {node_IDs_field} do not correspond with the node IDs in the field node {node_IDs_from_node_field.tolist()}."
                        )

        if len(error_messages) > 0:
            raise ValueError("\n".join(error_messages))

    def validate_model(self):
        """
        Checks:
        - Whether all node types in the node field are valid
        - Whether the node IDs of the node_type fields are valid
        - Whether the node IDs in the node field correspond to the node IDs on the node type fields
        """

        self.validate_model_node_types()
        self.validate_model_node_field_IDs()
        self.validate_model_node_IDs()

    def write(self, directory: FilePath) -> None:
        """
        Write the contents of the model to a GeoPackage and a TOML
        configuration file.

        If ``directory`` does not exist, it is created before writing.
        The GeoPackage and TOML file will be called ``{modelname}.gpkg`` and
        ``{modelname}.toml`` respectively.

        Parameters
        ----------
        directory: FilePath
        """
        self.validate_model()

        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        self._write_toml(directory)
        self._write_tables(directory)
        return

    @staticmethod
    def from_toml(path: FilePath) -> "Model":
        """
        Initialize a model from the TOML configuration file.

        Parameters
        ----------
        path : FilePath
            Path to the configuration TOML file.

        Returns
        -------
        model : Model
        """

        path = Path(path)
        with open(path, "rb") as f:
            config = tomli.load(f)

        kwargs: dict[str, Any] = {"modelname": path.stem}
        config["geopackage"] = path.parent / config["geopackage"]

        for module in [geometry, node_types]:
            for _, node_type_cls in inspect.getmembers(module, inspect.isclass):
                cls_casted = cast(Type[TableModel], node_type_cls)
                kwargs[node_type_cls.get_toml_key()] = cls_casted.from_config(config)

        kwargs["starttime"] = config["starttime"]
        kwargs["endtime"] = config["endtime"]
        kwargs["solver"] = config.get("solver")

        return Model(**kwargs)

    def plot_control_listen(self, ax):
        if not self.control:
            return

        edges = set()
        condition = self.control.condition

        for node_id in condition.node_id.unique():
            for listen_node_id in condition.loc[
                condition.node_id == node_id, "listen_node_id"
            ]:
                edges.add((node_id - 1, listen_node_id - 1))

        start, end = list(zip(*edges))

        # This part can probably be done more efficiently
        x_start = self.node.static.iloc[list(start)].geometry.x
        y_start = self.node.static.iloc[list(start)].geometry.y
        x_end = self.node.static.iloc[list(end)].geometry.x
        y_end = self.node.static.iloc[list(end)].geometry.y

        for x, y, x_, y_ in zip(x_start, y_start, x_end, y_end):
            ax.plot([x, x_], [y, y_], c="gray", ls="--")

    def plot(self, ax=None) -> Any:
        """
        Plot the nodes and edges of the model.

        Parameters
        ----------
        ax : matplotlib.pyplot.Artist, optional
            Axes on which to draw the plot.

        Returns
        -------
        ax : matplotlib.pyplot.Artist
        """
        if ax is None:
            _, ax = plt.subplots()
            ax.axis("off")
        self.edge.plot(ax=ax, zorder=2)
        self.node.plot(ax=ax, zorder=3)
        self.plot_control_listen(ax)
        return ax

    def sort(self):
        """
        Sort all input tables as required.
        Tables are sorted by "node_id", unless otherwise specified.
        Sorting is done automatically before writing the table.
        """
        for name in self.fields():
            input_entry = getattr(self, name)
            if isinstance(input_entry, TableModel):
                input_entry.sort()
