#!/usr/bin/env -S julia --color=yes

# Details on some of the influences on the design of this script:
#
# - Using `Pkg.gc(collect_delay=Day(0))` does not clean up unused `.ji` files. As we want to
#   only include the required `.ji` files used by the architecture of the current image we
#   need to copy what we want from the cache rather than copy everything and then cleanup.
# - Symlinks are used to create hybrid Julia depots which use a combination of the final
#   depot and the cache depot. This appears to be the best mechanism to avoid unnecessary
#   file transfers while still populating a shared cache.
# - Julia standard libaries do make use of precompilation files in the user depot
#   (i.e. SuiteSparse)
# - Julia utilizes the active project directory to generate unique `.ji` file slugs. When
#   using a depot shared between Docker containers this isn't necessarily unique enough so
#   we modify the project path to ensure generated slugs are both deterministic and unique.
# - Containers may already include pre-existing precompilation files. This script preserves
#   most of the existing precompilation files but but any precompilation cache files
#   required by the active Julia project will overwrite any pre-existing files when their
#   content checksums differ.
# - Purposely avoiding incorporating the fixed modification time workaround fix to the
#   "packages" directory within this script as doing so creates unnecessary image bloat if
#   this Docker step occurs in a separate statement from instantiation (for Julia < v1.11).

# Limit the Julia versions which can run this script. We have this restriction as this is
# the first version of Julia to define `Base.isprecompiled` which is a critical self-check
# part of this script.
#
# https://github.com/JuliaLang/julia/pull/50218 (f6f35533f237d55e881276428bef2f091f9cae5b)
if VERSION < v"1.10.0-DEV.1604"
    error("Script $(basename(@__FILE__())) is only supported on Julia 1.10+")
end

using Base: PkgId, in_sysimage, isprecompiled, isvalid_cache_header
using Dates: Dates, DateTime, @dateformat_str
using Pkg: Pkg, PackageSpec
using SHA: sha256

# https://github.com/JuliaLang/julia/pull/53906 (e9d25ca09382b0f67a4c7770cba08bff3db3cb38)
if VERSION >= v"1.11.0-alpha1.76"
    compilecache_path = Base.compilecache_path
else
    using Base: StaleCacheKey, find_all_in_cache_path, stale_cachefile

    # Provide a `compilecache_path` method which accepts a single argument on Julia 1.10.
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

# https://github.com/JuliaLang/julia/pull/53192 (d7b9ac8281cd988ffb5da9b0e7deed23b8d5cb28)
if VERSION < v"1.11.0-DEV.1589"
    Base.filesize(io::IOBuffer) = io.size
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

        # Packages must include their UUID to provide an accurate entry prefix and slug.
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

"""
    set_distinct_active_project(f) -> Any

Update the active Julia project to use a distinct path based upon the content hash of the
Manifest.toml (if available) or Project.toml. Used to ensure that `.ji` generate unique
slugs.

When Julia generates the `.ji` precompile slug it uses the [active Julia project path as
part of the hash](https://github.com/JuliaLang/julia/blob/019aa63fdeeabb0d42c435af2ade796938b3631a/base/loading.jl#L3150).
Typically, only one Julia Project.toml resides within a directory but inside of Docker build
containers it is possible for different Project.toml's to reside within the same path. This
can result in Julia generating a single `.ji` file for multiple versions of a Julia package
rather than a `.ji` file for each version.

Additionally, Julia searches through the pre-existing precompilation files for a package
before generating a new one. Due to this search behavior we don't need to use a
predetermined `.ji` file for Julia to be able to use it. We can take advantage of this by
modifying the Julia project path such we can generate unique `.ji` files for each version of
a Julia package.
"""
function set_distinct_active_project(f)
    # Generate a checksum based upon the content of the Manifest.toml (preferred) or the
    # Project.toml.
    project_file = Base.active_project()
    manifest_file = Base.project_file_manifest_path(project_file)
    hash = sha256sum(isfile(manifest_file) ? manifest_file : project_file)

    project_dir = dirname(project_file)
    new_project_dir = project_dir * "-" * hash

    # Co-locate the current Julia project directory to ensure that we not moving the project
    # content between disks.
    mv(project_dir, new_project_dir)
    try
        # Create a symlink which uses the old project directory to ensure that relative and
        # absolute paths in the Manifest.toml still work.
        symlink(new_project_dir, project_dir)
        Base.set_active_project(new_project_dir)
        f()
    finally
        islink(project_dir) && rm(project_dir)
        mv(new_project_dir, project_dir)
        Base.set_active_project(project_file)
    end
end

# https://github.com/JuliaLang/julia/blob/c3282ceaacb3a41dad6da853b7677e404e603c9a/src/staticdata_utils.c#L471
const JI_MAGIC = b"\373jli\r\n\032\n"

function rewrite(cachefile::AbstractString, old_new::Pair{<:AbstractString, <:AbstractString})
    old, new = old_new
    io = IOBuffer()
    mutated = false

    @debug "Rewriting $cachefile"
    open(cachefile) do f
        # https://github.com/JuliaLang/julia/blob/c3282ceaacb3a41dad6da853b7677e404e603c9a/src/staticdata_utils.c#L806-L807
        magic = read(f, sizeof(JI_MAGIC))
        magic == JI_MAGIC || error("File signature is not for a `.ji` file.")

        # Ensure we are attempting to read `.ji` file with a version we support.
        format_version = read(f, UInt16)
        if format_version != 12
            error("Version $format_version of a `.ji` file is not yet supported")
        end

        # https://github.com/JuliaLang/julia/blob/760b2e5b7396f9cc0da5efce0cadd5d1974c4069/base/loading.jl#L3412
        if iszero(isvalid_cache_header(seekstart(f)))
            throw(ArgumentError("Incompatible header in cache file $cachefile."))
        end

        # Most of the code below is adapted from `_parse_cache_header`:
        # https://github.com/JuliaLang/julia/blob/760b2e5b7396f9cc0da5efce0cadd5d1974c4069/base/loading.jl#L3243

        read(f, UInt8) # Skip flags

        # Skip modules
        while true
            n = read(f, Int32)
            n == 0 && break
            seek(f, position(f) + n + sizeof(UInt64) + sizeof(UInt64) + sizeof(UInt64))
        end

        # Read total bytes. We'll update this later if we modify `depname` or `modpath`.
        totbytes_pos = position(f)
        totbytes = Int64(read(f, UInt64)) # total bytes for file dependencies + preferences
        offset = 0

        @debug "totbytes = $totbytes"

        # Copy original file up to and including`totbytes`.
        seekstart(f)
        write(io, read(f, totbytes_pos + sizeof(totbytes)))

        # The end of the section which is tracked by `totbytes`.
        totbytes_pos_end = totbytes_pos + sizeof(totbytes) + totbytes

        # The `srctextpos` occurs right before the end of the `totbytes` section
        srctextpos_pos = totbytes_pos_end - sizeof(Int64)
        seek(f, srctextpos_pos)
        srctextpos = read(f, Int64)
        @debug "srctextpos = $srctextpos"

        seek(f, totbytes_pos + sizeof(totbytes))
        @assert position(f) == position(io)

        # Update the all `modpath` entries that match our criteria. We'll need to update
        # `totbytes` to match the updated number of bytes
        while true
            n2 = read(f, Int32)
            if n2 == 0
                write(io, n2)
                break
            end
            depname = String(read(f, n2))

            if startswith(depname, old)
                new_depname = replace(depname, old => new; count=1)
                offset += sizeof(new_depname) - n2

                @debug "depname: $depname => $new_depname"

                write(io, Int32(sizeof(new_depname)))
                write(io, new_depname)
                mutated = true
            else
                write(io, n2)
                write(io, depname)
            end

            # Additional fields were added in Julia 1.11.0 but the `.ji` version number
            # wasn't updated.
            # https://github.com/JuliaLang/julia/pull/49866
            if VERSION < v"1.11.0-DEV.683"
                # Skip `mtime`
                write(io, read(f, sizeof(Float64)))
            else
                # Skip `fsize`, `hash`, and `mtime`
                write(io, read(f, sizeof(UInt64) + sizeof(UInt32) + sizeof(Float64)))
            end

            n1 = read(f, Int32)
            write(io, n1)
            if n1 != 0
                while true
                    n1 = read(f, Int32)
                    if n1 == 0
                        write(io, n1)
                        break
                    end
                    modpath = String(read(f, n1))

                    if startswith(modpath, old)
                        new_modpath = replace(modpath, old => new; count=1)
                        offset += sizeof(new_modpath) - n1

                        @debug "modpath: $modpath => $new_modpath"

                        write(io, Int32(sizeof(new_modpath)))
                        write(io, new_modpath)
                        mutated = true
                    else
                        write(io, n1)
                        write(io, modpath)
                    end
                end
            end
        end

        # If we've tracked our modications correctly the positions will be off by exactly
        # the offset.
        @assert position(f) + offset == position(io)

        # Copy unchanged content up to the `srctextpos`
        write(io, read(f, srctextpos - position(f)))

        # Update `totbytes` in place
        @debug "totbytes: $totbytes => $(totbytes + offset)"
        seek(io, totbytes_pos) # Position is the same in both `f` and `io`
        write(io, UInt64(totbytes + offset))
        seekend(io)
        @assert position(f) + offset == position(io)

        if srctextpos != 0
            # Update `srctextpos` in place
            @debug "srctextpos: $srctextpos => $(srctextpos + offset)"
            seek(io, srctextpos_pos + offset)
            write(io, Int64(srctextpos + offset))
            seekend(io)
            @assert position(f) + offset == position(io)

            while !eof(f)
                filenamelen = read(f, Int32)
                if filenamelen == 0
                    write(io, filenamelen)
                    break
                end
                filename = String(read(f, filenamelen))

                if startswith(filename, old)
                    new_filename = replace(filename, old => new; count=1)

                    @debug "srctext file: $filename => $new_filename"

                    write(io, Int32(length(new_filename)))
                    write(io, new_filename)
                    mutated = true
                else
                    write(io, filenamelen)
                    write(io, filename)
                end

                # Copy unchanged file content
                len = read(f, UInt64)
                write(io, len)
                write(io, read(f, len))
            end
        end

       # Copy remainder of the file content
        write(io, read(f))
    end

    # Update the file checksum. Adapted from `isvalid_file_crc`:
    # https://github.com/JuliaLang/julia/blob/760b2e5b7396f9cc0da5efce0cadd5d1974c4069/base/loading.jl#L3188
    checksum = Base._crc32c(seekstart(io), filesize(io) - 4)
    write(io, UInt32(checksum))

    if mutated
        seekstart(io)
        open(cachefile, "w") do f
            write(f, read(io))
        end
    end
end

# Precompile the depot packages using the "compiled" directory from Docker cache mount
# allowing us to perform precompilation for Julia packages once across all Docker builds on
# a system.
cache_depot = ARGS[1]
final_depot = length(ARGS) >= 2 ? ARGS[2] : DEPOT_PATH[1]

env = Pkg.Operations.EnvCache()

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

precompile_pkgs = filter!(!in_sysimage, [PkgId(uuid, dep.name)
                                         for (uuid, dep) in Pkg.dependencies(env)])

# When a root package is defined but can not be loaded we need to exclude it from the
# packages which are precompiled.
root = root_package(env)
if !isnothing(root.pkg)
    if root.loadable
        push!(precompile_pkgs, root.pkg)
    else
        @warn "Package $(root.pkg.name) is incomplete. Excluding it from precompilation"
    end
end

# Precompile files for dependencies tracked with a local path (via `Pkg.develop`) include this path
# internally and moving the source files will invalidate the precompilation files. Using
# `JULIA_DEBUG=loading` reveals messages such as: `Debug: Rejecting cache file *.ji
# because it is for file /project-abc/x.jl not file  /project/x.jl`. This is problematic
# for us
path_tracked_pkgs = [PkgId(uuid, dep.name) for (uuid, dep) in Pkg.dependencies(env)
                     if dep.is_tracking_path]

# Skip precompilation when the package list is empty. Typically, this would make
# `Pkg.precompile` compile everything. Unfortunately, `Pkg.precompile` on newer versions of
# Julia (1.11.0+) display the full list of packages to precompile which adds noise to the
# output.
if !isempty(precompile_pkgs)
    project_dir = dirname(Base.active_project())

    # Modify the Julia project to ensure precompile file slugs are unique for each Docker
    # image.
    set_distinct_active_project() do
        Pkg.precompile([PackageSpec(; p.uuid, p.name) for p in precompile_pkgs]; strict=true, timing=true)

        # Precompilation files for dependencies tracked with a local path
        # (via `Pkg.develop`) are invalidated when the tracked source location is changed.
        tmp_project_dir = dirname(Base.active_project())
        for pkg in path_tracked_pkgs
            path = compilecache_path(pkg)
            !isnothing(path) || continue

            rewrite(path, tmp_project_dir => project_dir)
        end
    end
end

cache_paths = filter!(within_depot, compilecache_paths(env))

# Report the `.ji` files which will be transferred from the cache depot to the final depot.
#
# TODO: We could improve the accuracy of this message by utilizing checksums when
# determining if a cache file is new.
@debug begin
    paths = map(cache_paths) do p
        string(p, !(p in old_cache_paths) ? " (new)" : "")
    end
    num_new = length(setdiff(cache_paths, old_cache_paths))
    total = length(cache_paths)
    "Precompile files to transfer (new additions $num_new/$total):\n$(join(paths, '\n'))"
end

# # Listing all cached precompile files can be useful in debugging unexpected failures but
# # it can be extremely verbose.
# @debug let paths = String[]
#     for (root, dirs, files) in walkdir(joinpath(DEPOT_PATH[1], "compiled", "v$(VERSION.major).$(VERSION.minor)"))
#         for file in files
#             if endswith(file, ".ji")
#                 push!(paths, joinpath(root, file))
#             end
#         end
#     end
#     "All precompile files within the cache mount:\n$(join(paths, '\n'))"
# end

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
