__version__ = "2025.1.0"
# Keep synced write_schema_version in ribasim_qgis/core/geopackage.py
__schema_version__ = 3

from ribasim.config import Allocation, Logging, Node, Solver
from ribasim.geometry.edge import EdgeTable
from ribasim.model import Model

__all__ = [
    "EdgeTable",
    "Allocation",
    "Logging",
    "Model",
    "Solver",
    "Node",
]
