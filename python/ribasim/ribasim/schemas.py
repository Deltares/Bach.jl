# Automatically generated file. Do not modify.

from collections.abc import Callable
from typing import Annotated, Any

import pandas as pd
import pandera as pa
import pyarrow
from pandera.dtypes import Int32
from pandera.typing import Index, Series

from ribasim import migrations


class _BaseSchema(pa.DataFrameModel):
    class Config:
        add_missing_columns = True
        coerce = True

    @classmethod
    def _index_name(self) -> str:
        return "fid"

    @pa.dataframe_parser
    def _name_index(cls, df):
        df.index.name = cls._index_name()
        return df

    @classmethod
    def migrate(cls, df: Any, schema_version: int) -> Any:
        f: Callable[[Any, Any], Any] = getattr(
            migrations, str(cls.__name__).lower() + "_migration", lambda x, _: x
        )
        return f(df, schema_version)


class BasinConcentrationExternalSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    substance: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )

    concentration: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )


class BasinConcentrationStateSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    substance: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )

    concentration: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )


class BasinConcentrationSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    substance: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )

    drainage: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    precipitation: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )


class BasinProfileSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    area: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(nullable=False)

    level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class BasinStateSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class BasinStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    drainage: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    potential_evaporation: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = (
        pa.Field(nullable=True)
    )

    infiltration: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    precipitation: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )


class BasinSubgridTimeSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    subgrid_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False
    )

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    basin_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    subgrid_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class BasinSubgridSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    subgrid_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False
    )

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    basin_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    subgrid_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class BasinTimeSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    drainage: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    potential_evaporation: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = (
        pa.Field(nullable=True)
    )

    infiltration: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    precipitation: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )


class ContinuousControlFunctionSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    input: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    output: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    controlled_variable: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )


class ContinuousControlVariableSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    listen_node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False
    )

    variable: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )

    weight: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    look_ahead: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )


class DiscreteControlConditionSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    compound_variable_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False
    )

    greater_than: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class DiscreteControlLogicSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    truth_state: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )

    control_state: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )


class DiscreteControlVariableSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    compound_variable_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False
    )

    listen_node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False
    )

    variable: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )

    weight: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    look_ahead: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )


class FlowBoundaryConcentrationSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    substance: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )

    concentration: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class FlowBoundaryStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    active: Series[Annotated[pd.ArrowDtype, pyarrow.bool_()]] = pa.Field(nullable=True)

    flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class FlowBoundaryTimeSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class FlowDemandStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    demand: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    demand_priority: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=True
    )


class FlowDemandTimeSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    demand: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    demand_priority: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=True
    )


class LevelBoundaryConcentrationSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    substance: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )

    concentration: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class LevelBoundaryStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    active: Series[Annotated[pd.ArrowDtype, pyarrow.bool_()]] = pa.Field(nullable=True)

    level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class LevelBoundaryTimeSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class LevelDemandStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    min_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    max_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    demand_priority: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=True
    )


class LevelDemandTimeSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    min_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    max_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    demand_priority: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=True
    )


class LinearResistanceStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    active: Series[Annotated[pd.ArrowDtype, pyarrow.bool_()]] = pa.Field(nullable=True)

    resistance: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    max_flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    control_state: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=True
    )


class ManningResistanceStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    active: Series[Annotated[pd.ArrowDtype, pyarrow.bool_()]] = pa.Field(nullable=True)

    length: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    manning_n: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    profile_width: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    profile_slope: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    control_state: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=True
    )


class OutletStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    active: Series[Annotated[pd.ArrowDtype, pyarrow.bool_()]] = pa.Field(nullable=True)

    flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    min_flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    max_flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    min_upstream_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    max_downstream_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = (
        pa.Field(nullable=True)
    )

    control_state: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=True
    )


class PidControlStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    active: Series[Annotated[pd.ArrowDtype, pyarrow.bool_()]] = pa.Field(nullable=True)

    listen_node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False
    )

    target: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    proportional: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    integral: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    derivative: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    control_state: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=True
    )


class PidControlTimeSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    listen_node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    target: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    proportional: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    integral: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    derivative: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    control_state: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=True
    )


class PumpStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    active: Series[Annotated[pd.ArrowDtype, pyarrow.bool_()]] = pa.Field(nullable=True)

    flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    min_flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    max_flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    min_upstream_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    max_downstream_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = (
        pa.Field(nullable=True)
    )

    control_state: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=True
    )


class TabulatedRatingCurveStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    active: Series[Annotated[pd.ArrowDtype, pyarrow.bool_()]] = pa.Field(nullable=True)

    level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    max_downstream_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = (
        pa.Field(nullable=True)
    )

    control_state: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=True
    )


class TabulatedRatingCurveTimeSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    flow_rate: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    max_downstream_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = (
        pa.Field(nullable=True)
    )


class UserDemandConcentrationSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    substance: Series[Annotated[pd.ArrowDtype, pyarrow.string()]] = pa.Field(
        nullable=False
    )

    concentration: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )


class UserDemandStaticSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    active: Series[Annotated[pd.ArrowDtype, pyarrow.bool_()]] = pa.Field(nullable=True)

    demand: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=True
    )

    return_factor: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    min_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    demand_priority: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=True
    )


class UserDemandTimeSchema(_BaseSchema):
    fid: Index[Int32] = pa.Field(default=1, check_name=True, coerce=True)

    node_id: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=False, default=0
    )

    time: Series[Annotated[pd.ArrowDtype, pyarrow.timestamp("ms")]] = pa.Field(
        nullable=False
    )

    demand: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    return_factor: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    min_level: Series[Annotated[pd.ArrowDtype, pyarrow.float64()]] = pa.Field(
        nullable=False
    )

    demand_priority: Series[Annotated[pd.ArrowDtype, pyarrow.int32()]] = pa.Field(
        nullable=True
    )
