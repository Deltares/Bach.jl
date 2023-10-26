using PackageCompiler
using TOML
using LibGit2

include("strip_cldr.jl")

# change directory to this script's location
cd(@__DIR__)

project_dir = "../ribasim_cli"
license_file = "../../LICENSE"
output_dir = "ribasim_cli"
git_repo = "../.."

create_app(
    project_dir,
    output_dir;
    # map from binary name to julia function name
    executables = ["ribasim" => "julia_main"],
    precompile_execution_file = "precompile.jl",
    include_lazy_artifacts = true,
    force = true,
)

include("add_metadata.jl")
add_metadata(project_dir, license_file, output_dir, git_repo)

# On Windows, write ribasim.cmd in the output_dir, that starts ribasim.exe.
# Since the bin dir contains a julia.exe and many DLLs that you may not want in your path,
# with this script you can put output_dir in your path instead.
if Sys.iswindows()
    cmd = raw"""
    @echo off
    "%~dp0bin\ribasim.exe" %*
    """
    open(normpath(output_dir, "ribasim.cmd"); write = true) do io
        print(io, cmd)
    end
end
