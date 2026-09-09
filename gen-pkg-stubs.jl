#!/usr/bin/env -S julia --color=yes

using Pkg

"""
    generate_module_stub(path, name) -> Union{String,Nothing}

Create an empty `module \$name end` definition at `path` if a file does not already exist
there. Returns `path` if a stub was created, or `nothing` if a file already existed there.
"""
function generate_module_stub(path::AbstractString, name::AbstractString)
    isfile(path) && return nothing

    mkpath(dirname(path))

    # Define an empty module to avoid warnings such as:
    # ```
    # WARNING: --output requested, but no modules defined during run
    # ```
    open(path, "w") do io
        println(io, "module $name")
        println(io, "end")
    end
    return path
end

"""
    generate_project_stub(env) -> Union{String,Nothing}

Create an entry point (`src/<name>.jl`) for a named project where it does not yet exist.

Creating these stubs allows `Pkg.instantiate` to succeed before the real package contents
have been copied into a Docker image. Doing this makes better use of Docker layer caching
as most dependencies can be installed/precompiled before we copy in `src`/`ext` content.
"""
function generate_project_stub(env::Pkg.Types.EnvCache)
    name = env.project.name
    name === nothing && return nothing

    path = joinpath(dirname(env.project_file), "src", "$name.jl")
    return generate_module_stub(path, name)
end

"""
    generate_path_tracked_stubs(env) -> Vector{String}

For each Manifest dependency tracked via a local filesystem path (added via `Pkg.develop`)
that isn't present on disk, generate a stub module for the package and for each of its
extensions.

Creating these stubs allows `Pkg.instantiate` to succeed before the real package contents
have been copied into a Docker image. Doing this makes better use of Docker layer caching
as most dependencies can be installed/precompiled before we copy in `src`/`ext` content.
"""
function generate_path_tracked_stubs(env::Pkg.Types.EnvCache)
    manifest = env.manifest
    paths = String[]
    for (uuid, dep) in pairs(Pkg.dependencies(env))
        dep.is_tracking_path || continue

        path = generate_module_stub(joinpath(dep.source, "src", "$(dep.name).jl"), dep.name)
        path !== nothing && push!(paths, path)

        for ext in keys(manifest[uuid].exts)
            path = generate_module_stub(joinpath(dep.source, "ext", "$ext.jl"), ext)
            path !== nothing && push!(paths, path)
        end
    end
    return paths
end

function parse_args(args)
    generate_project_stub = nothing
    for arg in args
        m = match(r"^--generate-project-stub=(yes|no)$", arg)
        if m !== nothing
            generate_project_stub = m[1] == "yes"
        end
    end

    # Julia 1.10.0 - 1.10.6 and 1.11.0 require the root stub to be present when
    # instantiating a named Julia project.
    if generate_project_stub === nothing
        generate_project_stub = v"1.10.0" <= VERSION <= v"1.10.6" || VERSION == v"1.11.0"
    end

    return (; generate_project_stub)
end

function main()
    env = Pkg.Types.EnvCache()
    stub_paths = String[]

    flag = parse_args(ARGS)
    if flag.generate_project_stub
        @info "Generating project stub..."
        project_stub_path = generate_project_stub(env)
        project_stub_path !== nothing && push!(stub_paths, project_stub_path)
    end

    @info "Generating dependency stubs..."
    append!(stub_paths, generate_path_tracked_stubs(env))

    @debug begin
        "Generated $(length(stub_paths)) stub modules:\n$(join(stub_paths, '\n'))"
    end
end

if abspath(PROGRAM_FILE) == @__FILE__()
    main()
end
