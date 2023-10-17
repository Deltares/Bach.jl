# generated by datamodel-codegen:
#   filename:  Config.schema.json

from __future__ import annotations

from datetime import datetime
from typing import List, Optional, Union

from pydantic import BaseModel


class Output(BaseModel):
    basin: str = "output/basin.arrow"
    flow: str = "output/flow.arrow"
    control: str = "output/control.arrow"
    outstate: Optional[str] = None
    compression: str = "zstd"
    compression_level: int = 6


class Solver(BaseModel):
    algorithm: str = "QNDF"
    saveat: Union[float, List[float]] = []
    adaptive: bool = True
    dt: Optional[float] = None
    dtmin: Optional[float] = None
    dtmax: Optional[float] = None
    force_dtmin: bool = False
    abstol: float = 1e-06
    reltol: float = 0.001
    maxiters: int = 1000000000
    sparse: bool = True
    autodiff: bool = True


class Logging(BaseModel):
    verbosity: str = "info"
    timing: bool = False


class Terminal(BaseModel):
    static: Optional[str] = None


class PidControl(BaseModel):
    static: Optional[str] = None
    time: Optional[str] = None


class LevelBoundary(BaseModel):
    static: Optional[str] = None
    time: Optional[str] = None


class Pump(BaseModel):
    static: Optional[str] = None


class TabulatedRatingCurve(BaseModel):
    static: Optional[str] = None
    time: Optional[str] = None


class User(BaseModel):
    static: Optional[str] = None
    time: Optional[str] = None


class FlowBoundary(BaseModel):
    static: Optional[str] = None
    time: Optional[str] = None


class Basin(BaseModel):
    profile: Optional[str] = None
    state: Optional[str] = None
    static: Optional[str] = None
    time: Optional[str] = None


class ManningResistance(BaseModel):
    static: Optional[str] = None


class DiscreteControl(BaseModel):
    condition: Optional[str] = None
    logic: Optional[str] = None


class Outlet(BaseModel):
    static: Optional[str] = None


class LinearResistance(BaseModel):
    static: Optional[str] = None


class FractionalFlow(BaseModel):
    static: Optional[str] = None


class Config(BaseModel):
    starttime: datetime
    endtime: datetime
    update_timestep: float = 86400
    relative_dir: str = "."
    input_dir: str = "."
    output_dir: str = "."
    geopackage: str
    output: Output = {
        "basin": "output/basin.arrow",
        "flow": "output/flow.arrow",
        "control": "output/control.arrow",
        "outstate": None,
        "compression": "zstd",
        "compression_level": 6,
    }
    solver: Solver = {
        "algorithm": "QNDF",
        "saveat": [],
        "adaptive": True,
        "dt": None,
        "dtmin": None,
        "dtmax": None,
        "force_dtmin": False,
        "abstol": 1e-06,
        "reltol": 0.001,
        "maxiters": 1000000000,
        "sparse": True,
        "autodiff": True,
    }
    logging: Logging = {"verbosity": {"level": 0}, "timing": False}
    terminal: Terminal = {"static": None}
    pid_control: PidControl = {"static": None, "time": None}
    level_boundary: LevelBoundary = {"static": None, "time": None}
    pump: Pump = {"static": None}
    tabulated_rating_curve: TabulatedRatingCurve = {"static": None, "time": None}
    user: User = {"static": None, "time": None}
    flow_boundary: FlowBoundary = {"static": None, "time": None}
    basin: Basin = {"profile": None, "state": None, "static": None, "time": None}
    manning_resistance: ManningResistance = {"static": None}
    discrete_control: DiscreteControl = {"condition": None, "logic": None}
    outlet: Outlet = {"static": None}
    linear_resistance: LinearResistance = {"static": None}
    fractional_flow: FractionalFlow = {"static": None}
