using JSON3: JSON3
using Random: randstring

function get_cached_files(depot_cache_id; debug::Bool=false)
    image = "read-cache:$(randstring())"
    dockerfile = joinpath(@__DIR__, "read-cache.Dockerfile")
    context = @__DIR__
    build_cmd = ```
        docker build --progress=plain -f $dockerfile -t $image
        --build-arg=JULIA_DEPOT_CACHE_ID=$(depot_cache_id)
        --build-arg=INVALIDATE_READ_CACHE=$(randstring())
        $context
        ```
    cleanup_cmd = `docker rmi $image`

    if !debug
        build_cmd = pipeline(build_cmd; stdout=devnull, stderr=devnull)
        cleanup_cmd = pipeline(cleanup_cmd; stdout=devnull, stderr=devnull)
    end

    run(build_cmd)
    files = readlines(`docker run --rm $image`)
    run(cleanup_cmd)

    return files
end

function get_cached_ji_files(args...; kwargs...)
    return filter!(endswith(".ji"), get_cached_files(args...; kwargs...))
end

function build(context::AbstractString, build_args::AbstractVector{Pair{String,String}}=[]; debug::Bool=false)
    # Docker doesn't support the use of symbolic links for copying files outside the
    # context so we'll setup up temporary hardlinks
    hardlink_files = [
        joinpath(@__DIR__, "..", "pkg-precompile.jl"),
    ]
    for src in hardlink_files
        dst = joinpath(context, basename(src))
        run(`ln $src $dst`)
    end

    dockerfile = joinpath(@__DIR__, "Dockerfile")
    build_cmd = ```
        docker build --progress=plain -f $dockerfile
        --build-arg=INVALIDATE_PRECOMPILE=$(randstring())
        $(["--build-arg=$k=$v" for (k, v) in build_args])
        $context
        ```

    if debug
        println(build_cmd)
    else
        build_cmd = pipeline(build_cmd; stdout=devnull, stderr=devnull)
    end

    try
        run(build_cmd)
    finally
        for src in hardlink_files
            rm(joinpath(context, basename(src)))
        end
    end
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
