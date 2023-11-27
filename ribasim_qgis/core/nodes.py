"""
This module contains the classes to represent the Ribasim node layers.

The classes specify:

* The (unabbreviated) name
* The type of geometry (No geometry, point, linestring, polygon)
* The required attributes of the attribute table

Each node layer is (optionally) represented in multiple places:

* It always lives in a GeoPackage.
* While a geopackage is active within plugin, it is always represented in a
  Dataset Tree: the Dataset Tree provides a direct look at the state of the
  GeoPackage. In this tree, steady and transient input are on the same row.
  Associated input is, to potentially enable transient associated data later
  on (like a building pit with changing head top boundary).
* It can be added to the Layers Panel in QGIS. This enables a user to visualize
  and edit its data.

"""

from __future__ import annotations

import abc
from pathlib import Path
from typing import Any, cast

from PyQt5.QtCore import Qt, QVariant
from PyQt5.QtGui import QColor
from qgis.core import (
    Qgis,
    QgsCategorizedSymbolRenderer,
    QgsCoordinateReferenceSystem,
    QgsEditorWidgetSetup,
    QgsFeatureRenderer,
    QgsField,
    QgsLineSymbol,
    QgsMarkerLineSymbolLayer,
    QgsMarkerSymbol,
    QgsPalLayerSettings,
    QgsRendererCategory,
    QgsSimpleMarkerSymbolLayer,
    QgsSimpleMarkerSymbolLayerBase,
    QgsVectorLayer,
    QgsVectorLayerSimpleLabeling,
)

from ribasim_qgis.core import geopackage


class Input(abc.ABC):
    """Abstract base class for Ribasim input layers."""

    def __init__(self, path: Path):
        self._path = path

    @classmethod
    @abc.abstractmethod
    def input_type(cls) -> str:
        ...

    @classmethod
    @abc.abstractmethod
    def geometry_type(cls) -> str:
        ...

    @classmethod
    @abc.abstractmethod
    def attributes(cls) -> list[QgsField]:
        ...

    @classmethod
    def is_spatial(cls):
        return False

    @classmethod
    def nodetype(cls):
        return cls.input_type().split("/")[0].strip()

    @classmethod
    def create(
        cls,
        path: Path,
        crs: QgsCoordinateReferenceSystem,
        names: list[str],
    ) -> Input:
        if cls.input_type() in names:
            raise ValueError(f"Name already exists in geopackage: {cls.input_type()}")
        instance = cls(path)
        instance.layer = instance.new_layer(crs)
        return instance

    def new_layer(self, crs: QgsCoordinateReferenceSystem) -> QgsVectorLayer:
        """
        Separate creation of the instance with creating the layer, since the
        layer might also come from an existing geopackage.
        """
        layer = QgsVectorLayer(self.geometry_type(), self.input_type(), "memory")
        provider = layer.dataProvider()
        assert provider is not None
        provider.addAttributes(self.attributes())
        layer.updateFields()
        layer.setCrs(crs)
        return layer

    def set_defaults(self) -> None:
        defaults = getattr(self, "defaults", None)
        if self.layer is None or defaults is None:
            return
        fields = self.layer.fields()
        for name, definition in defaults.items():
            index = fields.indexFromName(name)
            self.layer.setDefaultValueDefinition(index, definition)

    def set_read_only(self) -> None:
        pass

    @property
    def renderer(self) -> QgsFeatureRenderer | None:
        return None

    @property
    def labels(self) -> Any:
        return None

    def layer_from_geopackage(self) -> QgsVectorLayer:
        self.layer = QgsVectorLayer(
            f"{self._path}|layername={self.input_type()}", self.input_type()
        )
        return self.layer

    def from_geopackage(self) -> tuple[QgsVectorLayer, Any, Any]:
        self.layer_from_geopackage()
        return (self.layer, self.renderer, self.labels)

    def write(self) -> None:
        self.layer = geopackage.write_layer(self._path, self.layer, self.input_type())
        self.set_defaults()

    def remove_from_geopackage(self) -> None:
        geopackage.remove_layer(self._path, self.input_type())

    def set_editor_widget(self) -> None:
        # Calling during new_layer doesn't have any effect...
        pass


class Node(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Node"

    @classmethod
    def geometry_type(cls) -> str:
        return "Point"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("name", QVariant.String),
            QgsField("type", QVariant.String),
        ]

    @classmethod
    def is_spatial(cls):
        return True

    def write(self) -> None:
        # Special case the Node layer write because it needs to generate a new file.
        self.layer = geopackage.write_layer(
            self._path, self.layer, self.input_type(), newfile=True
        )
        self.set_defaults()
        return

    def set_editor_widget(self) -> None:
        layer = self.layer
        index = layer.fields().indexFromName("type")
        setup = QgsEditorWidgetSetup(
            "ValueMap",
            {"map": {node: node for node in NONSPATIALNODETYPES}},
        )
        layer.setEditorWidgetSetup(index, setup)

        layer_form_config = layer.editFormConfig()
        layer_form_config.setReuseLastValue(1, True)
        layer.setEditFormConfig(layer_form_config)

        return

    @property
    def renderer(self) -> QgsCategorizedSymbolRenderer:
        shape = Qgis.MarkerShape
        MARKERS: dict[str, tuple[QColor, str, Qgis.MarkerShape]] = {
            "Basin": (QColor("blue"), "Basin", shape.Circle),
            "FractionalFlow": (QColor("red"), "FractionalFlow", shape.Triangle),
            "LinearResistance": (
                QColor("green"),
                "LinearResistance",
                shape.Triangle,
            ),
            "TabulatedRatingCurve": (
                QColor("green"),
                "TabulatedRatingCurve",
                shape.Diamond,
            ),
            "LevelBoundary": (QColor("green"), "LevelBoundary", shape.Circle),
            "FlowBoundary": (QColor("purple"), "FlowBoundary", shape.Hexagon),
            "Pump": (QColor("gray"), "Pump", shape.Hexagon),
            "Outlet": (QColor("green"), "Outlet", shape.Hexagon),
            "ManningResistance": (QColor("red"), "ManningResistance", shape.Diamond),
            "Terminal": (QColor("purple"), "Terminal", shape.Square),
            "DiscreteControl": (QColor("black"), "DiscreteControl", shape.Star),
            "PidControl": (QColor("black"), "PidControl", shape.Cross2),
            "User": (QColor("green"), "User", shape.Square),
            # All other nodes, or incomplete input
            "": (QColor("white"), "", shape.Circle),
        }

        categories = []
        for value, (color, label, marker_shape) in MARKERS.items():
            symbol = QgsMarkerSymbol()
            cast(QgsSimpleMarkerSymbolLayerBase, symbol.symbolLayer(0)).setShape(
                marker_shape
            )
            symbol.setColor(QColor(color))
            symbol.setSize(4)
            category = QgsRendererCategory(value, symbol, label, render=True)
            categories.append(category)

        renderer = QgsCategorizedSymbolRenderer(attrName="type", categories=categories)
        return renderer

    @property
    def labels(self) -> Any:
        pal_layer = QgsPalLayerSettings()
        pal_layer.fieldName = """concat("name", ' #', "fid")"""
        pal_layer.isExpression = True
        pal_layer.dist = 2.0
        labels = QgsVectorLayerSimpleLabeling(pal_layer)
        return labels


class Edge(Input):
    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("name", QVariant.String),
            QgsField("from_node_id", QVariant.Int),
            QgsField("to_node_id", QVariant.Int),
            QgsField("edge_type", QVariant.String),
        ]

    @classmethod
    def geometry_type(cls) -> str:
        return "Linestring"

    @classmethod
    def input_type(cls) -> str:
        return "Edge"

    @classmethod
    def is_spatial(cls):
        return True

    def set_editor_widget(self) -> None:
        layer = self.layer
        index = layer.fields().indexFromName("edge_type")
        setup = QgsEditorWidgetSetup(
            "ValueMap",
            {"map": {node: node for node in EDGETYPES}},
        )
        layer.setEditorWidgetSetup(index, setup)

        layer_form_config = layer.editFormConfig()
        layer_form_config.setReuseLastValue(1, True)
        layer.setEditFormConfig(layer_form_config)

        return

    @property
    def renderer(self) -> QgsCategorizedSymbolRenderer:
        MARKERS = {
            "flow": (QColor("#3690c0"), "flow"),  # lightblue
            "control": (QColor("gray"), "control"),
            "": (QColor("black"), ""),  # All other edges, or incomplete input
        }

        categories = []
        for value, (colour, label) in MARKERS.items():
            # Create line
            symbol = QgsLineSymbol()
            symbol.setColor(QColor(colour))
            symbol.setWidth(0.5)

            # Create an arrow marker to indicate directionality
            arrow_marker = QgsSimpleMarkerSymbolLayer()
            arrow_marker.setShape(Qgis.MarkerShape.ArrowHeadFilled)
            arrow_marker.setColor(QColor(colour))
            arrow_marker.setSize(3)
            arrow_marker.setStrokeStyle(Qt.PenStyle(Qt.NoPen))

            # Add marker to line
            marker_symbol = QgsMarkerSymbol()
            marker_symbol.changeSymbolLayer(0, arrow_marker)
            marker_line_symbol_layer = cast(
                QgsMarkerLineSymbolLayer,
                QgsMarkerLineSymbolLayer.create({"placements": "SegmentCenter"}),
            )

            marker_line_symbol_layer.setSubSymbol(marker_symbol)
            symbol.appendSymbolLayer(marker_line_symbol_layer)

            category = QgsRendererCategory(value, symbol, label)
            category.setRenderState(True)
            categories.append(category)

        renderer = QgsCategorizedSymbolRenderer(
            attrName="edge_type", categories=categories
        )
        return renderer

    @property
    def labels(self) -> Any:
        pal_layer = QgsPalLayerSettings()
        pal_layer.fieldName = """concat("name", ' #', "fid")"""
        pal_layer.isExpression = True
        pal_layer.placement = Qgis.LabelPlacement.Line
        pal_layer.dist = 1.0
        labels = QgsVectorLayerSimpleLabeling(pal_layer)
        return labels


class BasinProfile(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Basin / profile"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("area", QVariant.Double),
            QgsField("level", QVariant.Double),
        ]


class BasinStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Basin / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("drainage", QVariant.Double),
            QgsField("potential_evaporation", QVariant.Double),
            QgsField("infiltration", QVariant.Double),
            QgsField("precipitation", QVariant.Double),
            QgsField("urban_runoff", QVariant.Double),
        ]


class BasinTime(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Basin / time"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("time", QVariant.DateTime),
            QgsField("node_id", QVariant.Int),
            QgsField("drainage", QVariant.Double),
            QgsField("potential_evaporation", QVariant.Double),
            QgsField("infiltration", QVariant.Double),
            QgsField("precipitation", QVariant.Double),
            QgsField("urban_runoff", QVariant.Double),
        ]


class BasinSubgridLevel(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Basin / subgrid"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("subgrid_id", QVariant.Int),
            QgsField("node_id", QVariant.Int),
            QgsField("basin_level", QVariant.Double),
            QgsField("subgrid_level", QVariant.Double),
        ]


class BasinState(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Basin / state"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("level", QVariant.Double),
            QgsField("concentration", QVariant.Double),
        ]


class TabulatedRatingCurveStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "TabulatedRatingCurve / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("active", QVariant.Bool),
            QgsField("level", QVariant.Double),
            QgsField("discharge", QVariant.Double),
            QgsField("control_state", QVariant.String),
        ]


class TabulatedRatingCurveTime(Input):
    @classmethod
    def input_type(cls) -> str:
        return "TabulatedRatingCurve / time"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("time", QVariant.DateTime),
            QgsField("node_id", QVariant.Int),
            QgsField("level", QVariant.Double),
            QgsField("discharge", QVariant.Double),
        ]


class FractionalFlowStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "FractionalFlow / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("fraction", QVariant.Double),
            QgsField("control_state", QVariant.String),
        ]


class LinearResistanceStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "LinearResistance / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("active", QVariant.Bool),
            QgsField("resistance", QVariant.Double),
            QgsField("control_state", QVariant.String),
        ]


class ManningResistanceStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "ManningResistance / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("active", QVariant.Bool),
            QgsField("length", QVariant.Double),
            QgsField("manning_n", QVariant.Double),
            QgsField("profile_width", QVariant.Double),
            QgsField("profile_slope", QVariant.Double),
            QgsField("control_state", QVariant.String),
        ]


class LevelBoundaryStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "LevelBoundary / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("active", QVariant.Bool),
            QgsField("level", QVariant.Double),
        ]


class LevelBoundaryTime(Input):
    @classmethod
    def input_type(cls) -> str:
        return "LevelBoundary / time"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("time", QVariant.DateTime),
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("level", QVariant.Double),
        ]


class PumpStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Pump / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("active", QVariant.Bool),
            QgsField("flow_rate", QVariant.Double),
            QgsField("min_flow_rate", QVariant.Double),
            QgsField("max_flow_rate", QVariant.Double),
            QgsField("control_state", QVariant.String),
        ]


class OutletStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Outlet / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("active", QVariant.Bool),
            QgsField("flow_rate", QVariant.Double),
            QgsField("min_flow_rate", QVariant.Double),
            QgsField("max_flow_rate", QVariant.Double),
            QgsField("min_crest_level", QVariant.Double),
            QgsField("control_state", QVariant.String),
        ]


class TerminalStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Terminal / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [QgsField("node_id", QVariant.Int)]


class FlowBoundaryStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "FlowBoundary / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("active", QVariant.Bool),
            QgsField("flow_rate", QVariant.Double),
        ]


class FlowBoundaryTime(Input):
    @classmethod
    def input_type(cls) -> str:
        return "FlowBoundary / time"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("time", QVariant.DateTime),
            QgsField("node_id", QVariant.Int),
            QgsField("flow_rate", QVariant.Double),
        ]


class DiscreteControlCondition(Input):
    @classmethod
    def input_type(cls) -> str:
        return "DiscreteControl / condition"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("listen_feature_id", QVariant.Int),
            QgsField("variable", QVariant.String),
            QgsField("greater_than", QVariant.Double),
        ]


class DiscreteControlLogic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "DiscreteControl / logic"

    @classmethod
    def geometry_type(cls) -> str:
        return "LineString"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("control_state", QVariant.String),
            QgsField("truth_state", QVariant.String),
        ]


class PidControlStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "PidControl / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "LineString"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("active", QVariant.Bool),
            QgsField("listen_node_id", QVariant.Int),
            QgsField("target", QVariant.Double),
            QgsField("proportional", QVariant.Double),
            QgsField("integral", QVariant.Double),
            QgsField("derivative", QVariant.Double),
        ]


class PidControlTime(Input):
    @classmethod
    def input_type(cls) -> str:
        return "PidControl / time"

    @classmethod
    def geometry_type(cls) -> str:
        return "LineString"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("listen_node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("target", QVariant.Double),
            QgsField("proportional", QVariant.Double),
            QgsField("integral", QVariant.Double),
            QgsField("derivative", QVariant.Double),
        ]


class UserStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "User / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("active", QVariant.Bool),
            QgsField("demand", QVariant.Double),
            QgsField("return_factor", QVariant.Double),
            QgsField("priority", QVariant.Int),
        ]


class UserTime(Input):
    @classmethod
    def input_type(cls) -> str:
        return "User / time"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("demand", QVariant.Double),
            QgsField("return_factor", QVariant.Double),
            QgsField("priority", QVariant.Int),
        ]


NODES: dict[str, type[Input]] = {
    cls.input_type(): cls  # type: ignore[type-abstract] # mypy doesn't see that all classes are concrete.
    for cls in Input.__subclasses__()
}
NONSPATIALNODETYPES: set[str] = {
    cls.nodetype() for cls in Input.__subclasses__() if not cls.is_spatial()
}
EDGETYPES = {"flow", "control"}


def load_nodes_from_geopackage(path: Path) -> dict[str, Input]:
    # List the names in the geopackage
    gpkg_names = geopackage.layers(path)
    nodes = {}
    for layername in gpkg_names:
        nodes[layername] = NODES[layername](path)
    return nodes
