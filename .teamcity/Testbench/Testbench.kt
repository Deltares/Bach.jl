package Testbench

import Templates.*
import Testbench.IntegrationTestHWS.IntegrationTestHWS
import Testbench.RegressionTestODESolve.RegressionTestODESolve
import jetbrains.buildServer.configs.kotlin.Project

object Testbench : Project({
    subProject(IntegrationTestHWS)
    subProject(RegressionTestODESolve)
})
//object IntegrationTestHWS : Project ({
//    id("IntegrationTestHWS")
//    name = "IntegrationTestHWS"
//
//    buildType(IntegrationTest_Windows)
//    buildType(IntegrationTest_Linux)
//
//    template(IntegrationTestWindows)
//    template(IntegrationTestLinux)
//})
//
//object IntegrationTest_Windows : BuildType({
//    name = "IntegrationTestWindows"
//    templates(WindowsAgent, GithubCommitStatusIntegration, IntegrationTestWindows)
//
//    dependencies{
//        dependency(Windows_BuildRibasim) {
//            snapshot {
//            }
//
//            artifacts {
//                id = "ARTIFACT_DEPENDENCY_570"
//                cleanDestination = true
//                artifactRules = """
//                    ribasim_windows.zip!** => ribasim/build/ribasim
//                """.trimIndent()
//            }
//        }
//    }
//})
//
//object IntegrationTest_Linux : BuildType({
//    templates(LinuxAgent, GithubCommitStatusIntegration, IntegrationTestLinux)
//    name = "IntegrationTestLinux"
//
//    dependencies{
//        dependency(Linux_BuildRibasim) {
//            snapshot {
//            }
//
//            artifacts {
//                id = "ARTIFACT_DEPENDENCY_570"
//                cleanDestination = true
//                artifactRules = """
//                    ribasim_linux.zip!** => ribasim/build/ribasim
//                """.trimIndent()
//            }
//        }
//    }
//})