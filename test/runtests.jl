using Base: PkgId, is_stdlib
using Test
using UUIDs: UUID

include("utils.jl")

@testset "Docker Package Precompile" begin
#=
    # Standard libraries which aren't included in the sysimage usually contain
    # precompilation which are shipped with Julia.
    @testset "stdlib with bundled precompile" begin
        with_cache_mount(; id_prefix="julia-depot-stdlib-bundled-precompile-") do depot_cache_id
            @test length(get_cached_ji_files(depot_cache_id)) == 0

            build_args = ["JULIA_DEPOT_CACHE_ID" => depot_cache_id]

            # Unicode is a stdlib which does not typically create a `.ji` file.
            image = build(joinpath(@__DIR__, "stdlib-bundled-precompile"), build_args)
            ji_files = get_cached_ji_files(depot_cache_id)
            @test length(ji_files) == 0

            metadata = pkg_details(image, Base.identify_package("Unicode"))
            @test metadata.is_stdlib
            @test !metadata.in_sysimage
            @test metadata.is_precompiled
            @test startswith(metadata.ji_path, "/usr/local/julia/share/julia/compiled")
        end
    end

    @testset "stdlib user precompile" begin
        with_cache_mount(; id_prefix="julia-depot-stdlib-user-precompile-") do depot_cache_id
            @test length(get_cached_ji_files(depot_cache_id)) == 0

            build_args = ["JULIA_DEPOT_CACHE_ID" => depot_cache_id]

            # SuiteSparse is a stdlib that also creates a `.ji` file.
            image = build(joinpath(@__DIR__, "stdlib-user-precompile"), build_args)
            ji_files = get_cached_ji_files(depot_cache_id)
            @test length(ji_files) == 1
            @test "SuiteSparse" in basename.(dirname.(ji_files))

            metadata = pkg_details(image, Base.identify_package("SuiteSparse"))
            @test metadata.is_stdlib
            @test !metadata.in_sysimage
            @test metadata.is_precompiled
            @test startswith(metadata.ji_path, "/usr/local/share/julia-depot/compiled")
        end
    end

    # Verifying that direct dependencies have been precompiled requires us to special case
    # packages in the sysimage as these packages will return:
    # `Base.isprecompiled(...) == false`.
    @testset "stdlib in sysimage" begin
        with_cache_mount(; id_prefix="julia-depot-stdlib-in-sysimage-") do depot_cache_id
            @test length(get_cached_ji_files(depot_cache_id)) == 0

            build_args = ["JULIA_DEPOT_CACHE_ID" => depot_cache_id]

            # SHA is usually built into the Julia system image
            image = build(joinpath(@__DIR__, "stdlib-in-sysimage"), build_args)
            ji_files = get_cached_ji_files(depot_cache_id)
            @test length(ji_files) == 0

            metadata = pkg_details(image, Base.identify_package("SHA"))
            @test metadata.is_stdlib
            @test metadata.in_sysimage
            @test !metadata.is_precompiled
            @test metadata.ji_path === nothing
        end
    end

    # Details from `Pkg.dependencies` do not include extensions.
    @testset "extension" begin
        with_cache_mount(; id_prefix="julia-depot-extension-") do depot_cache_id
            @test length(get_cached_ji_files(depot_cache_id)) == 0

            build_args = ["JULIA_DEPOT_CACHE_ID" => depot_cache_id]

            # Build an image which installs Compat/LinearAlgebra and the extension
            # CompatLinearAlgebraExt.
            image = build(joinpath(@__DIR__, "extension"), build_args)
            ji_files = get_cached_ji_files(depot_cache_id)
            @test length(ji_files) > 0
            @test "CompatLinearAlgebraExt" in basename.(dirname.(ji_files))

            pkg = PkgId(UUID("dbe5ba0b-aecc-598a-a867-79051b540f49"), "CompatLinearAlgebraExt")
            metadata = pkg_details(image, pkg)
            @test !metadata.is_stdlib
            @test !metadata.in_sysimage
            @test metadata.is_precompiled
            @test startswith(metadata.ji_path, "/usr/local/share/julia-depot/compiled")
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
    @testset "different package version, same project path" begin
        with_cache_mount(; id_prefix="julia-different-pkg-") do depot_cache_id
            @test length(get_cached_ji_files(depot_cache_id)) == 0

            julia_project = "/julia-project"
            build_args = ["JULIA_PROJECT" => julia_project,
                          "JULIA_DEPOT_CACHE_ID" => depot_cache_id]

            # Build an image which installs MultilineStrings@0.1.1 and writes the compile
            # cache file into the cache mount.
            build(joinpath(@__DIR__, "pkg-v0"), build_args)
            ji_files = get_cached_ji_files(depot_cache_id)
            @test length(ji_files) == 1

            # Build another image which installs MultilineStrings@1.0.0 and writes the
            # compile cache file into the cache mount.
            build(joinpath(@__DIR__, "pkg-v1"), build_args)
            @test length(get_cached_ji_files(depot_cache_id)) == 2

            # Ensure the generated compile cache path is deterministic. We test this by
            # creating a new cache mount and checking the name of the produced compile cache
            # path.
            with_cache_mount(; id_prefix="julia-different-pkg-alt-") do alt_depot_cache_id
                build_args = ["JULIA_PROJECT" => julia_project,
                              "JULIA_DEPOT_CACHE_ID" => alt_depot_cache_id]

                build(joinpath(@__DIR__, "pkg-v0"), build_args)
                alt_ji_files = get_cached_ji_files(alt_depot_cache_id)
                @test length(alt_ji_files) == 1
                @test alt_ji_files == ji_files
            end
        end
    end

    # Julia will search for existing precompilation files which can be used even if the
    # names differ. We rely on this functionality as without it the strategy used in
    # `set_distinct_active_project` wouldn't work if names needed to match.
    @testset "same package version, different project path" begin
        with_cache_mount(; id_prefix="julia-same-pkg-") do depot_cache_id
            @test length(get_cached_ji_files(depot_cache_id)) == 0

            julia_project_a = "/julia-project-a"
            julia_project_b = "/julia-project-b"

            # Build the image which will create the precomplation file based upon the
            # provided Julia project path "A".
            build_args = ["JULIA_PROJECT" => julia_project_a,
                          "JULIA_DEPOT_CACHE_ID" => depot_cache_id]
            build(joinpath(@__DIR__, "pkg-v1"), build_args)
            ji_files_a1 = get_cached_ji_files(depot_cache_id)
            @test length(ji_files_a1) == 1

            # Build an image with Julia project path "B". Julia will noticed the existing
            # precompilation file from "A" and use that instead of creating a new one.
            build_args = ["JULIA_PROJECT" => julia_project_b,
                          "JULIA_DEPOT_CACHE_ID" => depot_cache_id]
            build(joinpath(@__DIR__, "pkg-v1"), build_args)
            ji_files_b1 = get_cached_ji_files(depot_cache_id)
            @test length(ji_files_b1) == 1
            @test ji_files_a1 == ji_files_b1

            with_cache_mount(; id_prefix="julia-same-pkg-alt-") do alt_depot_cache_id
                # Build another the image which will create a new  precomplation file based
                # upon the provided Julia project path "B". The name of the  precompilation
                # file will differ from the one created with Julia project path "A".
                build_args = ["JULIA_PROJECT" => julia_project_b,
                              "JULIA_DEPOT_CACHE_ID" => alt_depot_cache_id]
                build(joinpath(@__DIR__, "pkg-v1"), build_args)
                ji_files_b2 = get_cached_ji_files(alt_depot_cache_id)
                @test length(ji_files_b2) == 1
                @test ji_files_b2 != ji_files_b1

                # Build an image with the Julia project path "A". Julia will noticed the
                # existing precompilation file from "B" and use that instead of creating a
                # new one.
                build_args = ["JULIA_PROJECT" => julia_project_a,
                              "JULIA_DEPOT_CACHE_ID" => alt_depot_cache_id]
                build(joinpath(@__DIR__, "pkg-v1"), build_args)
                ji_files_a2 = get_cached_ji_files(alt_depot_cache_id)
                @test length(ji_files_a2) == 1
                @test ji_files_a2 != ji_files_a1
                @test ji_files_a2 == ji_files_b2
            end
        end
    end

    # Ensure we load the Julia packages to trigger the first initialization of the package.
    # Executing the package's `__init__` functions can important for packages which call
    # `@get_scratch!` which will attept to create a directory under
    # `$(DEPOT_PATH[1])/scratchspaces` which may not be writable when running as a different
    # user than the one which installed the Julia depot.
    #
    # Originally, this issue was discovered when loading Makie.jl but I have ended up using
    # ODBC.jl here as the later package has far fewer dependencies.
    #
    # - https://github.com/MakieOrg/Makie.jl/blob/b0635c4855dd5013caebbd2ec3ea7e92b3f5f118/src/Makie.jl#L386
    # - https://github.com/JuliaDatabases/ODBC.jl/blob/0229edb6c8e6120884878a432fa86951d07ed26a/src/API.jl#L192
    @testset "triggers initialization" begin
        with_cache_mount(; id_prefix="julia-initialize-") do depot_cache_id
            # Failures look similar to:
            # ```
            # ERROR: InitError: IOError: mkdir("/usr/local/share/julia-depot/scratchspaces/be6f12e9-ca4f-5eb2-a339-a4f995cc0291"; mode=0o777): permission denied (EACCES)
            # ```
            build_args = ["JULIA_DEPOT_CACHE_ID" => depot_cache_id]
            image = build(joinpath(@__DIR__, "initialize"), build_args; target="user")

            depot = "/usr/local/share/julia-depot"
            scratchspace = "$depot/scratchspaces/be6f12e9-ca4f-5eb2-a339-a4f995cc0291"
            shell_script = "id -u; [ -r $depot ]; echo \$?; [ -w $depot ]; echo \$?; [ -d $scratchspace ]; echo \$?"
            lines = readlines(`docker run --rm --entrypoint /bin/bash $image -c $shell_script`)
            uid = parse(Int, lines[1])
            depot_read = lines[2] == "0"
            depot_write = lines[3] == "0"
            scratchspace_exists = lines[4] == "0"

            @test uid != 0  # Not running as root
            @test depot_read
            @test !depot_write
            @test scratchspace_exists

            # Ensure the user can successfully load all Julia direct dependencies. Failures
            # here are due to the package's `__init__` function attempting to write content
            # into the Julia depot.
            #
            # Purposefully avoiding using `Pkg.dependencies` as that function attempts to
            # create a `$(JULIA_DEPOT[1])/logs/manifest_usage.toml.pid` which fails as the
            # user doesn't have write access to the Julia depot.
            load_script = quote
                using TOML
                for direct_dep_name in keys(TOML.parsefile(Base.active_project())["deps"])
                    Base.require(Main, Symbol(direct_dep_name))
                end
            end

            # Avoid using `success` here as that call suppresses stdout/stderr from the process
            p = run(ignorestatus(`docker run --rm $image -e $load_script`))
            @test p.exitcode == 0
        end
    end
=#
    @testset "relocate depot" begin
        with_cache_mount(; id_prefix="julia-relocate-") do depot_cache_id
            build_args = ["JULIA_VERSION" => string(VERSION),
                          "JULIA_DEPOT_CACHE_ID" => depot_cache_id]
            image = build(joinpath(@__DIR__, "pkg-v1"), build_args; target="relocate-depot", debug=true)

            # Precompilation files should not be invalidated after relocating the Julia
            # depot (at least on Julia 1.11+)
            precompiled_script = quote
                using Pkg
                for (uuid, dep) in pairs(Pkg.dependencies())
                    pkg = Base.PkgId(uuid, dep.name)
                    @assert Base.isprecompiled(pkg) "Package $(pkg.name) not precompiled"
                end
            end

            # Avoid using `success` here as that call suppresses stdout/stderr from the process
            p = run(ignorestatus(`docker run --rm $image -e $precompiled_script`))
            @test p.exitcode == 0
        end
    end
end
