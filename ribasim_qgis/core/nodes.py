"""
Classes to represent the Ribasim node layers.

The classes specify:

* The (unabbreviated) name
* The type of geometry ("No Geometry", "Point", "LineString", "Polygon")
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
from typing import Any

from PyQt5.QtCore import QVariant
from qgis.core import (
    Qgis,
    QgsCoordinateReferenceSystem,
    QgsEditorWidgetSetup,
    QgsField,
    QgsPalLayerSettings,
    QgsVectorLayer,
    QgsVectorLayerSimpleLabeling,
)

from ribasim_qgis.core import geopackage

STYLE_DIR = Path(__file__).parent / "styles"


class Input(abc.ABC):
    """Abstract base class for Ribasim input layers."""

    def __init__(self, path: Path):
        self._path = path

    @classmethod
    @abc.abstractmethod
    def input_type(cls) -> str: ...

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def qgis_geometry_type(cls) -> Qgis.GeometryType:
        return Qgis.GeometryType.NullGeometry  # type: ignore

    @classmethod
    @abc.abstractmethod
    def attributes(cls) -> list[QgsField]: ...

    @classmethod
    def is_spatial(cls):
        return False

    @classmethod
    def fid_column(cls) -> str:
        return "fid"

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
        # Load style from QML file
        instance.load_default_style()
        return instance

    def new_layer(self, crs: QgsCoordinateReferenceSystem) -> QgsVectorLayer:
        """
        Separate creation of the instance with creating the layer.

        Needed since the layer might also come from an existing geopackage.
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

    def set_dropdown(self, name: str, options: set[str]) -> None:
        """Use a dropdown menu for a field in the editor widget."""
        layer = self.layer
        index = layer.fields().indexFromName(name)
        setup = QgsEditorWidgetSetup(
            "ValueMap",
            {"map": {node: node for node in options}},
        )
        layer.setEditorWidgetSetup(index, setup)

    def set_unique(self, name: str) -> None:
        layer = self.layer
        index = layer.fields().indexFromName(name)
        setup = QgsEditorWidgetSetup(
            "UniqueValues",
            {},
        )
        layer.setEditorWidgetSetup(index, setup)

    def set_read_only(self) -> None:
        pass

    @property
    def labels(self) -> Any:
        return None

    def layer_from_geopackage(self) -> QgsVectorLayer:
        self.layer = QgsVectorLayer(
            f"{self._path}|layername={self.input_type()}", self.input_type()
        )
        # Load style from database if exists, otherwise load and save default qml style
        _, success = self.layer.loadDefaultStyle()
        if not success:
            self.load_default_style()
            self.save_style()
        # Connect signal to save style to database when changed
        self.layer.styleChanged.connect(self.save_style)
        return self.layer

    def from_geopackage(self) -> tuple[QgsVectorLayer, Any]:
        self.layer_from_geopackage()
        return (self.layer, self.labels)

    def write(self) -> None:
        self.layer = geopackage.write_layer(
            self._path, self.layer, self.input_type(), fid=self.fid_column()
        )
        self.set_defaults()

    def remove_from_geopackage(self) -> None:
        geopackage.remove_layer(self._path, self.input_type())

    def set_editor_widget(self) -> None:
        # Calling during new_layer doesn't have any effect...
        pass

    def stylename(self) -> str:
        return f"{self.input_type().replace(' / ', '_')}Style"

    def load_default_style(self):
        fn = STYLE_DIR / f"{self.stylename()}.qml"
        self.layer.loadNamedStyle(str(fn))

    def save_style(self):
        self.layer.saveStyleToDatabase(self.stylename(), "", True, "")


class Node(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Node"

    @classmethod
    def geometry_type(cls) -> str:
        return "Point"

    @classmethod
    def qgis_geometry_type(cls) -> Qgis.GeometryType:
        return Qgis.GeometryType.PointGeometry  # type: ignore

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("name", QVariant.String),
            QgsField("node_type", QVariant.String),
            QgsField("subnetwork_id", QVariant.Int),
        ]

    @classmethod
    def is_spatial(cls):
        return True

    @classmethod
    def fid_column(cls):
        return "node_id"

    def write(self) -> None:
        # Special case the Node layer write because it needs to generate a new file.
        self.layer = geopackage.write_layer(
            self._path,
            self.layer,
            self.input_type(),
            newfile=True,
            fid=self.fid_column(),
        )
        self.set_defaults()
        return

    def set_editor_widget(self) -> None:
        layer = self.layer
        node_type_field_index = layer.fields().indexFromName("node_type")
        self.set_dropdown("node_type", NONSPATIALNODETYPES)
        self.set_unique("node_id")

        layer_form_config = layer.editFormConfig()
        layer_form_config.setReuseLastValue(node_type_field_index, True)
        layer.setEditFormConfig(layer_form_config)

        return

    @property
    def labels(self) -> Any:
        pal_layer = QgsPalLayerSettings()
        pal_layer.fieldName = """concat("name", ' #', "node_id")"""
        pal_layer.isExpression = True
        pal_layer.dist = 2.0
        labels = QgsVectorLayerSimpleLabeling(pal_layer)
        return labels


class Edge(Input):
    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("edge_id", QVariant.Int),
            QgsField("name", QVariant.String),
            QgsField("from_node_id", QVariant.Int),
            QgsField("to_node_id", QVariant.Int),
            QgsField("edge_type", QVariant.String),
        ]

    @classmethod
    def geometry_type(cls) -> str:
        return "LineString"

    @classmethod
    def qgis_geometry_type(cls) -> Qgis.GeometryType:
        return Qgis.GeometryType.LineGeometry  # type: ignore

    @classmethod
    def input_type(cls) -> str:
        return "Edge"

    @classmethod
    def is_spatial(cls):
        return True

    @classmethod
    def fid_column(cls):
        return "edge_id"

    def set_editor_widget(self) -> None:
        layer = self.layer

        self.set_dropdown("edge_type", EDGETYPES)
        self.set_unique("edge_id")

        layer_form_config = layer.editFormConfig()
        layer.setEditFormConfig(layer_form_config)

        return

    @property
    def labels(self) -> Any:
        pal_layer = QgsPalLayerSettings()
        pal_layer.fieldName = """concat("name", ' #', "edge_id")"""
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
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("drainage", QVariant.Double),
            QgsField("potential_evaporation", QVariant.Double),
            QgsField("infiltration", QVariant.Double),
            QgsField("precipitation", QVariant.Double),
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
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("drainage", QVariant.Double),
            QgsField("potential_evaporation", QVariant.Double),
            QgsField("infiltration", QVariant.Double),
            QgsField("precipitation", QVariant.Double),
        ]


class BasinConcentrationExternal(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Basin / concentration_external"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("substance", QVariant.String),
            QgsField("concentration", QVariant.Double),
        ]


class BasinConcentrationState(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Basin / concentration_state"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("substance", QVariant.String),
            QgsField("concentration", QVariant.Double),
        ]


class BasinConcentration(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Basin / concentration"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("substance", QVariant.String),
            QgsField("drainage", QVariant.Double),
            QgsField("precipitation", QVariant.Double),
        ]


class BasinSubgrid(Input):
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


class BasinSubgridTime(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Basin / subgrid_time"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("subgrid_id", QVariant.Int),
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("basin_level", QVariant.Double),
            QgsField("subgrid_level", QVariant.Double),
        ]


class BasinArea(Input):
    @classmethod
    def input_type(cls) -> str:
        return "Basin / area"

    @classmethod
    def is_spatial(cls):
        return True

    @classmethod
    def geometry_type(cls) -> str:
        return "MultiPolygon"

    @classmethod
    def qgis_geometry_type(cls) -> Qgis.GeometryType:
        return Qgis.GeometryType.PolygonGeometry  # type: ignore

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [QgsField("node_id", QVariant.Int)]


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
            QgsField("flow_rate", QVariant.Double),
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
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("level", QVariant.Double),
            QgsField("flow_rate", QVariant.Double),
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
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("level", QVariant.Double),
        ]


class LevelBoundaryConcentration(Input):
    @classmethod
    def input_type(cls) -> str:
        return "LevelBoundary / concentration"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("substance", QVariant.String),
            QgsField("concentration", QVariant.Double),
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
            QgsField("min_upstream_level", QVariant.Double),
            QgsField("control_state", QVariant.String),
        ]


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
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("flow_rate", QVariant.Double),
        ]


class FlowBoundaryConcentration(Input):
    @classmethod
    def input_type(cls) -> str:
        return "FlowBoundary / concentration"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("substance", QVariant.String),
            QgsField("concentration", QVariant.Double),
        ]


class DiscreteControlVariable(Input):
    @classmethod
    def input_type(cls) -> str:
        return "DiscreteControl / variable"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("compound_variable_id", QVariant.Int),
            QgsField("listen_node_id", QVariant.Int),
            QgsField("variable", QVariant.String),
            QgsField("weight", QVariant.Double),
            QgsField("look_ahead", QVariant.Double),
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
            QgsField("compound_variable_id", QVariant.Int),
            QgsField("greater_than", QVariant.Double),
        ]


class DiscreteControlLogic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "DiscreteControl / logic"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("control_state", QVariant.String),
            QgsField("truth_state", QVariant.String),
        ]


class ContinuousControlVariable(Input):
    @classmethod
    def input_type(cls) -> str:
        return "ContinuousControl / variable"

    @classmethod
    def geometry_type(cs) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("listen_node_id", QVariant.Int),
            QgsField("variable", QVariant.String),
            QgsField("weight", QVariant.Double),
            QgsField("look_ahead", QVariant.Double),
        ]


class ContinuousControlFunction(Input):
    @classmethod
    def input_type(cls) -> str:
        return "ContinuousControl / function"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("input", QVariant.Double),
            QgsField("output", QVariant.Double),
            QgsField("controlled_variable", QVariant.String),
        ]


class PidControlStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "PidControl / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

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
        return "No Geometry"

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


class UserDemandStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "UserDemand / static"

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
            QgsField("demand_priority", QVariant.Int),
        ]


class UserDemandTime(Input):
    @classmethod
    def input_type(cls) -> str:
        return "UserDemand / time"

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
            QgsField("demand_priority", QVariant.Int),
        ]


class UserDemandConcentration(Input):
    @classmethod
    def input_type(cls) -> str:
        return "UserDemand / concentration"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("substance", QVariant.String),
            QgsField("concentration", QVariant.Double),
        ]


class LevelDemandStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "LevelDemand / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("min_level", QVariant.Double),
            QgsField("max_level", QVariant.Double),
            QgsField("demand_priority", QVariant.Int),
        ]


class LevelDemandTime(Input):
    @classmethod
    def input_type(cls) -> str:
        return "LevelDemand / time"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("min_level", QVariant.Double),
            QgsField("max_level", QVariant.Double),
            QgsField("demand_priority", QVariant.Int),
        ]


class FlowDemandStatic(Input):
    @classmethod
    def input_type(cls) -> str:
        return "FlowDemand / static"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("demand", QVariant.Double),
            QgsField("demand_priority", QVariant.Int),
        ]


class FlowDemandTime(Input):
    @classmethod
    def input_type(cls) -> str:
        return "FlowDemand / time"

    @classmethod
    def geometry_type(cls) -> str:
        return "No Geometry"

    @classmethod
    def attributes(cls) -> list[QgsField]:
        return [
            QgsField("node_id", QVariant.Int),
            QgsField("time", QVariant.DateTime),
            QgsField("demand", QVariant.Double),
            QgsField("demand_priority", QVariant.Int),
        ]


NODES: dict[str, type[Input]] = {
    cls.input_type(): cls  # type: ignore[type-abstract] # mypy doesn't see that all classes are concrete.
    for cls in Input.__subclasses__()
}
NONSPATIALNODETYPES: set[str] = {
    cls.nodetype() for cls in Input.__subclasses__() if not cls.is_spatial()
} | {"Terminal"}
EDGETYPES = {"flow", "control"}
SPATIALCONTROLNODETYPES = {
    "ContinuousControl",
    "DiscreteControl",
    "FlowDemand",
    "LevelDemand",
    "PidControl",
}


def load_nodes_from_geopackage(path: Path) -> dict[str, Input]:
    # List the names in the geopackage
    gpkg_names = geopackage.layers(path)
    nodes = {}
    for layername in gpkg_names:
        klass = NODES.get(layername)
        if klass is not None:
            nodes[layername] = klass(path)
    return nodes
