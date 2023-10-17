from typing import Optional

import pandera as pa
from pandera.engines.pandas_engine import PydanticModel
from pandera.typing import DataFrame
from pydantic import ConfigDict

from ribasim import models
from ribasim.input_base import TableModel

__all__ = ("User",)


class StaticSchema(pa.SchemaModel):
    model_config = ConfigDict(dtype=PydanticModel(models.UserStatic))


class TimeSchema(pa.SchemaModel):
    model_config = ConfigDict(dtype=PydanticModel(models.UserTime))


class User(TableModel):
    """
    User node type with demand and priority.

    Parameters
    ----------
    static: pandas.DataFrame
        table with static data for this node type.
    time: pandas.DataFrame
        table with static data for this node type (only demand can be transient).
    """

    static: Optional[DataFrame[StaticSchema]] = None
    time: Optional[DataFrame[TimeSchema]] = None
    model_config = ConfigDict(validate_assignment=True)

    def sort(self):
        if self.static is not None:
            self.static.sort_values("node_id", ignore_index=True, inplace=True)
        if self.time is not None:
            self.time.sort_values(
                ["node_id", "priority", "time"], ignore_index=True, inplace=True
            )
