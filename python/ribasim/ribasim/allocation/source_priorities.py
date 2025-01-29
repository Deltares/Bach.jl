from typing import Annotated

import pandas as pd
import pandera as pa
import pyarrow
from pandera.dtypes import Int32
from pandera.typing import Index, Series
from ribasim.input_base import TableModel
from ribasim.schemas import _BaseSchema


class AllocationSourcePrioritySchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)
    subnetwork_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False
    )
    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )
    source_priority: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False
    )


class AllocationSourcePriorityTable(TableModel[AllocationSourcePrioritySchema]):
    pass
