package Ribasim_Linux.buildTypes

import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildFeatures.commitStatusPublisher
import jetbrains.buildServer.configs.kotlin.buildSteps.script

object Linux_BuildRibasim : BuildType({
    templates(Ribasim.buildTypes.Linux_1)
    name = "Build Ribasim"

    artifactRules = """ribasim\build\ribasim => ribasim_linux.zip"""

    vcs {
        root(Ribasim.vcsRoots.Ribasim, ". => ribasim")
    }

    steps {
        script {
            name = "Set up pixi"
            id = "RUNNER_2415"
            workingDir = "ribasim"
            scriptContent = """
                #!/bin/bash
                # black magic
                source /usr/share/Modules/init/bash

                module load pixi
                pixi --version
                pixi run install-ci
            """.trimIndent()
        }
        script {
            name = "Build binary"
            id = "RUNNER_2416"
            workingDir = "ribasim"
            scriptContent = """
                #!/bin/bash
                # black magic
                source /usr/share/Modules/init/bash

                module load pixi
                module load gcc/11.3.0
                pixi run remove-artifacts
                pixi run build
            """.trimIndent()
        }
    }

    failureConditions {
        executionTimeoutMin = 120
    }

    features {
        commitStatusPublisher {
            id = "BUILD_EXT_295"
            publisher = github {
                githubUrl = "https://api.github.com"
                authType = personalToken {
                    token = "credentialsJSON:6b37af71-1f2f-4611-8856-db07965445c0"
                }
            }
        }
    }
})
