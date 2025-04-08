#!/usr/bin/env -S julia --color=yes

# Details on some of the influences on the design of this script:
#
# - Using `Pkg.gc(collect_delay=Day(0))` does not clean up unused `.ji` files. As we want to
#   only include the required `.ji` files used by the architecture of the current image we
#   need to copy what we want from the cache rather than copy everything and then cleanup.
# - Symlinks are used to create hybrid Julia depots which use a combination of the final
#   depot and the cache depot. This appears to be the best mechanism to avoid unnecessary
#   file transfers while still populating a shared cache.
# - Julia provides some basic concurrent precompilation support between multiple Julia
#   processes. However, using `type=cache,sharing=shared` is dangerous since different
#   package versions overwrite the same precompilation file. Cache mounts should use
#   `sharing=locked` and alternatively `sharing=private`.
# - Julia standard libaries do make use of precompilation files in the user depot
#   (i.e. SuiteSparse)
# - Containers may already include pre-existing precompilation files. When using this script
#   most existing files will be preserved but any precompilation cache files required by the
#   active Julia project will overwrite any files where their content checksums do not
#   match.


# Limit the Julia versions which can run this script. We have this restriction as this is
# the first version of Julia to define `Base.isprecompiled` which is a critical self-check
# part of this script.
#
# https://github.com/JuliaLang/julia/pull/50218 (f6f35533f237d55e881276428bef2f091f9cae5b)
if VERSION < v"1.10.0-DEV.1604"
    error("Script $(basename(@__FILE__())) is only supported on Julia 1.10+")
end

using Base: PkgId, in_sysimage, isprecompiled
using Pkg: Pkg, PackageSpec
using SHA: sha256

# https://github.com/JuliaLang/julia/pull/53906 (e9d25ca09382b0f67a4c7770cba08bff3db3cb38)
if VERSION >= v"1.11.0-alpha1.76"
    compilecache_path = Base.compilecache_path
else
    using Base: StaleCacheKey, find_all_in_cache_path, stale_cachefile

    # Provide a `compilecache_path` method which accepts only `PkgId` on Julia 1.10.
    # Adapted from Julia's 1.10.0 version of `isprecompiled` and PR #53906.
    function compilecache_path(pkg::PkgId;
            ignore_loaded::Bool=false,
            stale_cache::Dict{StaleCacheKey,Bool}=Dict{StaleCacheKey, Bool}(),
            cachepaths::Vector{String}=Base.find_all_in_cache_path(pkg),
            sourcepath::Union{String,Nothing}=Base.locate_package(pkg)
        )
        path = nothing
        isnothing(sourcepath) && error("Cannot locate source for $(repr("text/plain", pkg))")
        for path_to_try in cachepaths
            staledeps = stale_cachefile(sourcepath, path_to_try, ignore_loaded = true)
            if staledeps === true
                continue
            end
            staledeps, _ = staledeps::Tuple{Vector{Any}, Union{Nothing, String}}
            # finish checking staledeps module graph
            for i in 1:length(staledeps)
                dep = staledeps[i]
                dep isa Module && continue
                modpath, modkey, modbuild_id = dep::Tuple{String, PkgId, UInt128}
                modpaths = find_all_in_cache_path(modkey)
                for modpath_to_try in modpaths::Vector{String}
                    stale_cache_key = (modkey, modbuild_id, modpath, modpath_to_try)::StaleCacheKey
                    if get!(() -> stale_cachefile(stale_cache_key...; ignore_loaded) === true,
                            stale_cache, stale_cache_key)
                        continue
                    end
                    @goto check_next_dep
                end
                @goto check_next_path
                @label check_next_dep
            end
            try
                # update timestamp of precompilation file so that it is the first to be tried by code loading
                touch(path_to_try)
            catch ex
                # file might be read-only and then we fail to update timestamp, which is fine
                ex isa IOError || rethrow()
            end
            path = path_to_try
            break
            @label check_next_path
        end
        return path
    end
end

"""
    root_package(env) -> @NamedTuple{pkg::Union{PkgId,Nothing},loadable::Bool}

For named Julia projects returns the `PkgId` and whether the package defines a `.jl` file
which would be used for loading the package.

It appears Julia doesn't clearly define term for this source file so I've opted to name it
"root". Alternatively, this could name be "entry".
"""
function root_package(env::Pkg.Types.EnvCache)
    if !isnothing(env.project.name) && !isnothing(env.project.uuid)
        pkg = PkgId(env.project.uuid, env.project.name)
        source_file = joinpath(dirname(env.project_file), "src", "$(env.project.name).jl")
        loadable = isfile(source_file)
    else
        pkg = nothing
        loadable = false
    end

    return (; pkg, loadable)
end

"""
    compilecache_paths(env) -> Vector{String}

Provide a complete list of compile cache paths for all Julia packages directly used or
depended upon within the active Julia project.
"""
function compilecache_paths(env::Pkg.Types.EnvCache)
    manifest = env.manifest

    results = String[]
    for (uuid, dep) in pairs(Pkg.dependencies(env))
        pkg = PkgId(uuid, dep.name)

        # Packages must include there UUID to provide an accurate entry prefix and slug.
        # The function will return `nothing` when a precompilation file is not present.
        path = compilecache_path(pkg)
        !isnothing(path) && push!(results, path)

        # Extensions are not included in the dependencies list so we need to extract that
        for ext in keys(manifest[pkg.uuid].exts)
            # The extension UUID deterministic and based upon the parent UUID and the
            # extension name. e.g. https://github.com/JuliaLang/julia/blob/2fd6db2e2b96057dbfa15ee651958e03ca5ce0d9/base/loading.jl#L1561
            # Note: the `Base.uuid5` implementation differs from `UUIDs.uuid5`
            path = compilecache_path(PkgId(Base.uuid5(pkg.uuid, ext), ext))
            !isnothing(path) && push!(results, path)
        end
    end

    root = root_package(env)
    if !isnothing(root.pkg) && root.loadable
        # The `compilecache_path` function doesn't work for this package (not sure why).
        # We'll add all cache paths we find to be safe.
        paths = Base.find_all_in_cache_path(root.pkg)
        append!(results, paths)
    end

    return results
end

"""
    depot_relpath(path) -> String

Create a path relative to the primary Julia depot provided that the path resides within the
depot. If the path exists outside the depot `nothing` will be returned.
"""
function depot_relpath(path::AbstractString)
    startswith(path, DEPOT_PATH[1]) || return nothing
    return relpath(path, DEPOT_PATH[1])
end

within_depot(path::AbstractString) = startswith(path, DEPOT_PATH[1])

"""
    sha256sum(path) -> String

Create a SHA-256 hexadecimal string from the contents of the provided `path`.
"""
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

cache_depot = ARGS[1]
final_depot = length(ARGS) >= 2 ? ARGS[2] : DEPOT_PATH[1]

env = Pkg.Operations.EnvCache()

# Precompile the depot packages using a Docker cache mount as the "compiled" directory.
# Using a cache mount allows us to perform precompilation for Julia packages once across all
# Docker builds on a system.
@info "Precompile packages..."

cache_compiled_dir = joinpath(cache_depot, "compiled")
final_compiled_dir = joinpath(final_depot, "compiled")
backup_compiled_dir = joinpath(final_depot, "compiled.backup")

mkpath(cache_compiled_dir)

# Creating this symlink requires that the final compiled directory doesn't exist. If it does
# we'll move the existing compiled directory temporarily.
isdir(final_compiled_dir) && mv(final_compiled_dir, backup_compiled_dir)
symlink(cache_compiled_dir, final_compiled_dir)

# Record the pre-existing precompile cache files which exist in the cache mount.
old_cache_paths = filter!(within_depot, compilecache_paths(env))

set_distinct_active_project() do
    # When a root package is defined but can not be loaded we need to exclude it from the
    # packages which are precompiled.
    root = root_package(env)
    package_specs = if !isnothing(root.pkg) && !root.loadable
        @warn "Package $(root.pkg.name) is incomplete. Excluding it from precompilation"
        [PackageSpec(; name=dep.name, uuid)
                     for (uuid, dep) in Pkg.dependencies(env)
                     if !in_sysimage(PkgId(uuid, dep.name))]
    else
        PackageSpec[]  # Precompile everything
    end

    Pkg.precompile(package_specs; strict=true, timing=true)
end

cache_paths = filter!(within_depot, compilecache_paths(env))

# Report the `.ji` files which will be transferred from the cache depot to the final depot.
#
# TODO: We could improve the accuracy of this message by utilizing checksums when
# determining if a cache file is new.
@debug begin
    paths = map(cache_paths) do p
        string(p, !(p in old_cache_paths) ? " (new)" : "", " ", sha256sum(p))
    end
    num_new = length(setdiff(cache_paths, old_cache_paths))
    total = length(cache_paths)
    "Precompile files to transfer (new additions $num_new/$total):\n$(join(paths, '\n'))"
end

# Delete symlink and restore the old compiled directory, if any.
rm(final_compiled_dir)
if isdir(backup_compiled_dir)
    mv(backup_compiled_dir, final_compiled_dir)
else
    mkdir(final_compiled_dir)
end

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

    # Need to copy the `.ji` file and any associated library `.so`/`.dylib` files
    for f in readdir(src_cache_dir)
        if startswith(f, prefix)
            src_file = joinpath(src_cache_dir, f)
            dst_file = joinpath(dst_cache_dir, f)

            # Copy over missing files or modified files
            if !isfile(dst_file) || sha256sum(src_file) != sha256sum(dst_file)
                cp(src_file, dst_file)
            end
        end
    end
end

# Executes the `__init__` functions of packages by loading them. Doing this ensures that
# one time package setup that occurs at runtime happens during the Docker build
# (i.e. creating scrachspace).
@info "Initialize dependencies..."
for (uuid, dep) in pairs(Pkg.dependencies(env))
    dep.is_direct_dep || continue
    pkg = PkgId(uuid, dep.name)

    # If the copy precompilation file fails to transfer all of the required
    # precompilation files Julia will precompile the package upon the initial loading of
    # the package. If that happens then this script logic is flawed and requires
    # updating.
    if !isprecompiled(pkg) && !in_sysimage(pkg)
        error("Precompilation incomplete for $(pkg.name)")
    end

    Base.require(Main, Symbol(pkg.name))
end

# Since `compilecache_path` doesn't work for the root package that means `isprecompiled`
# will always return `false`.
root = root_package(env)
if root.loadable
    if isempty(Base.find_all_in_cache_path(root.pkg))
        error("Precompilation incomplete for $(root.pkg.name)")
    end

    Base.require(Main, Symbol(root.pkg.name))
end

for cache_path in cache_paths
    println("$cache_path $(sha256sum(cache_path))")
end
