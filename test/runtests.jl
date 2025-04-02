using Test

include("utils.jl")

@testset "Docker Package Precompile" begin
    # Out-of-the-box on Julia 1.11 the compile cache path used for a package is based upon the:
    #
    # - Package UUID
    # - Active project path
    # - System image path (`--sysimage`)
    # - Julia binary path
    # - Cache flags (`--pkgimages`, `--debug-info`, `--check-bounds`, `--inline`, `--optimize`)
    # - CPU target (`--cpu-target` / `JULIA_CPU_TARGET`)
    #
    # The use of the active project path is problematic in Docker environments as two
    # distinct projects may use the same project path. When that occurs Julia could use the
    # same compile cache path resulting in cache files being unncesssarily clobbered and
    # also causing build failures when using `sharing=shared`.
    @testset "different package version, same depot path" begin
        with_cache_mount(; id_prefix="julia-depot-test-") do depot_cache_id
            @test length(get_cached_ji_files(depot_cache_id)) == 0

            julia_project = "/julia-project"
            build_args = ["JULIA_PROJECT" => julia_project,
                          "JULIA_DEPOT_CACHE_ID" => depot_cache_id]

            # Build an image which installs MultilineStrings@0.1.1 and writes the compile
            # cache file into the cache mount.
            build(joinpath(@__DIR__, "a"), build_args; debug=true)
            ji_files = get_cached_ji_files(depot_cache_id)
            @test length(ji_files) == 1

            # Build another image which installs MultilineStrings@1.0.0 and writes the
            # compile cache file into the cache mount.
            build(joinpath(@__DIR__, "b"), build_args; debug=true)
            @test length(get_cached_ji_files(depot_cache_id)) == 2

            # The generated compile cache path is deterministic. We test this by creating a
            # separate cache mount.
            with_cache_mount(; id_prefix="julia-depot-test-new-") do new_depot_cache_id
                build_args = ["JULIA_PROJECT" => julia_project,
                              "JULIA_DEPOT_CACHE_ID" => new_depot_cache_id]

                build(joinpath(@__DIR__, "a"), build_args; debug=true)
                new_ji_files = get_cached_ji_files(new_depot_cache_id)
                @test length(new_ji_files) == 1
                @test new_ji_files == ji_files
            end
        end
    end
end
