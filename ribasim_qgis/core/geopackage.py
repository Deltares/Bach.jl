"""
Geopackage management utilities.

This module lightly wraps a few QGIS built in functions to:

    * List the layers of a geopackage
    * Write a layer to a geopackage
    * Remove a layer from a geopackage

"""

import sqlite3
from contextlib import contextmanager
from pathlib import Path

# qgis is monkey patched by plugins.processing.
# Importing from plugins directly for mypy
from plugins import processing
from qgis.core import QgsVectorFileWriter, QgsVectorLayer
from qgis.PyQt.QtXml import QDomDocument


@contextmanager
def sqlite3_cursor(path: Path):
    connection = sqlite3.connect(path)
    cursor = connection.cursor()
    try:
        yield cursor
    finally:
        cursor.close()
        connection.commit()
        connection.close()


def layers(path: Path) -> list[str]:
    """
    Return all layers that are present in the geopackage.

    Parameters
    ----------
    path: Path
        Path to the geopackage

    Returns
    -------
    layernames: list[str]
    """
    with sqlite3_cursor(path) as cursor:
        cursor.execute("Select table_name from gpkg_contents")
        layers = [item[0] for item in cursor.fetchall()]
    return layers


# Keep version synced __schema_version__ in ribasim/__init__.py
def write_schema_version(path: Path, version: int = 4) -> None:
    """Write the schema version to the geopackage."""
    with sqlite3_cursor(path) as cursor:
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS ribasim_metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            """
        )
        cursor.execute(
            "INSERT OR REPLACE INTO ribasim_metadata (key, value) VALUES ('schema_version', ?)",
            (version,),
        )
        sql = "INSERT INTO gpkg_contents (table_name, data_type, identifier) VALUES (?, ?, ?)"
        cursor.execute(sql, ("ribasim_metadata", "attributes", "ribasim_metadata"))


def write_layer(
    path: Path,
    layer: QgsVectorLayer,
    layername: str,
    newfile: bool = False,
    fid: str = "fid",
) -> QgsVectorLayer:
    """
    Write a QgsVectorLayer to a GeoPackage database.

    Parameters
    ----------
    path: Path
        Path to the GeoPackage file
    layer: QgsVectorLayer
        QGIS map layer (in-memory)
    layername: str
        Layer name to write in the GeoPackage
    newfile: bool, optional
        Whether to write a new GeoPackage file. Defaults to false.

    Returns
    -------
    layer: QgsVectorLayer
        The layer, now associated with the both GeoPackage and its QGIS
        representation.
    """
    options = QgsVectorFileWriter.SaveVectorOptions()
    options.driverName = "gpkg"
    options.layerName = layername
    options.layerOptions = [f"FID={fid}"]

    # Store the current layer style
    doc = QDomDocument()
    layer.exportNamedStyle(doc)

    if not newfile:
        options.actionOnExistingFile = (
            QgsVectorFileWriter.ActionOnExistingFile.CreateOrOverwriteLayer
        )
    write_result, error_message = QgsVectorFileWriter.writeAsVectorFormat(
        layer, str(path), options
    )
    if write_result != QgsVectorFileWriter.WriterError.NoError:
        raise RuntimeError(
            f"Layer {layername} could not be written to geopackage: {path}"
            f" with error: {error_message}"
        )
    layer = QgsVectorLayer(f"{path}|layername={layername}", layername, "ogr")

    # Load the stored layer style, and save it to the geopackage
    layer.importNamedStyle(doc)
    stylename = f"{layername.replace(' / ', '_')}Style"
    layer.saveStyleToDatabase(stylename, "", True, "")
    return layer


def remove_layer(path: Path, layer: str) -> None:
    query = {"DATABASE": f"{path}|layername={layer}", "SQL": f"drop table {layer}"}
    try:
        processing.run("native:spatialiteexecutesql", query)
    except Exception:
        raise RuntimeError(f"Failed to remove layer with {query}")
