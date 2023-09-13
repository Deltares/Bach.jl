from pathlib import Path

import ribasim_testmodels

if __name__ == "__main__":
    datadir = Path("data")

    models = [
        model_generator()
        for model_generator in map(
            ribasim_testmodels.__dict__.get, ribasim_testmodels.__all__
        )
    ]

    for model in models:
        model.write(datadir / model.modelname)
