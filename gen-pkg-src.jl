#!/usr/bin/env -S julia --color=yes

using Pkg

env = Pkg.Types.EnvCache()
project_dir = dirname(env.project_file)
entry_file = joinpath(project_dir, "src", "$(env.project.name).jl")

if !isfile(entry_file)
    mkdir(dirname(entry_file))
    touch(entry_file)
end
