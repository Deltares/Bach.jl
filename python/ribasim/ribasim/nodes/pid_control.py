from pandera.typing import DataFrame

from ribasim.schemas import PidControlStaticSchema, PidControlTimeSchema


class Static(DataFrame[PidControlStaticSchema]):
    def __init__(self, **kwargs):
        super().__init__(data=dict(**kwargs))


class Time(DataFrame[PidControlTimeSchema]):
    def __init__(self, **kwargs):
        super().__init__(data=dict(**kwargs))