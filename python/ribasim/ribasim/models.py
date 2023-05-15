# generated by datamodel-codegen:
#   filename:  root.schema.json
#   timestamp: 2023-05-15T08:26:34+00:00

from __future__ import annotations

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class Edge(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    fid: int = Field(..., description="fid")
    to_node_id: int = Field(..., description="to_node_id")
    from_node_id: int = Field(..., description="from_node_id")


class PumpStatic(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    flow_rate: float = Field(..., description="flow_rate")
    node_id: int = Field(..., description="node_id")


class BasinForcing(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    time: datetime = Field(..., description="time")
    precipitation: float = Field(..., description="precipitation")
    infiltration: float = Field(..., description="infiltration")
    urban_runoff: float = Field(..., description="urban_runoff")
    node_id: int = Field(..., description="node_id")
    potential_evaporation: float = Field(..., description="potential_evaporation")
    drainage: float = Field(..., description="drainage")


class FractionalFlowStatic(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    node_id: int = Field(..., description="node_id")
    fraction: float = Field(..., description="fraction")


class LevelControlStatic(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    node_id: int = Field(..., description="node_id")
    conductance: float = Field(..., description="conductance")
    target_level: float = Field(..., description="target_level")


class LinearLevelConnectionStatic(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    node_id: int = Field(..., description="node_id")
    conductance: float = Field(..., description="conductance")


class Node(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    fid: int = Field(..., description="fid")
    type: str = Field(..., description="type")


class TabulatedRatingCurveTime(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    time: datetime = Field(..., description="time")
    node_id: int = Field(..., description="node_id")
    discharge: float = Field(..., description="discharge")
    level: float = Field(..., description="level")


class TabulatedRatingCurveStatic(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    node_id: int = Field(..., description="node_id")
    discharge: float = Field(..., description="discharge")
    level: float = Field(..., description="level")


class BasinState(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    storage: float = Field(..., description="storage")
    node_id: int = Field(..., description="node_id")


class BasinProfile(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    area: float = Field(..., description="area")
    storage: float = Field(..., description="storage")
    node_id: int = Field(..., description="node_id")
    level: float = Field(..., description="level")


class BasinStatic(BaseModel):
    remarks: Optional[str] = Field("", description="a hack for pandera")
    precipitation: float = Field(..., description="precipitation")
    infiltration: float = Field(..., description="infiltration")
    urban_runoff: float = Field(..., description="urban_runoff")
    node_id: int = Field(..., description="node_id")
    potential_evaporation: float = Field(..., description="potential_evaporation")
    drainage: float = Field(..., description="drainage")


class Root(BaseModel):
    Edge: Optional[Edge] = None
    PumpStatic: Optional[PumpStatic] = None
    BasinForcing: Optional[BasinForcing] = None
    FractionalFlowStatic: Optional[FractionalFlowStatic] = None
    LevelControlStatic: Optional[LevelControlStatic] = None
    LinearLevelConnectionStatic: Optional[LinearLevelConnectionStatic] = None
    Node: Optional[Node] = None
    TabulatedRatingCurveTime: Optional[TabulatedRatingCurveTime] = None
    TabulatedRatingCurveStatic: Optional[TabulatedRatingCurveStatic] = None
    BasinState: Optional[BasinState] = None
    BasinProfile: Optional[BasinProfile] = None
    BasinStatic: Optional[BasinStatic] = None
