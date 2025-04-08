#!/usr/bin/env -S julia --color=yes

using Pkg

env = Pkg.Types.EnvCache()
project_dir = dirname(env.project_file)
project_name = env.project.name
entry_file = joinpath(project_dir, "src", "$(project_name).jl")

if !isfile(entry_file)
    mkdir(dirname(entry_file))

    # Define an empty module to avoid warnings such as:
    # ```
    # WARNING: --output requested, but no modules defined during run
    # ```
    open(entry_file, "w") do io
        println(io, "module $(project_name)")
        println(io, "end")
    end
end
