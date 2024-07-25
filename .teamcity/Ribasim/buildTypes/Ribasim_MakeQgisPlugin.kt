package Ribasim.buildTypes

import Templates.LinuxAgent
import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildSteps.script

object Ribasim_MakeQgisPlugin : BuildType({
    templates(LinuxAgent)
    name = "Make QGIS plugin"

    artifactRules = "ribasim_qgis.zip"

    vcs {
        root(Ribasim.vcsRoots.Ribasim)
        cleanCheckout = true
    }

    steps {
        script {
            id = "RUNNER_2193"
            scriptContent = """
                rsync --verbose --recursive --delete ribasim_qgis/ ribasim_qgis
                rm --force ribasim_qgis.zip
                zip -r ribasim_qgis.zip ribasim_qgis
            """.trimIndent()
        }
    }

    requirements {
        doesNotEqual("env.OS", "Windows_NT", "RQ_338")
    }

    disableSettings("RQ_338")
})
