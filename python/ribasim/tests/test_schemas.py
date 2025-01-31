from unittest.mock import patch

import pandas as pd
import pytest
import ribasim
from pandas.testing import assert_frame_equal
from pydantic import ValidationError
from ribasim import Model
from ribasim.db_utils import _get_db_schema_version, _set_db_schema_version
from ribasim.migrations import _rename_column
from ribasim.nodes import basin
from ribasim.schemas import BasinProfileSchema
from shapely.geometry import Point


def test_config_inheritance():
    assert BasinProfileSchema.__config__.add_missing_columns
    assert BasinProfileSchema.__config__.coerce


@patch("ribasim.schemas.migrations.nodeschema_migration")
def test_migration(migration, basic, tmp_path):
    toml_path = tmp_path / "basic.toml"
    db_path = tmp_path / "database.gpkg"
    basic.write(toml_path)

    # Migration is not needed on default model
    Model.read(toml_path)
    assert not migration.called

    # Fake old schema that needs migration
    _set_db_schema_version(db_path, 0)
    Model.read(toml_path)
    assert migration.called


def test_model_schema(basic, tmp_path):
    toml_path = tmp_path / "basic.toml"
    db_path = tmp_path / "database.gpkg"
    basic.write(toml_path)

    assert _get_db_schema_version(db_path) == ribasim.__schema_version__
    _set_db_schema_version(db_path, 0)
    assert _get_db_schema_version(db_path) == 0


def test_geometry_validation():
    with pytest.raises(
        ValidationError,
        match="Column 'geometry' failed element-wise validator number 0: <Check is_correct_geometry_type> failure cases",
    ):
        basin.Area(geometry=[Point([1.0, 2.0])])


def test_column_rename():
    df = pd.DataFrame({"edge_type": [1], "link_type": [2]})
    _rename_column(df, "edge_type", "link_type")
    assert_frame_equal(df, pd.DataFrame({"link_type": [1]}))
    df = pd.DataFrame({"edge_type": [1]})
    _rename_column(df, "edge_type", "link_type")
    assert_frame_equal(df, pd.DataFrame({"link_type": [1]}))
    df = pd.DataFrame({"link_type": [2]})
    with pytest.raises(KeyError, match="\['edge_type'\] not found in axis"):
        _rename_column(df, "edge_type", "link_type")
