"""Utilities to write Delwaq (binary) input files."""

import struct
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
import ribasim

# import ribasim_testmodels
import xugrid as xu


def strfdelta(tdelta):
    # dddhhmmss format
    days = tdelta.days
    hours, rem = divmod(tdelta.seconds, 3600)
    minutes, seconds = divmod(rem, 60)
    return f"{days:03d}{hours:02d}{minutes:02d}{seconds:02d}"


def write_pointer(fn: Path | str, data: pd.DataFrame):
    """Write pointer file for Delwaq.

    The format is a matrix of int32 of edges
    with 4 columns: from_node_id, to_node_id, 0, 0

    This saves as column major order for Fortran compatibility.

    Data is a DataFrame with columns from_node_id, to_node_id.
    """
    with open(fn, "wb") as f:
        for a, b in data.to_numpy():
            f.write(struct.pack("<4i", a, b, 0, 0))


def write_lengths(fn: Path | str, data: np.ndarray[np.float32]):
    """Write lengths file for Delwaq.

    The format is an int defining time/edges (?)
    Followed by a matrix of float32 of 2, n_edges
    Defining the length of the half-edges.

    This saves as column major order for Fortran compatibility.

    Data is an array of float32.
    """
    with open(fn, "wb") as f:
        f.write(struct.pack("<i", 0))
        f.write(data.astype("float32").tobytes())


def write_volumes(fn: Path | str, data: pd.DataFrame):
    """Write volumes file for Delwaq.

    The format is an int defining the time
    followed by the volume for each node
    The order should be the same as the nodes in the mesh.

    This saves as column major order for Fortran compatibility.

    Data is a DataFrame with columns time, storage
    """
    with open(fn, "wb") as f:
        for time, group in data.groupby("time"):
            f.write(struct.pack("<i", int(time)))
            f.write(group.storage.to_numpy().astype("float32").tobytes())


def write_flows(fn: Path | str, data: pd.DataFrame):
    """Write flows file for Delwaq.

    The format is an int defining the time
    followed by the flow for each edge
    The order should be the same as the nodes in the pointer.

    This saves as column major order for Fortran compatibility.

    Data is a DataFrame with columns time, flow
    """
    with open(fn, "wb") as f:
        for time, group in data.groupby("time"):
            f.write(struct.pack("<i", int(time)))
            f.write(group.flow_rate.to_numpy().astype("float32").tobytes())


def ugridify(model: ribasim.Model):
    node_df = gpd.read_file(
        model.filepath.parent / "database.gpkg", layer="Node", fid_as_index=True
    )
    edge_df = model.edge.df[model.edge.df.edge_type == "flow"]

    # from node_id to the node_dim index
    node_lookup = pd.Series(
        index=node_df.index.rename("node_id"),
        data=node_df.index.argsort(),
        name="node_index",
    )
    # from edge_id to the edge_dim index
    edge_lookup = pd.Series(
        index=edge_df.index.rename("edge_id"),
        data=edge_df.index.argsort(),
        name="edge_index",
    )

    grid = xu.Ugrid1d(
        node_x=node_df.geometry.x,
        node_y=node_df.geometry.y,
        fill_value=-1,
        edge_node_connectivity=np.column_stack(
            (
                node_lookup[edge_df.from_node_id],
                node_lookup[edge_df.to_node_id],
            )
        ),
        name="ribasim_network",
        projected=node_df.crs.is_projected,
        crs=node_df.crs,
    )

    edge_dim = grid.edge_dimension
    node_dim = grid.node_dimension

    uds = xu.UgridDataset(None, grid)
    uds = uds.assign_coords(node_id=(node_dim, node_df.index))
    uds = uds.assign_coords(from_node_id=(edge_dim, edge_df.from_node_id))
    uds = uds.assign_coords(to_node_id=(edge_dim, edge_df.to_node_id))
    uds = uds.assign_coords(edge_id=(edge_dim, edge_df.index))
    # MDAL doesn't like string coordinates
    # uds = uds.assign_coords(node_name=(node_dim, node_df.name))
    # uds = uds.assign_coords(node_type=(node_dim, node_df["type"]))
    # uds = uds.assign_coords(edge_name=(edge_dim, edge_df.name))

    results_dir = model.filepath.parent / model.results_dir

    # Split out the boundary condition flows, since are on nodes, not edges.
    # Use pyarrow backend since it doesn't convert the edge_id to float to handle missings.
    all_flow_df = pd.read_feather(results_dir / "flow.arrow")

    # https://github.com/pydata/xarray/issues/6318 datetime64[ms] gives trouble
    all_flow_df.time = all_flow_df.time.astype("datetime64[ns]")

    flow_df = all_flow_df[all_flow_df.edge_id.notna()].copy()
    # The numpy_nullable backend converts to float to handle missing,
    # now we can convert it back since there are no missings left here.
    # The pyarrow backend fixes this, but then we get object dtypes after to_xarray()
    flow_df.edge_id = flow_df.edge_id.astype(np.int64)

    flow_df[edge_dim] = edge_lookup[flow_df.edge_id].to_numpy()
    flow_da = flow_df.set_index(["time", edge_dim]).flow_rate.to_xarray()
    uds["flow"] = flow_da

    bc_flow_df = all_flow_df[all_flow_df.edge_id.isna()].copy()
    bc_flow_df = bc_flow_df.rename(
        columns={"flow_rate": "boundary_flow", "from_node_id": "node_id"}
    ).drop(columns=["edge_id", "to_node_id"])
    bc_flow_df[node_dim] = node_lookup[bc_flow_df.node_id].to_numpy()
    bc_flow_df
    bc_flow_da = bc_flow_df.set_index(["time", node_dim]).boundary_flow.to_xarray()
    # perhaps not the best name?
    # this does not visualize properly, and is selected on load, maybe due to alphabetical order
    uds["boundary_flow"] = bc_flow_da
    return uds