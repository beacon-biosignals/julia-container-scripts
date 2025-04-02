#!/usr/bin/env -S julia --color=yes

# Details on some of the influences on the design of this script:
#
# - Using `Pkg.gc(collect_delay=Day(0))` does not clean up unused `.ji` files. As we want to
#   only include the required `.ji` files used by the architecture of the current image we
#   need to copy what we want from the cache rather than copy everything and then clean.
# - Symlinks are used to create hybrid Julia depots which use a combination of the image
#   depot and the shared cache depot. This appears to be the best mechanism to avoid
#   unnecessary file transfer while still populating the shared cache depot.
# - Julia provides a limited some concurrent precompilation support between multiple Julia
#   processes. However, using `type=cache,sharing=shared` is dangerous since different
#   package versions overwrite the same precompilation file. Cache mounts should use
#   `sharing=locked` and alternatively `sharing=private`.
# - Julia standard libaries sometimes utilize precompile files (i.e. SuiteSparse)

using Base: PkgId, isprecompiled
using Pkg: Pkg
using SHA: sha256

function compilecache_paths(env::Pkg.Types.EnvCache)
    manifest = env.manifest
    dependencies = Pkg.dependencies(env)

    paths = String[]
    for (uuid, dep) in pairs(dependencies)
        pkg = PkgId(uuid, dep.name)

        # Packages must include there UUID to provide an accurate entry prefix and slug.
        # The function will return `nothing` when a precompilation file is not present.
        path = Base.compilecache_path(pkg)
        !isnothing(path) && push!(paths, path)

        # Extensions are not included in the dependencies list so we need to extract that
        for ext in keys(manifest[uuid].exts)
            # The extension UUID deterministic and based upon the parent UUID and the
            # extension name. e.g. https://github.com/JuliaLang/julia/blob/2fd6db2e2b96057dbfa15ee651958e03ca5ce0d9/base/loading.jl#L1561
            # Note: the `Base.uuid5` implementation differs from `UUIDs.uuid5`
            path = Base.compilecache_path(PkgId(Base.uuid5(pkg.uuid, ext), ext))
            !isnothing(path) && push!(paths, path)
        end
    end

    return paths
end

function depot_relpath(path::AbstractString)
    startswith(path, DEPOT_PATH[1]) || return nothing
    return relpath(path, DEPOT_PATH[1])
end

function sha256sum(path)
    return open(path, "r") do io
        bytes2hex(sha256(io))
    end
end

function set_distinct_active_project(f)
    project_file = Base.active_project()
    manifest_file = Base.project_file_manifest_path(project_file)
    hash = sha256sum(isfile(manifest_file) ? manifest_file : project_file)
    project_dir = dirname(project_file)
    new_project_dir = project_dir * "-" * hash
    mv(project_dir, new_project_dir)
    try
        symlink(new_project_dir, project_dir)
        Base.set_active_project(new_project_dir)
        f()
    finally
        islink(project_dir) && rm(project_dir)
        mv(new_project_dir, project_dir)
        Base.set_active_project(project_file)
    end
end

within_depot(path::AbstractString) = startswith(path, DEPOT_PATH[1])

cache_depot = ARGS[1]
final_depot = length(ARGS) >= 2 ? ARGS[2] : DEPOT_PATH[1]

env = Pkg.Operations.EnvCache()

# Precompile the depot packages using a Docker cache mount as the "compiled" directory.
# Using a cache mount allows us to perform precompilation for Julia packages once across all
# Docker builds on a system.
@info "Precompile packages..."

cache_compiled_dir = joinpath(cache_depot, "compiled")
final_compiled_dir = joinpath(final_depot, "compiled")

mkpath(cache_compiled_dir)

# Creating this symlink requires that the final compiled directory doesn't exist
symlink(cache_compiled_dir, final_compiled_dir)

old_cache_paths = filter!(within_depot, compilecache_paths(env))
set_distinct_active_project() do
    Pkg.precompile(; strict=true, timing=true)
end
cache_paths = filter!(within_depot, compilecache_paths(env))

@debug begin
    paths = map(cache_paths) do p
        string(p, !(p in old_cache_paths) ? " (new)" : "")
    end
    num_new = length(setdiff(cache_paths, old_cache_paths))
    total = length(cache_paths)
    "Precompile files to transfer (new additions $num_new/$total):\n$(join(paths, '\n'))"
end

rm(final_compiled_dir)
mkdir(final_compiled_dir)

# Copy required precompilation files for packages and extensions.
@info "Copy precompilation files into image..."
for cache_path in cache_paths
    cache_relpath = depot_relpath(cache_path)
    isnothing(cache_relpath) && continue

    src_cache_path = joinpath(cache_depot, cache_relpath)
    src_cache_dir = joinpath(cache_depot, dirname(cache_relpath))
    dst_cache_dir = joinpath(final_depot, dirname(cache_relpath))
    prefix = replace(basename(cache_relpath), r"\.ji$" => "")

    mkpath(dst_cache_dir)

    # Need to copy the `.ji` file and any associated library `.so`/`.dylib`
    for f in readdir(src_cache_dir)
        if startswith(f, prefix)
            cp(joinpath(src_cache_dir, f), joinpath(dst_cache_dir, f))
        end
    end
end

# Executes the `__init__` functions of packages by loading them. Doing this ensures that
# one time package setup that occurs at runtime happens during the Docker build
# (i.e. creating scrachspace).
@info "Initialize dependencies..."
for (uuid, dep) in pairs(Pkg.dependencies(env))
    if dep.is_direct_dep
        pkg = PkgId(uuid, dep.name)

        # If the copy precompilation file fails to transfer all of the required
        # precompilation files Julia will precompile the package upon the initial loading of
        # the package. If that happens then this script logic is flawed and requires
        # updating.
        if !isprecompiled(pkg)
            error("Precompilation incomplete for $(pkg.name)")
        end

        Base.require(Main, Symbol(pkg.name))
    end
end
