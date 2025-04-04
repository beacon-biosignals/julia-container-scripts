using JSON3: JSON3
using Logging: Logging
using Random: randstring


function docker_debug()
    return Logging.min_enabled_level(Logging.global_logger()) == Logging.Debug
end

function get_cached_files(depot_cache_id; debug::Bool=false)
    dockerfile = joinpath(@__DIR__, "read-cache.Dockerfile")
    context = @__DIR__
    build_cmd = ```
        docker build -f $dockerfile
        --build-arg=JULIA_DEPOT_CACHE_ID=$(depot_cache_id)
        --build-arg=INVALIDATE_READ_CACHE=$(randstring())
        $context
        ```

    if debug
        cmd = `$build_cmd --progress=plain`
        println(cmd)
        run(cmd)
    end

    digest = readchomp(`$build_cmd --quiet`)
    files = readlines(`docker run --rm $digest`)
    run(pipeline(`docker rmi $digest`; stdout=devnull))

    return files
end

function get_cached_ji_files(args...; kwargs...)
    return filter!(endswith(".ji"), get_cached_files(args...; kwargs...))
end

function build(context::AbstractString, build_args::AbstractVector{Pair{String,String}}=[];
               target::Union{AbstractString,Nothing}=nothing,
               debug::Bool=true)
    # Docker doesn't support the use of symbolic links for copying files outside the
    # context so we'll setup up temporary hardlinks
    hardlink_files = [
        joinpath(@__DIR__, "..", "pkg-precompile.jl"),
    ]
    for src in hardlink_files
        dst = joinpath(context, basename(src))
        run(`ln -f $src $dst`)
    end

    flags = String[]
    !isnothing(target) && push!(flags, "--target=$target")


    dockerfile = joinpath(@__DIR__, "Dockerfile")
    build_cmd = ```
        docker build -f $dockerfile
        $flags
        --build-arg=INVALIDATE_PRECOMPILE=$(randstring())
        $(["--build-arg=$k=$v" for (k, v) in build_args])
        $context
        ```

    digest = try
        if debug
            println(build_cmd)
            run(`$build_cmd --progress=plain`)
        end

        readchomp(`$build_cmd --quiet`)
    finally
        for src in hardlink_files
            rm(joinpath(context, basename(src)))
        end
    end

    @debug "Built image with digest: $digest"
    return digest
end

# Delete Docker build cache entrie based upon the user specified cache mount ID. Equivalent
# to the following CLI command:
# docker builder prune --filter id="$(docker system df -v --format json | jq -r --arg id "$cache_mount_id" '.BuildCache[] | select(.CacheType == "exec.cachemount" and (.Description | endswith("with id \"/" + $id + "\""))).ID')"
function delete_cache_mount(cache_mount_id)
    json = JSON3.read(`docker system df --verbose --format json`)
    build_caches = filter(json.BuildCache) do bc
        bc.CacheType == "exec.cachemount" && endswith(bc.Description, "with id \"/$cache_mount_id\"")
    end

    # When using `sharing=private` concurrent access to the same "cache mount ID" results in
    # multiple caches being created using the same "cache mount ID". The build cache ID
    # appears to be randomly generated.
    for bc in build_caches
        run(pipeline(`docker builder prune --force --filter id=$(bc.ID)`; stdout=devnull))
    end

    return nothing
end

function with_cache_mount(body; id_prefix="julia-container-scripts-")
    cache_mount_id = "$(id_prefix)$(randstring())"
    try
        body(cache_mount_id)
    finally
        delete_cache_mount(cache_mount_id)
    end
end

function pkg_details(image::AbstractString, pkg::Base.PkgId)
    script = quote
        using Base: PkgId
        using Pkg: Pkg
        using UUIDs: UUID
        pkg = $pkg
        println(Pkg.Types.is_stdlib(pkg.uuid))
        println(Base.in_sysimage(pkg))
        println(Base.isprecompiled(pkg))
        println(Base.compilecache_path(pkg))
    end

    lines = readlines(`docker run --rm $image -e $script`)
    is_stdlib = parse(Bool, lines[1])
    in_sysimage = parse(Bool, lines[2])
    is_precompiled = parse(Bool, lines[3])
    ji_path = lines[4] == "nothing" ? nothing : lines[4]

    return (; is_stdlib, in_sysimage, is_precompiled, ji_path)
end
