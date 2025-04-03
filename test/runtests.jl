using Test

include("utils.jl")

@testset "Docker Package Precompile" begin
    @testset "stdlib without precompile" begin
        with_cache_mount(; id_prefix="julia-depot-stdlib-without-precompile-") do depot_cache_id
            @test length(get_cached_ji_files(depot_cache_id)) == 0

            build_args = ["JULIA_DEPOT_CACHE_ID" => depot_cache_id]

            # Unicode is a stdlib which does not create a `.ji` file.
            build(joinpath(@__DIR__, "stdlib-without-precompile"), build_args)
            ji_files = get_cached_ji_files(depot_cache_id)
            @test length(ji_files) == 0
        end
    end

    @testset "stdlib with precompile" begin
        with_cache_mount(; id_prefix="julia-depot-stdlib-with-precompile-") do depot_cache_id
            @test length(get_cached_ji_files(depot_cache_id)) == 0

            build_args = ["JULIA_DEPOT_CACHE_ID" => depot_cache_id]

            # SuiteSparse is a stdlib that also creates a `.ji` file.
            build(joinpath(@__DIR__, "stdlib-with-precompile"), build_args)
            ji_files = get_cached_ji_files(depot_cache_id)
            @test length(ji_files) == 1
            @test basename(dirname(ji_files[1])) == "SuiteSparse"
        end
    end

    @testset "extension" begin
        with_cache_mount(; id_prefix="julia-depot-extension-") do depot_cache_id
            @test length(get_cached_ji_files(depot_cache_id)) == 0

            build_args = ["JULIA_DEPOT_CACHE_ID" => depot_cache_id]

            # Build an image which installs Compat/LinearAlgebra and the extension
            # CompatLinearAlgebraExt.
            build(joinpath(@__DIR__, "extension"), build_args; debug=true)
            ji_files = get_cached_ji_files(depot_cache_id)
            @test length(ji_files) > 0

            @show ji_files
        end
    end

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
            build(joinpath(@__DIR__, "a"), build_args)
            ji_files = get_cached_ji_files(depot_cache_id)
            @test length(ji_files) == 1

            # Build another image which installs MultilineStrings@1.0.0 and writes the
            # compile cache file into the cache mount.
            build(joinpath(@__DIR__, "b"), build_args)
            @test length(get_cached_ji_files(depot_cache_id)) == 2

            # Ensure the generated compile cache path is deterministic. We test this by
            # creating a new cache mount and checking the name of the produced compile cache
            # path.
            with_cache_mount(; id_prefix="julia-depot-test-new-") do new_depot_cache_id
                build_args = ["JULIA_PROJECT" => julia_project,
                              "JULIA_DEPOT_CACHE_ID" => new_depot_cache_id]

                build(joinpath(@__DIR__, "a"), build_args)
                new_ji_files = get_cached_ji_files(new_depot_cache_id)
                @test length(new_ji_files) == 1
                @test new_ji_files == ji_files
            end
        end
    end
end
