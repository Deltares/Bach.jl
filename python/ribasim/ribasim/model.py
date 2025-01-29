import datetime
import logging
import shutil
from collections.abc import Generator
from os import PathLike
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import tomli
import tomli_w
from matplotlib import pyplot as plt
from pandera.typing.geopandas import GeoDataFrame
from pydantic import (
    DirectoryPath,
    Field,
    PrivateAttr,
    field_serializer,
    model_validator,
)

import ribasim
from ribasim.allocation.source_priorities import AllocationSourcePriorityTable
from ribasim.config import (
    Allocation,
    Basin,
    ContinuousControl,
    DiscreteControl,
    Experimental,
    FlowBoundary,
    FlowDemand,
    LevelBoundary,
    LevelDemand,
    LinearResistance,
    Logging,
    ManningResistance,
    MultiNodeModel,
    Outlet,
    PidControl,
    Pump,
    Results,
    Solver,
    TabulatedRatingCurve,
    Terminal,
    UserDemand,
)
from ribasim.db_utils import _set_db_schema_version
from ribasim.geometry.edge import EdgeSchema, EdgeTable
from ribasim.geometry.node import NodeTable
from ribasim.input_base import (
    ChildModel,
    FileModel,
    SpatialTableModel,
    context_file_loading,
    context_file_writing,
)
from ribasim.utils import (
    MissingOptionalModule,
    UsedIDs,
    _concat,
    _edge_lookup,
    _node_lookup,
    _node_lookup_numpy,
    _time_in_ns,
)
from ribasim.validation import control_edge_neighbor_amount, flow_edge_neighbor_amount

try:
    import xugrid
except ImportError:
    xugrid = MissingOptionalModule("xugrid")


class Model(FileModel):
    """A model of inland water resources systems."""

    starttime: datetime.datetime
    endtime: datetime.datetime
    crs: str

    input_dir: Path = Field(default=Path("."))
    results_dir: Path = Field(default=Path("results"))

    logging: Logging = Field(default_factory=Logging)
    solver: Solver = Field(default_factory=Solver)
    results: Results = Field(default_factory=Results)

    allocation: Allocation = Field(default_factory=Allocation)

    experimental: Experimental = Field(default_factory=Experimental)

    basin: Basin = Field(default_factory=Basin)
    continuous_control: ContinuousControl = Field(default_factory=ContinuousControl)
    discrete_control: DiscreteControl = Field(default_factory=DiscreteControl)
    flow_boundary: FlowBoundary = Field(default_factory=FlowBoundary)
    flow_demand: FlowDemand = Field(default_factory=FlowDemand)
    level_boundary: LevelBoundary = Field(default_factory=LevelBoundary)
    level_demand: LevelDemand = Field(default_factory=LevelDemand)
    linear_resistance: LinearResistance = Field(default_factory=LinearResistance)
    manning_resistance: ManningResistance = Field(default_factory=ManningResistance)
    outlet: Outlet = Field(default_factory=Outlet)
    pid_control: PidControl = Field(default_factory=PidControl)
    pump: Pump = Field(default_factory=Pump)
    tabulated_rating_curve: TabulatedRatingCurve = Field(
        default_factory=TabulatedRatingCurve
    )
    terminal: Terminal = Field(default_factory=Terminal)
    user_demand: UserDemand = Field(default_factory=UserDemand)

    allocation_source_priority_table: AllocationSourcePriorityTable = Field(
        default_factory=AllocationSourcePriorityTable
    )

    edge: EdgeTable = Field(default_factory=EdgeTable)
    use_validation: bool = Field(default=True, exclude=True)

    _used_node_ids: UsedIDs = PrivateAttr(default_factory=UsedIDs)

    @model_validator(mode="after")
    def _set_node_parent(self) -> "Model":
        for (
            k,
            v,
        ) in self._children().items():
            setattr(v, "_parent", self)
            setattr(v, "_parent_field", k)
        return self

    @model_validator(mode="after")
    def _ensure_edge_table_is_present(self) -> "Model":
        if self.edge.df is None:
            self.edge.df = GeoDataFrame[EdgeSchema](index=pd.Index([], name="edge_id"))
        self.edge.df = self.edge.df.set_geometry("geometry", crs=self.crs)
        return self

    @model_validator(mode="after")
    def _update_used_ids(self) -> "Model":
        # Only update the used node IDs if we read from a database
        if "database" in context_file_loading.get():
            df = self.node_table().df
            assert df is not None
            if len(df.index) > 0:
                self._used_node_ids.node_ids.update(df.index)
                self._used_node_ids.max_node_id = df.index.max()
        return self

    @field_serializer("input_dir", "results_dir")
    def _serialize_path(self, path: Path) -> str:
        return str(path)

    def model_post_init(self, __context: Any) -> None:
        # When serializing we exclude fields that are set to their default values
        # However, we always want to write `input_dir` and `results_dir`
        # By overriding `BaseModel.model_post_init` we can set them explicitly,
        # and enforce that they are always written.
        self.model_fields_set.update({"input_dir", "results_dir"})

    def __repr__(self) -> str:
        """Generate a succinct overview of the Model content.

        Skip "empty" NodeModel instances: when all dataframes are None.
        """
        content = ["ribasim.Model("]
        INDENT = "    "
        for field in self._fields():
            attr = getattr(self, field)
            if isinstance(attr, EdgeTable):
                content.append(f"{INDENT}{field}=Edge(...),")
            else:
                if isinstance(attr, MultiNodeModel) and attr.node.df is None:
                    # Skip unused node types
                    continue
                content.append(f"{INDENT}{field}={repr(attr)},")

        content.append(")")
        return "\n".join(content)

    def _write_toml(self, fn: Path) -> Path:
        """
        Write the model data to a TOML file.

        Parameters
        ----------
        fn : FilePath
            The file path where the TOML file will be written.

        Returns
        -------
        Path
            The file path of the written TOML file.
        """
        content = self.model_dump(exclude_unset=True, exclude_none=True, by_alias=True)
        # Filter empty dicts (default Nodes)
        content = dict(filter(lambda x: x[1], content.items()))
        content["ribasim_version"] = ribasim.__version__
        with open(fn, "wb") as f:
            tomli_w.dump(content, f)
        return fn

    def _save(self, directory: DirectoryPath, input_dir: DirectoryPath):
        # We write all tables to a temporary GeoPackage with a dot prefix,
        # and at the end move this over the target file.
        # This does not throw a PermissionError if the file is open in QGIS.
        db_path = directory / input_dir / ".database.gpkg"

        # avoid adding tables to existing model
        db_path.parent.mkdir(parents=True, exist_ok=True)
        db_path.unlink(missing_ok=True)
        context_file_writing.get()["database"] = db_path

        self.edge._save(directory, input_dir)
        node = self.node_table()

        assert node.df is not None
        node._save(directory, input_dir)

        # Run after geopackage schema has been created
        _set_db_schema_version(db_path, ribasim.__schema_version__)

        for sub in self._nodes():
            sub._save(directory, input_dir)

        shutil.move(db_path, db_path.with_name("database.gpkg"))

    def set_crs(self, crs: str) -> None:
        """Set the coordinate reference system of the data in the model.

        Parameters
        ----------
        crs : str
            Coordinate reference system, like "EPSG:4326" for WGS84 latitude longitude.
        """
        self._apply_crs_function("set_crs", crs)

    def to_crs(self, crs: str) -> None:
        # Set CRS of the tables to the CRS stored in the Model object
        self.set_crs(self.crs)
        self._apply_crs_function("to_crs", crs)

    def _apply_crs_function(self, function_name: str, crs: str) -> None:
        """Apply `function_name`, with `crs` as the first and only argument to all spatial tables."""
        getattr(self.edge.df, function_name)(crs, inplace=True)
        for sub in self._nodes():
            if sub.node.df is not None:
                getattr(sub.node.df, function_name)(crs, inplace=True)
            for table in sub._tables():
                if isinstance(table, SpatialTableModel) and table.df is not None:
                    getattr(table.df, function_name)(crs, inplace=True)
        self.crs = crs

    def node_table(self) -> NodeTable:
        """Compute the full sorted NodeTable from all node types."""
        df_chunks = [node.node.df for node in self._nodes()]
        df = (
            _concat(df_chunks)
            if df_chunks
            else pd.DataFrame(index=pd.Index([], name="node_id"))
        )
        node_table = NodeTable(df=df)
        node_table.sort()
        assert node_table.df is not None
        assert node_table.df.index.is_unique, "node_id must be unique"
        return node_table

    def _nodes(self) -> Generator[MultiNodeModel, Any, None]:
        """Return all non-empty MultiNodeModel instances."""
        for key in self.model_fields.keys():
            attr = getattr(self, key)
            if (
                isinstance(attr, MultiNodeModel)
                and attr.node.df is not None
                # TODO: Model.read creates empty node tables (#1278)
                and not attr.node.df.empty
            ):
                yield attr

    def _children(self):
        return {
            k: getattr(self, k)
            for k in self.model_fields.keys()
            if isinstance(getattr(self, k), ChildModel)
        }

    @classmethod
    def read(cls, filepath: str | PathLike[str]) -> "Model":
        """Read a model from a TOML file.

        Parameters
        ----------
        filepath : str | PathLike[str]
            The path to the TOML file.
        """
        if not Path(filepath).is_file():
            raise FileNotFoundError(f"File '{filepath}' does not exist.")
        return cls(filepath=filepath)  # type: ignore

    def write(self, filepath: str | PathLike[str]) -> Path:
        """Write the contents of the model to disk and save it as a TOML configuration file.

        If ``filepath.parent`` does not exist, it is created before writing.

        Parameters
        ----------
        filepath : str | PathLike[str]
            A file path with .toml extension.
        """
        if self.use_validation:
            self._validate_model()

        filepath = Path(filepath)
        self.filepath = filepath
        if not filepath.suffix == ".toml":
            raise ValueError(f"Filepath '{filepath}' is not a .toml file.")
        context_file_writing.set({})
        directory = filepath.parent
        directory.mkdir(parents=True, exist_ok=True)
        self._save(directory, self.input_dir)
        fn = self._write_toml(filepath)

        context_file_writing.set({})
        return fn

    def _validate_model(self):
        df_edge = self.edge.df
        df_chunks = [node.node.df for node in self._nodes()]
        df_node = _concat(df_chunks)

        df_graph = df_edge
        # Join df_edge with df_node to get to_node_type
        df_graph = df_graph.join(
            df_node[["node_type"]], on="from_node_id", how="left", rsuffix="_from"
        )
        df_graph = df_graph.rename(columns={"node_type": "from_node_type"})

        df_graph = df_graph.join(
            df_node[["node_type"]], on="to_node_id", how="left", rsuffix="_to"
        )
        df_graph = df_graph.rename(columns={"node_type": "to_node_type"})

        if not self._has_valid_neighbor_amount(
            df_graph, flow_edge_neighbor_amount, "flow", df_node["node_type"]
        ):
            raise ValueError("Minimum flow inneighbor or outneighbor unsatisfied")
        if not self._has_valid_neighbor_amount(
            df_graph, control_edge_neighbor_amount, "control", df_node["node_type"]
        ):
            raise ValueError("Minimum control inneighbor or outneighbor unsatisfied")

    def _has_valid_neighbor_amount(
        self,
        df_graph: pd.DataFrame,
        edge_amount: dict[str, list[int]],
        edge_type: str,
        nodes,
    ) -> bool:
        """Check if the neighbor amount of the two nodes connected by the given edge meet the minimum requirements."""
        is_valid = True

        # filter graph by edge type
        df_graph = df_graph.loc[df_graph["edge_type"] == edge_type]

        # count occurrence of "from_node" which reflects the number of outneighbors
        from_node_count = (
            df_graph.groupby("from_node_id").size().reset_index(name="from_node_count")
        )

        # append from_node_count column to from_node_id and from_node_type
        from_node_info = (
            df_graph[["from_node_id", "from_node_type"]]
            .drop_duplicates()
            .merge(from_node_count, on="from_node_id", how="left")
        )
        from_node_info = from_node_info[
            ["from_node_id", "from_node_count", "from_node_type"]
        ]

        # add the node that is not the upstream of any other nodes
        from_node_info = self._add_source_sink_node(nodes, from_node_info, "from")

        # loop over all the "from_node" and check if they have enough outneighbor
        for _, row in from_node_info.iterrows():
            # from node's outneighbor
            if row["from_node_count"] < edge_amount[row["from_node_type"]][2]:
                is_valid = False
                logging.error(
                    f"Node {row['from_node_id']} must have at least {edge_amount[row['from_node_type']][2]} outneighbor(s) (got {row['from_node_count']})"
                )

        # count occurrence of "to_node" which reflects the number of inneighbors
        to_node_count = (
            df_graph.groupby("to_node_id").size().reset_index(name="to_node_count")
        )

        # append to_node_count column to result
        to_node_info = (
            df_graph[["to_node_id", "to_node_type"]]
            .drop_duplicates()
            .merge(to_node_count, on="to_node_id", how="left")
        )
        to_node_info = to_node_info[["to_node_id", "to_node_count", "to_node_type"]]

        # add the node that is not the downstream of any other nodes
        to_node_info = self._add_source_sink_node(nodes, to_node_info, "to")

        # loop over all the "to_node" and check if they have enough inneighbor
        for _, row in to_node_info.iterrows():
            if row["to_node_count"] < edge_amount[row["to_node_type"]][0]:
                is_valid = False
                logging.error(
                    f"Node {row['to_node_id']} must have at least {edge_amount[row['to_node_type']][0]} inneighbor(s) (got {row['to_node_count']})"
                )

        return is_valid

    def _add_source_sink_node(
        self, nodes, node_info: pd.DataFrame, direction: str
    ) -> pd.DataFrame:
        """Loop over node table.

        Add the nodes whose id are missing in the from_node and to_node column in the edge table because they are not the upstream or downstrem of other nodes.

        Specify that their occurrence in from_node table or to_node table is 0.
        """
        # loop over nodes, add the one that is not the downstream (from) or upstream (to) of any other nodes
        for index, node in enumerate(nodes):
            if nodes.index[index] not in node_info[f"{direction}_node_id"].to_numpy():
                new_row = {
                    f"{direction}_node_id": nodes.index[index],
                    f"{direction}_node_count": 0,
                    f"{direction}_node_type": node,
                }
                node_info = _concat(
                    [node_info, pd.DataFrame([new_row])], ignore_index=True
                )

        return node_info

    @classmethod
    def _load(cls, filepath: Path | None) -> dict[str, Any]:
        context_file_loading.set({})

        if filepath is not None and filepath.is_file():
            with open(filepath, "rb") as f:
                config = tomli.load(f)

            directory = filepath.parent / config.get("input_dir", ".")
            context_file_loading.get()["directory"] = directory
            db_path = directory / "database.gpkg"

            if not db_path.is_file():
                raise FileNotFoundError(f"Database file '{db_path}' does not exist.")

            context_file_loading.get()["database"] = db_path

            return config
        else:
            return {}

    @model_validator(mode="after")
    def _reset_contextvar(self) -> "Model":
        # Drop database info
        context_file_loading.set({})
        return self

    def plot_control_listen(self, ax):
        """Plot the implicit listen edges of the model."""
        df_listen_edge = pd.DataFrame(
            data={
                "control_node_id": pd.Series([], dtype="int32[pyarrow]"),
                "listen_node_id": pd.Series([], dtype="int32[pyarrow]"),
            }
        )

        # Listen edges from PidControl
        for table in (self.pid_control.static.df, self.pid_control.time.df):
            if table is None:
                continue

            to_add = table[["node_id", "listen_node_id"]].drop_duplicates()
            to_add.columns = ["control_node_id", "listen_node_id"]
            df_listen_edge = _concat([df_listen_edge, to_add])

        # Listen edges from ContinuousControl and DiscreteControl
        for table, name in (
            (self.continuous_control.variable.df, "ContinuousControl"),
            (self.discrete_control.variable.df, "DiscreteControl"),
        ):
            if table is None:
                continue

            to_add = table[["node_id", "listen_node_id"]].drop_duplicates()
            to_add.columns = [
                "control_node_id",
                "listen_node_id",
            ]
            df_listen_edge = _concat([df_listen_edge, to_add])

        # Collect geometry data
        node = self.node_table().df
        control_nodes_geometry = df_listen_edge.merge(
            node,
            left_on=["control_node_id"],
            right_on=["node_id"],
            how="left",
        )["geometry"]

        listen_nodes_geometry = df_listen_edge.merge(
            node,
            left_on=["listen_node_id"],
            right_on=["node_id"],
            how="left",
        )["geometry"]

        # Plot listen edges
        for i, (point_listen, point_control) in enumerate(
            zip(listen_nodes_geometry, control_nodes_geometry)
        ):
            ax.plot(
                [point_listen.x, point_control.x],
                [point_listen.y, point_control.y],
                color="gray",
                ls="--",
                label="Listen edge" if i == 0 else None,
            )
        return

    def plot(
        self,
        ax=None,
        indicate_subnetworks: bool = True,
        aspect_ratio_bound: float = 0.33,
    ) -> Any:
        """Plot the nodes, edges and allocation networks of the model.

        Parameters
        ----------
        ax : matplotlib.pyplot.Artist
            Axes on which to draw the plot.
        indicate_subnetworks : bool
            Whether to indicate subnetworks with a convex hull backdrop.
        aspect_ratio_bound : float
            The maximal aspect ratio in (0,1). The smaller this number, the further the figure
            shape is allowed to be from a square

        Returns
        -------
        ax : matplotlib.pyplot.Artist
            Axis on which the plot is drawn.
        """
        if ax is None:
            _, ax = plt.subplots()
            ax.axis("off")

        node = self.node_table()
        self.edge.plot(ax=ax, zorder=2)
        self.plot_control_listen(ax)
        node.plot(ax=ax, zorder=3)

        handles, labels = ax.get_legend_handles_labels()

        if indicate_subnetworks:
            (
                handles_subnetworks,
                labels_subnetworks,
            ) = node.plot_allocation_networks(ax=ax, zorder=1)
            handles += handles_subnetworks
            labels += labels_subnetworks

        ax.legend(handles, labels, loc="lower left", bbox_to_anchor=(1, 0.5))

        # Enforce aspect ratio bound
        xlim = ax.get_xlim()
        ylim = ax.get_ylim()
        xsize = xlim[1] - xlim[0]
        ysize = ylim[1] - ylim[0]

        if ysize < aspect_ratio_bound * xsize:
            y_mid = (ylim[0] + ylim[1]) / 2
            ysize_new = aspect_ratio_bound * xsize
            ax.set_ylim(y_mid - ysize_new / 2, y_mid + ysize_new / 2)
        elif xsize < aspect_ratio_bound * ysize:
            x_mid = (xlim[0] + xlim[1]) / 2
            xsize_new = aspect_ratio_bound * ysize
            ax.set_xlim(x_mid - xsize_new / 2, x_mid + xsize_new / 2)

        return ax

    def to_xugrid(self, add_flow: bool = False, add_allocation: bool = False):
        """Convert the network to a `xugrid.UgridDataset`.

        Either the flow or the allocation data can be added, but not both simultaneously.
        This method will throw `ImportError` if the optional dependency `xugrid` isn't installed.

        Parameters
        ----------
        add_flow : bool
            add flow results (Optional, defaults to False)
        add_allocation : bool
            add allocation results (Optional, defaults to False)
        """
        if add_flow and add_allocation:
            raise ValueError("Cannot add both allocation and flow results.")

        node_df = self.node_table().df
        assert node_df is not None

        assert self.edge.df is not None
        edge_df = self.edge.df.copy()
        # We assume only the flow network is of interest.
        edge_df = edge_df[edge_df.edge_type == "flow"]

        node_id = node_df.index.to_numpy()
        edge_id = edge_df.index.to_numpy()
        from_node_id = edge_df.from_node_id.to_numpy()
        to_node_id = edge_df.to_node_id.to_numpy()
        node_lookup = _node_lookup_numpy(node_id)

        grid = xugrid.Ugrid1d(
            node_x=node_df.geometry.x,
            node_y=node_df.geometry.y,
            fill_value=-1,
            edge_node_connectivity=np.column_stack(
                (
                    node_lookup.loc[from_node_id],
                    node_lookup.loc[to_node_id],
                )
            ),
            name="ribasim",
            projected=node_df.crs.is_projected,
            crs=node_df.crs,
        )

        edge_dim = grid.edge_dimension
        node_dim = grid.node_dimension

        uds = xugrid.UgridDataset(None, grid)
        uds = uds.assign_coords(node_id=(node_dim, node_id))
        uds = uds.assign_coords(edge_id=(edge_dim, edge_id))
        uds = uds.assign_coords(from_node_id=(edge_dim, from_node_id))
        uds = uds.assign_coords(to_node_id=(edge_dim, to_node_id))

        if add_flow:
            uds = self._add_flow(uds, node_lookup)
        elif add_allocation:
            uds = self._add_allocation(uds)

        return uds

    def _checked_toml_path(self) -> Path:
        toml_path = self.filepath
        if toml_path is None:
            raise FileNotFoundError("Model must be written to disk to add results.")
        return toml_path

    def _add_flow(self, uds, node_lookup):
        toml_path = self._checked_toml_path()

        results_path = toml_path.parent / self.results_dir
        basin_path = results_path / "basin.arrow"
        flow_path = results_path / "flow.arrow"

        if not basin_path.is_file() or not flow_path.is_file():
            raise FileNotFoundError(
                f"Cannot find results in '{results_path}', "
                "perhaps the model needs to be run first."
            )

        basin_df = pd.read_feather(basin_path, dtype_backend="pyarrow")
        flow_df = pd.read_feather(flow_path, dtype_backend="pyarrow")
        _time_in_ns(basin_df)
        _time_in_ns(flow_df)

        # add the xugrid dimension indices to the dataframes
        edge_dim = uds.grid.edge_dimension
        node_dim = uds.grid.node_dimension
        node_lookup = _node_lookup(uds)
        edge_lookup = _edge_lookup(uds)
        flow_df[edge_dim] = edge_lookup[flow_df["edge_id"]].to_numpy()
        basin_df[node_dim] = node_lookup[basin_df["node_id"]].to_numpy()

        # add flow results to the UgridDataset
        flow_da = flow_df.set_index(["time", edge_dim])["flow_rate"].to_xarray()
        uds[flow_da.name] = flow_da

        # add basin results to the UgridDataset
        basin_df.drop(columns=["node_id"], inplace=True)
        basin_ds = basin_df.set_index(["time", node_dim]).to_xarray()

        for var_name, da in basin_ds.data_vars.items():
            uds[var_name] = da

        return uds

    def _add_allocation(self, uds):
        toml_path = self._checked_toml_path()

        results_path = toml_path.parent / self.results_dir
        alloc_flow_path = results_path / "allocation_flow.arrow"

        if not alloc_flow_path.is_file():
            raise FileNotFoundError(
                f"Cannot find '{alloc_flow_path}', "
                "perhaps the model needs to be run first, or allocation is not used."
            )

        alloc_flow_df = pd.read_feather(
            alloc_flow_path,
            columns=[
                "time",
                "edge_id",
                "flow_rate",
                "optimization_type",
                "demand_priority",
            ],
            dtype_backend="pyarrow",
        )
        _time_in_ns(alloc_flow_df)

        # add the xugrid edge dimension index to the dataframe
        edge_dim = uds.grid.edge_dimension
        edge_lookup = _edge_lookup(uds)
        alloc_flow_df[edge_dim] = edge_lookup[alloc_flow_df["edge_id"]].to_numpy()

        # "flow_rate_allocated" is the sum of all allocated flow rates over the demand priorities
        allocate_df = alloc_flow_df.loc[
            alloc_flow_df["optimization_type"] == "allocate"
        ]
        uds["flow_rate_allocated"] = (
            allocate_df.groupby(["time", edge_dim])["flow_rate"].sum().to_xarray()
        )

        # also add the individual demand priorities and optimization types
        # added as separate variables to ensure QGIS / MDAL compatibility
        for (optimization_type, demand_priority), group in alloc_flow_df.groupby(
            ["optimization_type", "demand_priority"]
        ):
            varname = f"{optimization_type}_priority_{demand_priority}"
            da = group.set_index(["time", edge_dim])["flow_rate"].to_xarray()
            uds[varname] = da

        return uds
