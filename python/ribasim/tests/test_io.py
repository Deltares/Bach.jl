import pandas as pd
import pytest
import ribasim
from numpy.testing import assert_array_equal
from pandas.testing import assert_frame_equal
from pydantic import ValidationError
from ribasim import Pump


def assert_equal(a, b):
    """Like pandas.testing.assert_frame_equal, but ignoring the index."""
    if a is None and b is None:
        return True

    # TODO support assert basic == model, ignoring the index for all but node
    a = a.reset_index(drop=True)
    b = b.reset_index(drop=True)

    # avoid comparing datetime64[ns] with datetime64[ms]
    if "time" in a:
        a["time"] = a.time.astype("datetime64[ns]")
        b["time"] = b.time.astype("datetime64[ns]")

    return assert_frame_equal(a, b)


def test_basic(basic, tmp_path):
    model_orig = basic
    model_orig.write(tmp_path / "basic")
    model_loaded = ribasim.Model(filepath=tmp_path / "basic/ribasim.toml")

    index_a = model_orig.database.node.df.index.to_numpy(int)
    index_b = model_loaded.database.node.df.index.to_numpy(int)
    assert_array_equal(index_a, index_b)
    assert_equal(model_orig.database.node.df, model_loaded.database.node.df)
    assert_equal(model_orig.database.edge.df, model_loaded.database.edge.df)
    assert model_loaded.basin.time.df is None


def test_basic_transient(basic_transient, tmp_path):
    model_orig = basic_transient
    model_orig.write(tmp_path / "basic_transient")
    model_loaded = ribasim.Model(filepath=tmp_path / "basic_transient/ribasim.toml")
    print(model_loaded.database.node)
    print(model_loaded.database.edge)

    assert_equal(model_orig.database.node.df, model_loaded.database.node.df)
    assert_equal(model_orig.database.edge.df, model_loaded.database.edge.df)

    time = model_loaded.basin.time
    assert model_orig.basin.time.df.time[0] == time.df.time[0]
    assert_equal(model_orig.basin.time.df, time.df)
    assert time.df.shape == (1468, 8)


def test_pydantic():
    static_data_bad = pd.DataFrame(data={"node_id": [1, 2, 3]})

    with pytest.raises(ValidationError):
        Pump(static=static_data_bad)


def test_repr():
    static_data = pd.DataFrame(
        data={"node_id": [1, 2, 3], "flow_rate": [1.0, -1.0, 0.0]}
    )

    pump_1 = Pump(static=static_data)

    assert repr(pump_1) == "Pump(static=TableModel[PumpStaticSchema]())"
