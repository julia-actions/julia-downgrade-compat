using Test
using TOML
using Pkg

downgrade_jl = joinpath(dirname(@__DIR__), "downgrade.jl")

function expected_project_hash(project_file::String)
    env = Pkg.Types.EnvCache(project_file)
    if isdefined(Pkg.Types, :workspace_resolve_hash)
        return string(Pkg.Types.workspace_resolve_hash(env))
    elseif isdefined(Pkg.Types, :project_resolve_hash)
        return string(Pkg.Types.project_resolve_hash(env.project))
    else
        error("Could not compute expected project hash for tests")
    end
end

@testset "julia-downgrade-compat resolver tests" begin
    @testset "simple resolver test" begin
        mktempdir() do dir
            cd(dir) do
                # Create a Project.toml with known packages that have multiple versions
                toml_content = """
                name = "TestPackage"
                version = "0.1.0"

                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                [compat]
                julia = "1.10"
                JSON = "0.20, 0.21"
                DataStructures = "0.17, 0.18"
                """
                write("Project.toml", toml_content)

                # Run the downgrade script
                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10"`)

                # Verify Manifest.toml was created
                @test isfile("Manifest.toml")

                # Parse the manifest to check versions
                manifest = TOML.parsefile("Manifest.toml")

                # Find JSON and DataStructures entries
                deps = manifest["deps"]
                deps_JSON = get(deps, "JSON", [])
                deps_DataStructures = get(deps, "DataStructures", [])

                @test !isempty(deps_JSON)
                @test !isempty(deps_DataStructures)

                # Verify we got minimal versions (0.20.x for JSON, 0.17.x for DataStructures)
                @test startswith(deps_JSON[1]["version"], "0.20")
                @test startswith(deps_DataStructures[1]["version"], "0.17")
            end
        end
    end

    # The resolver only accepts numeric compat specs, so setup-julia channel
    # aliases must be converted to the numeric version they actually denote
    # (lts/release/pre from the official version databases, min from the
    # project's julia compat lower bound, nightly from the runtime).
    @testset "channel alias julia_version specs" begin
        current_minor = string(VERSION.major, ".", VERSION.minor)

        # Run the script with the given spec in a fresh project; return the
        # numeric version the alias was converted to, whether the full
        # resolution succeeded, and the parsed manifest (or nothing).
        function run_with_spec(spec)
            mktempdir() do dir
                cd(dir) do
                    write(
                        "Project.toml",
                        """
                        name = "TestPackage"
                        version = "0.1.0"

                        [deps]
                        JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                        [compat]
                        julia = "1.10"
                        JSON = "0.20, 0.21"
                        """,
                    )
                    err = IOBuffer()
                    proc = run(pipeline(
                            `$(Base.julia_cmd()) $downgrade_jl "" "." "deps" $spec`;
                            stderr = err,
                        ); wait = false)
                    wait(proc)
                    log = String(take!(err))
                    m = match(r"Converted julia_version \"[^\"]+\" to \"(\d+\.\d+)\"", log)
                    converted = m === nothing ? nothing : String(m.captures[1])
                    manifest = isfile("Manifest.toml") ? TOML.parsefile("Manifest.toml") :
                        nothing
                    success(proc) || println("[$spec] script failed; log:\n", log)
                    return converted, success(proc), manifest
                end
            end
        end

        # Deterministic aliases: target <= runtime, so resolution must succeed
        min_v, min_ok, min_manifest = run_with_spec("min")
        @test min_v == "1.10"  # the project's julia compat lower bound
        @test min_ok
        @test startswith(min_manifest["deps"]["JSON"][1]["version"], "0.20")

        nightly_v, nightly_ok, _ = run_with_spec("nightly")
        @test nightly_v == current_minor
        @test nightly_ok

        versioned_nightly_v, versioned_nightly_ok, _ = run_with_spec("$(current_minor)-nightly")
        @test versioned_nightly_v == current_minor
        @test versioned_nightly_ok

        # Database-resolved aliases: exact values change over time, so check
        # they are numeric and correctly ordered (lts <= release <= pre). The
        # lts target is never newer than a supported runtime, so its full
        # resolution must succeed; release/pre may target a Julia newer than
        # the runtime, where the resolver legitimately lacks stdlib data
        # (cross-runtime mode), so only the conversion is asserted for them.
        lts_v, lts_ok, lts_manifest = run_with_spec("lts")
        release_v, _, _ = run_with_spec("release")
        pre_v, _, _ = run_with_spec("pre")
        @test lts_v !== nothing && release_v !== nothing && pre_v !== nothing
        @test VersionNumber(lts_v) >= v"1.6"
        @test VersionNumber(lts_v) <= VersionNumber(release_v)
        @test VersionNumber(release_v) <= VersionNumber(pre_v)
        @test lts_ok
        @test startswith(lts_manifest["deps"]["JSON"][1]["version"], "0.20")

        # Unknown aliases fail with a clear error instead of reaching the resolver
        @testset "unknown alias rejected" begin
            mktempdir() do dir
                cd(dir) do
                    write(
                        "Project.toml",
                        """
                        name = "TestPackage"
                        version = "0.1.0"
                        """,
                    )
                    err = IOBuffer()
                    proc = run(pipeline(
                            `$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "notachannel"`;
                            stderr = err,
                        ); wait = false)
                    wait(proc)
                    @test !success(proc)
                    @test occursin("Unsupported julia_version channel alias", String(take!(err)))
                end
            end
        end
    end

    @testset "forcedeps mode - passes when lower bounds match" begin
        mktempdir() do dir
            cd(dir) do
                # Create a Project.toml with known packages that should resolve to their lower bounds
                # JSON 0.21.0 is a specific version that exists and should be resolvable
                toml_content = """
                name = "TestPackage"
                version = "0.1.0"

                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                [compat]
                julia = "1.10"
                JSON = "0.21"
                """
                write("Project.toml", toml_content)

                # Run the downgrade script with forcedeps mode
                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "forcedeps" "1.10"`)

                # Verify Manifest.toml was created
                @test isfile("Manifest.toml")

                # Parse the manifest to verify the version
                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]
                deps_JSON = get(deps, "JSON", [])

                @test !isempty(deps_JSON)
                # Should be exactly 0.21.0 (the lower bound)
                @test deps_JSON[1]["version"] == "0.21.0"
            end
        end
    end

    @testset "forcedeps mode - fails when lower bounds are incompatible" begin
        mktempdir() do dir
            cd(dir) do
                # JuMP 1.0.0 requires MathOptInterface >= 1.1.1, so even though we
                # specify MathOptInterface = "1.0", the resolver will pick 1.1.1.
                # The forcedeps check should then fail because 1.1.1 != 1.0.0
                toml_content = """
                name = "TestPackage"
                version = "0.1.0"

                [deps]
                JuMP = "4076af6c-e467-56ae-b986-b466b2749572"
                MathOptInterface = "b8f27783-ece8-5eb3-8dc8-9495eed66fee"

                [compat]
                julia = "1.10"
                JuMP = "1.0"
                MathOptInterface = "1.0"
                """
                write("Project.toml", toml_content)

                # Run the downgrade script with forcedeps mode - should fail
                @test_throws ProcessFailedException run(
                    `$(Base.julia_cmd()) $downgrade_jl "" "." "forcedeps"`,
                )
            end
        end
    end

    @testset "forcedeps mode - skip" begin
        mktempdir() do dir
            cd(dir) do
                # Create a Project.toml with known packages that should resolve to their lower bounds
                # JSON 0.21.0 is a specific version that exists and should be resolvable
                # LinearAlgebra is a standard library. So the compat bound should be "1", but we do not want to resolve LinearAlgebra to 1.0.0. Therefore we skip it.
                toml_content = """
                name = "TestPackage"
                version = "0.1.0"

                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

                [compat]
                julia = "1.10"
                JSON = "0.21"
                LinearAlgebra = "1"
                """
                write("Project.toml", toml_content)

                # Run the downgrade script with forcedeps mode
                run(`$(Base.julia_cmd()) $downgrade_jl "LinearAlgebra" "." "forcedeps" "1.10"`)

                # Verify Manifest.toml was created
                @test isfile("Manifest.toml")

                # Parse the manifest to verify the version
                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]
                deps_JSON = get(deps, "JSON", [])

                @test !isempty(deps_JSON)
                # Should be exactly 0.21.0 (the lower bound)
                @test deps_JSON[1]["version"] == "0.21.0"
            end
        end
    end

    @testset "forcedeps mode - ignores build metadata" begin
        mktempdir() do dir
            cd(dir) do
                # JLL packages commonly resolve with build metadata (e.g., +0)
                # while compat lower bounds typically omit it.
                toml_content = """
                name = "TestPackage"
                version = "0.1.0"

                [deps]
                OpenSSL_jll = "458c3c95-2e84-50aa-8efc-19380b2a3a95"

                [compat]
                julia = "1.10"
                OpenSSL_jll = "3.5.0"
                """
                write("Project.toml", toml_content)

                # Should pass even when resolved version is like 3.5.0+0
                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "forcedeps" "1.10"`)

                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]
                deps_OpenSSL_jll = get(deps, "OpenSSL_jll", [])

                @test !isempty(deps_OpenSSL_jll)
                @test startswith(deps_OpenSSL_jll[1]["version"], "3.5.0")
                @test occursin("+", deps_OpenSSL_jll[1]["version"])
            end
        end
    end

    @testset "invalid cases" begin
        # Test invalid mode
        mktempdir() do dir
            cd(dir) do
                write("Project.toml", "name = \"Test\"")
                @test_throws ProcessFailedException run(
                    `$(Base.julia_cmd()) $downgrade_jl "" "." "invalid_mode" "1.10"`,
                )
            end
        end

        # Test missing Project.toml
        mktempdir() do dir
            cd(dir) do
                @test_throws ProcessFailedException run(
                    `$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10"`,
                )
            end
        end
    end

    @testset "test/Project.toml with local sources" begin
        mktempdir() do dir
            cd(dir) do
                # Create main Project.toml
                main_toml = """
                name = "TestPackage"
                uuid = "598b003f-0677-49cf-8d2a-39b1658b755a"
                version = "0.1.0"

                [workspace]
                projects = ["test"]
                """
                write("Project.toml", main_toml)

                # Create src directory and module
                mkdir("src")
                write("src/TestPackage.jl", "module TestPackage\nend\n")

                # Create test/Project.toml with local source reference
                mkdir("test")
                test_toml = """
                [deps]
                TestPackage = "598b003f-0677-49cf-8d2a-39b1658b755a"
                Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

                [sources.TestPackage]
                path = ".."
                """
                write("test/Project.toml", test_toml)
                write("test/runtests.jl", "using TestPackage, Test\n@testset \"tests\" begin @test true end\n")

                # Run the downgrade script with merged resolution
                run(`$(Base.julia_cmd()) $downgrade_jl "" ".,test" "deps" "1.10"`)

                # Verify Manifest.toml was created
                @test isfile("Manifest.toml")
                @test isfile(joinpath("test", "Manifest.toml"))

                # Parse the manifest
                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]
                test_manifest = TOML.parsefile(joinpath("test", "Manifest.toml"))
                test_deps = test_manifest["deps"]

                # Verify TestPackage is in the manifest as a path dependency
                deps_TestPackage = get(deps, "TestPackage", [])
                @test !isempty(deps_TestPackage)
                @test deps_TestPackage[1]["path"] == "."
                @test deps_TestPackage[1]["uuid"] == "598b003f-0677-49cf-8d2a-39b1658b755a"

                # Verify TestPackage is present in test manifest with test-relative path
                test_deps_TestPackage = get(test_deps, "TestPackage", [])
                @test !isempty(test_deps_TestPackage)
                @test test_deps_TestPackage[1]["path"] == ".."

                # Verify Test stdlib is in the manifest
                deps_Test = get(deps, "Test", [])
                @test !isempty(deps_Test)

                # Verify project hashes match what Pkg expects for each project
                root_hash_expected = expected_project_hash(joinpath(dir, "Project.toml"))
                test_hash_expected = expected_project_hash(joinpath(dir, "test", "Project.toml"))
                @test manifest["project_hash"] == root_hash_expected
                @test test_manifest["project_hash"] == test_hash_expected

                # Verify the test/Project.toml was restored (still has sources section)
                test_project = TOML.parsefile("test/Project.toml")
                @test haskey(test_project, "sources")
                @test haskey(test_project["sources"], "TestPackage")
            end
        end
    end

    @testset "extras and targets.test (old-style test deps)" begin
        mktempdir() do dir
            cd(dir) do
                toml_content = """
                name = "TestPackage"
                uuid = "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d"
                version = "0.1.0"

                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                [extras]
                DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                [targets]
                test = ["DataStructures"]

                [compat]
                JSON = "0.20, 0.21"
                DataStructures = "0.17, 0.18"
                """
                write("Project.toml", toml_content)

                # Run the downgrade script
                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10"`)

                # Verify Manifest.toml was created
                @test isfile("Manifest.toml")

                # Parse the manifest to check versions
                manifest = TOML.parsefile("Manifest.toml")

                # Verify BOTH JSON and DataStructures are in the manifest
                # and resolved to their lower bounds.
                deps = manifest["deps"]
                @test haskey(deps, "JSON")
                @test haskey(deps, "DataStructures")

                @test startswith(deps["JSON"][1]["version"], "0.20")
                @test startswith(deps["DataStructures"][1]["version"], "0.17")
            end
        end
    end

    @testset "old-style test deps keep their floor inside Pkg.test" begin
        write_repro() = begin
            write(
                "Project.toml",
                """
                name = "ReproPkg"
                uuid = "598b003f-0677-49cf-8d2a-39b1658b755a"
                version = "0.1.0"

                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                [extras]
                Aqua = "4c88cf16-eb10-579e-8560-4a9242c79595"
                Bzip2_jll = "6e34b625-4abd-537c-b88f-471c36dfa7a0"
                DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
                Pkg = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
                Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

                [targets]
                test = ["Aqua", "Bzip2_jll", "DataStructures", "Pkg", "Test"]

                [compat]
                julia = "1.10"
                Aqua = "0.8.16"
                Bzip2_jll = "1.0.8"
                JSON = "0.20, 0.21"
                DataStructures = "0.17, 0.18"
                """,
            )
            mkdir("src")
            write("src/ReproPkg.jl", "module ReproPkg\nusing JSON\nend\n")
            mkdir("test")
            write(
                "test/runtests.jl",
                """
                using ReproPkg, Aqua, Bzip2_jll, DataStructures, Pkg, Test
                println("SANDBOX_DATASTRUCTURES=", pkgversion(DataStructures))
                Aqua.test_stale_deps(ReproPkg)
                actual = Dict(info.name => string(info.version) for info in values(Pkg.dependencies()))
                for entry in split(ENV["EXPECTED_FLOORS"], ',')
                    name, version = split(entry, '=')
                    @test actual[name] == version
                end
                """,
            )
        end

        mktempdir() do dir
            cd(dir) do
                write_repro()
                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10"`)
                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10"`)

                project = TOML.parsefile("Project.toml")
                @test startswith(
                    TOML.parsefile("Manifest.toml")["deps"]["DataStructures"][1]["version"],
                    "0.17",
                )
                @test !haskey(project["deps"], "DataStructures")
                @test !haskey(project["deps"], "Bzip2_jll")
                @test !haskey(project["deps"], "Test")
                @test project["compat"]["DataStructures"] == "0.17, 0.18"
                @test project["manifest"] == joinpath(".julia-downgrade-compat", "Manifest.toml")
                @test TOML.parsefile("Manifest.toml")["project_hash"] ==
                    expected_project_hash(joinpath(dir, "Project.toml"))

                manifest_before = read("Manifest.toml", String)
                manifest_deps = TOML.parse(manifest_before)["deps"]
                expected_floors = join(
                    [
                        name * "=" * only(entries)["version"] for (name, entries) in manifest_deps
                            if haskey(only(entries), "git-tree-sha1")
                    ],
                    ',',
                )
                # Pkg wires the sandboxed test process's stdio to stderr, so both
                # streams have to be captured to see what the tests printed.
                captured = IOBuffer()
                run(
                    pipeline(
                        addenv(
                            `$(Base.julia_cmd()) --project=. -e "using Pkg; Pkg.build(); Pkg.test(allow_reresolve=false)"`,
                            "EXPECTED_FLOORS" => expected_floors,
                        );
                        stdout = captured, stderr = captured,
                    ),
                )
                output = String(take!(captured))
                @test occursin("SANDBOX_DATASTRUCTURES=0.17", output)
                @test read("Manifest.toml", String) == manifest_before
            end
        end
    end

    @testset "no_promote test extras are not promoted into [deps]" begin
        # An extra kept out of the joint floor-resolve has no floor in the manifest,
        # so promoting it would declare a dependency the locked manifest cannot
        # satisfy. Manifest membership is what gates the promotion.
        mktempdir() do dir
            cd(dir) do
                write(
                    "Project.toml",
                    """
                    name = "ReproPkg"
                    uuid = "598b003f-0677-49cf-8d2a-39b1658b755a"
                    version = "0.1.0"

                    [deps]
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                    [extras]
                    DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                    [targets]
                    test = ["DataStructures"]

                    [compat]
                    julia = "1.10"
                    JSON = "0.20, 0.21"
                    DataStructures = "0.17, 0.18"
                    """,
                )
                mkdir("src")
                write("src/ReproPkg.jl", "module ReproPkg\nend\n")

                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10" "DataStructures"`)

                project = TOML.parsefile("Project.toml")
                @test !haskey(get(project, "deps", Dict()), "DataStructures")
                @test haskey(project["extras"], "DataStructures")
                @test !haskey(TOML.parsefile("Manifest.toml")["deps"], "DataStructures")
            end
        end
    end

    @testset "locked weakdep test extra retains [weakdeps] and still loads" begin
        mktempdir() do dir
            cd(dir) do
                write(
                    "Project.toml",
                    """
                    name = "ExtPkg"
                    uuid = "0f4b8c11-3f1e-4d2a-9b77-1a2b3c4d5e6f"
                    version = "0.1.0"

                    [deps]
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                    [weakdeps]
                    DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                    [extensions]
                    ExtPkgDSExt = "DataStructures"

                    [extras]
                    DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                    [targets]
                    test = ["DataStructures"]

                    [compat]
                    julia = "1.10"
                    JSON = "0.20, 0.21"
                    DataStructures = "0.17, 0.18"
                    """,
                )
                mkdir("src")
                write("src/ExtPkg.jl", "module ExtPkg\nend\n")
                mkdir("ext")
                write(
                    "ext/ExtPkgDSExt.jl",
                    "module ExtPkgDSExt\nusing ExtPkg, DataStructures\nend\n",
                )
                mkdir("test")
                write(
                    "test/runtests.jl",
                    "using ExtPkg, DataStructures\n" *
                        "@assert Base.get_extension(ExtPkg, :ExtPkgDSExt) !== nothing\n" *
                        "println(\"LOADED=\", pkgversion(DataStructures))\n",
                )

                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10"`)

                project = TOML.parsefile("Project.toml")
                @test !haskey(project["deps"], "DataStructures")
                @test haskey(project["weakdeps"], "DataStructures")
                @test project["extensions"]["ExtPkgDSExt"] == "DataStructures"

                captured = IOBuffer()
                run(
                    pipeline(
                        `$(Base.julia_cmd()) --project=. -e "using Pkg; Pkg.test(; allow_reresolve=false)"`;
                        stdout = captured, stderr = captured,
                    ),
                )
                output = String(take!(captured))
                @test occursin("LOADED=0.17", output)
            end
        end
    end

    @testset "single project with [sources] path dep used in [targets]" begin
        # Regression test: a package that devs a sibling via [sources] and also
        # lists it as a test dependency in [targets]. The source package must be
        # stripped from [targets] as well as [extras] during resolution, otherwise
        # Pkg validation fails with "Dependency DevTool in target test not listed
        # in deps, weakdeps or extras" and the resolver never runs.
        mktempdir() do dir
            cd(dir) do
                # Sibling package that is dev'd via a local path source.
                mkdir("DevTool")
                write(
                    "DevTool/Project.toml", """
                    name = "DevTool"
                    uuid = "11111111-1111-1111-1111-111111111111"
                    version = "0.1.0"

                    [deps]
                    DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                    [compat]
                    DataStructures = "0.18"
                    """
                )
                mkdir("DevTool/src")
                write(
                    "DevTool/src/DevTool.jl",
                    "module DevTool\n" *
                        "using DataStructures\n" *
                        "loaded() = OrderedDict(:ok => true)[:ok]\n" *
                        "dependency_version() = Base.pkgversion(DataStructures)\n" *
                        "end\n"
                )

                mkdir("WeakTool")
                write(
                    "WeakTool/Project.toml", """
                    name = "WeakTool"
                    uuid = "77777777-7777-7777-7777-777777777777"
                    version = "0.1.0"
                    """
                )
                mkdir("WeakTool/src")
                write(
                    "WeakTool/src/WeakTool.jl",
                    "module WeakTool\nloaded() = true\nend\n"
                )

                # Package under test: a registry dep plus a path-sourced test dep
                # that is referenced from [targets].
                mkdir("SubPackage")
                write(
                    "SubPackage/Project.toml", """
                    name = "SubPackage"
                    uuid = "22222222-2222-2222-2222-222222222222"
                    version = "0.1.0"

                    [deps]
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                    [extras]
                    DevTool = "11111111-1111-1111-1111-111111111111"
                    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
                    WeakTool = "77777777-7777-7777-7777-777777777777"

                    [weakdeps]
                    WeakTool = "77777777-7777-7777-7777-777777777777"

                    [sources]
                    DevTool = {path = "../DevTool"}
                    WeakTool = {path = "../WeakTool"}

                    [compat]
                    julia = "1.10"
                    JSON = "0.20, 0.21"

                    [targets]
                    test = ["DevTool", "Test", "WeakTool"]
                    """
                )
                mkdir("SubPackage/src")
                write("SubPackage/src/SubPackage.jl", "module SubPackage\nend\n")
                mkdir("SubPackage/test")
                write(
                    "SubPackage/test/runtests.jl",
                    "using DevTool, Test, WeakTool\n" *
                        "@test DevTool.loaded()\n" *
                        "@test DevTool.dependency_version() == v\"0.18.0\"\n" *
                        "@test WeakTool.loaded()\n"
                )

                original_project = read(joinpath("SubPackage", "Project.toml"), String)

                # Before the fix this throws a ProcessFailedException.
                run(`$(Base.julia_cmd()) $downgrade_jl "" "SubPackage" "deps" "1"`)

                @test isfile(joinpath("SubPackage", "Manifest.toml"))
                manifest = TOML.parsefile(joinpath("SubPackage", "Manifest.toml"))
                deps_JSON = get(manifest["deps"], "JSON", [])
                @test !isempty(deps_JSON)
                @test startswith(deps_JSON[1]["version"], "0.20")
                @test only(manifest["deps"]["DataStructures"])["version"] == "0.18.0"
                devtool = only(manifest["deps"]["DevTool"])
                @test devtool["path"] == "../DevTool"
                @test Set(devtool["deps"]) == Set(["DataStructures"])
                @test only(manifest["deps"]["WeakTool"])["path"] == "../WeakTool"
                expected_main_deps = VERSION >= v"1.11" ?
                                     Set(["DataStructures", "JSON"]) :
                                     Set(["DevTool", "JSON", "WeakTool"])
                @test Set(only(manifest["deps"]["SubPackage"])["deps"]) ==
                    expected_main_deps
                run(`$(Base.julia_cmd()) --project=SubPackage -e 'using Pkg; Pkg.test(; allow_reresolve = false)'`)

                restored = TOML.parsefile(joinpath("SubPackage", "Project.toml"))
                @test restored["targets"]["test"] == ["DevTool", "Test", "WeakTool"]
                @test haskey(restored["sources"], "DevTool")
                @test haskey(restored["sources"], "WeakTool")
                @test haskey(restored["extras"], "DevTool")
                @test haskey(restored["extras"], "WeakTool")
                if VERSION >= v"1.11"
                    @test read(joinpath("SubPackage", "Project.toml"), String) !=
                        original_project
                    @test restored["deps"]["DataStructures"] ==
                        "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
                    @test !haskey(restored["deps"], "DevTool")
                    @test !haskey(restored["deps"], "WeakTool")
                    @test haskey(restored, "weakdeps")
                else
                    @test restored["deps"]["DevTool"] ==
                        "11111111-1111-1111-1111-111111111111"
                    @test restored["deps"]["WeakTool"] ==
                        "77777777-7777-7777-7777-777777777777"
                    @test !haskey(restored, "weakdeps")
                end

                mkdir("WeakOnlyPackage")
                write(
                    "WeakOnlyPackage/Project.toml", """
                    name = "WeakOnlyPackage"
                    uuid = "88888888-8888-8888-8888-888888888888"
                    version = "0.1.0"

                    [weakdeps]
                    WeakTool = "77777777-7777-7777-7777-777777777777"

                    [sources]
                    WeakTool = {path = "../WeakTool"}

                    [compat]
                    julia = "1.10"
                    WeakTool = "0.1"

                    [targets]
                    test = ["WeakTool"]
                    """
                )
                mkdir("WeakOnlyPackage/src")
                write(
                    "WeakOnlyPackage/src/WeakOnlyPackage.jl",
                    "module WeakOnlyPackage\nend\n"
                )
                mkdir("WeakOnlyPackage/test")
                write(
                    "WeakOnlyPackage/test/runtests.jl",
                    "using WeakTool\nWeakTool.loaded() || error(\"WeakTool failed to load\")\n"
                )

                original_weak_project =
                    read(joinpath("WeakOnlyPackage", "Project.toml"), String)

                run(`$(Base.julia_cmd()) $downgrade_jl "" "WeakOnlyPackage" "deps" "1"`)
                run(`$(Base.julia_cmd()) --project=WeakOnlyPackage -e 'using Pkg; Pkg.test(; allow_reresolve = false)'`)
                weak_only = TOML.parsefile(joinpath("WeakOnlyPackage", "Project.toml"))
                if VERSION >= v"1.11"
                    @test read(joinpath("WeakOnlyPackage", "Project.toml"), String) !=
                        original_weak_project
                    @test !haskey(weak_only, "deps")
                    @test weak_only["extras"]["WeakTool"] ==
                        "77777777-7777-7777-7777-777777777777"
                    @test weak_only["weakdeps"]["WeakTool"] ==
                        "77777777-7777-7777-7777-777777777777"
                else
                    @test weak_only["deps"]["WeakTool"] ==
                        "77777777-7777-7777-7777-777777777777"
                    @test weak_only["extras"]["WeakTool"] ==
                        "77777777-7777-7777-7777-777777777777"
                    @test !haskey(weak_only, "weakdeps")
                end
            end
        end
    end

    @testset "single project re-adds [sources] path deps to manifest (#3021)" begin
        # A path-sourced package listed in [deps] must end up in the resolved
        # Manifest.toml. It is removed for resolution (can't be resolved from the
        # registry) and was previously never added back, so the build step failed
        # with the package present in Project.toml but absent from Manifest.toml.
        mktempdir() do dir
            cd(dir) do
                # Locally-developed dependency referenced by path.
                mkdir("CorePkg")
                write(
                    "CorePkg/Project.toml", """
                    name = "CorePkg"
                    uuid = "33333333-3333-3333-3333-333333333333"
                    version = "1.2.3"

                    [weakdeps]
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                    [extensions]
                    CorePkgJSONExt = "JSON"
                    """
                )
                mkdir("CorePkg/src")
                write(
                    "CorePkg/src/CorePkg.jl",
                    "module CorePkg\nfunction extension_loaded end\nend\n"
                )
                mkdir("CorePkg/ext")
                write(
                    "CorePkg/ext/CorePkgJSONExt.jl",
                    "module CorePkgJSONExt\n" *
                        "using CorePkg, JSON\n" *
                        "CorePkg.extension_loaded() = true\n" *
                        "end\n"
                )

                # Package under test: a registry dep plus a path-sourced dep in [deps].
                mkdir("SubPackage")
                write(
                    "SubPackage/Project.toml", """
                    name = "SubPackage"
                    uuid = "44444444-4444-4444-4444-444444444444"
                    version = "0.1.0"

                    [deps]
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                    CorePkg = "33333333-3333-3333-3333-333333333333"

                    [sources]
                    CorePkg = {path = "../CorePkg"}

                    [compat]
                    julia = "1.10"
                    JSON = "0.20, 0.21"
                    """
                )

                run(`$(Base.julia_cmd()) $downgrade_jl "" "SubPackage" "deps" "1.10"`)

                manifest_file = joinpath("SubPackage", "Manifest.toml")
                @test isfile(manifest_file)
                manifest = TOML.parsefile(manifest_file)
                deps = manifest["deps"]

                # Registry dep resolved to its minimal version.
                deps_JSON = get(deps, "JSON", [])
                @test !isempty(deps_JSON)
                @test startswith(deps_JSON[1]["version"], "0.20")

                # #3021: the path-sourced dep is present as a path dependency.
                core_entry = get(deps, "CorePkg", [])
                @test !isempty(core_entry)
                @test core_entry[1]["path"] == "../CorePkg"
                @test core_entry[1]["uuid"] == "33333333-3333-3333-3333-333333333333"
                @test core_entry[1]["version"] == "1.2.3"
                @test core_entry[1]["extensions"]["CorePkgJSONExt"] == "JSON"
                @test core_entry[1]["weakdeps"]["JSON"] ==
                    "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                run(`$(Base.julia_cmd()) --project=SubPackage -e 'using CorePkg, JSON; CorePkg.extension_loaded() || error("path-source extension did not load")'`)

                # Project hash matches what Pkg expects for the restored project.
                @test manifest["project_hash"] ==
                    expected_project_hash(joinpath(dir, "SubPackage", "Project.toml"))
            end
        end
    end

    @testset "merged resolution with test dependencies" begin
        mktempdir() do dir
            cd(dir) do
                # Create main Project.toml with JSON dependency
                main_toml = """
                name = "TestPackage"
                uuid = "598b003f-0677-49cf-8d2a-39b1658b755a"
                version = "0.1.0"

                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                [compat]
                julia = "1.10"
                JSON = "0.20, 0.21"

                [workspace]
                projects = ["test"]
                """
                write("Project.toml", main_toml)

                # Create src directory and module
                mkdir("src")
                write("src/TestPackage.jl", "module TestPackage\nend\n")

                # Create test/Project.toml with additional test dependency and local source
                mkdir("test")
                test_toml = """
                [deps]
                TestPackage = "598b003f-0677-49cf-8d2a-39b1658b755a"
                Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
                DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                [compat]
                DataStructures = "0.17, 0.18"

                [sources.TestPackage]
                path = ".."
                """
                write("test/Project.toml", test_toml)

                # Run the downgrade script with merged resolution
                run(`$(Base.julia_cmd()) $downgrade_jl "" ".,test" "deps" "1.10"`)

                # Verify Manifest.toml was created
                @test isfile("Manifest.toml")

                # Parse the manifest
                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]

                # Verify main dependency JSON is minimized
                deps_JSON = get(deps, "JSON", [])
                @test !isempty(deps_JSON)
                @test startswith(deps_JSON[1]["version"], "0.20")

                # Verify test dependency DataStructures is minimized
                deps_DataStructures = get(deps, "DataStructures", [])
                @test !isempty(deps_DataStructures)
                @test startswith(deps_DataStructures[1]["version"], "0.17")

                # Verify TestPackage is in the manifest as a path dependency
                deps_TestPackage = get(deps, "TestPackage", [])
                @test !isempty(deps_TestPackage)
                @test deps_TestPackage[1]["path"] == "."
            end
        end
    end

    @testset "merged resolution for nested subpackage test environment" begin
        mktempdir() do dir
            cd(dir) do
                mkdir("libs")
                mkdir("libs/SubdirPackage")

                main_toml = """
                name = "SubdirPackage"
                uuid = "598b003f-0677-49cf-8d2a-39b1658b755a"
                version = "0.1.0"

                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                [compat]
                julia = "1.10"
                JSON = "0.20, 0.21"

                [workspace]
                projects = ["test"]
                """
                write("libs/SubdirPackage/Project.toml", main_toml)

                mkdir("libs/SubdirPackage/src")
                write("libs/SubdirPackage/src/SubdirPackage.jl", "module SubdirPackage\nend\n")

                mkdir("libs/SubdirPackage/test")
                test_toml = """
                [deps]
                SubdirPackage = "598b003f-0677-49cf-8d2a-39b1658b755a"
                Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
                DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                [compat]
                DataStructures = "0.17, 0.18"

                [sources.SubdirPackage]
                path = ".."
                """
                write("libs/SubdirPackage/test/Project.toml", test_toml)

                run(`$(Base.julia_cmd()) $downgrade_jl "" "libs/SubdirPackage,libs/SubdirPackage/test" "deps" "1.10"`)

                main_manifest_file = joinpath("libs", "SubdirPackage", "Manifest.toml")
                test_manifest_file = joinpath("libs", "SubdirPackage", "test", "Manifest.toml")
                @test isfile(main_manifest_file)
                @test isfile(test_manifest_file)

                main_manifest = TOML.parsefile(main_manifest_file)
                test_manifest = TOML.parsefile(test_manifest_file)

                main_deps = get(main_manifest, "deps", Dict())
                test_deps = get(test_manifest, "deps", Dict())

                deps_JSON = get(main_deps, "JSON", [])
                @test !isempty(deps_JSON)
                @test startswith(deps_JSON[1]["version"], "0.20")

                deps_DataStructures = get(main_deps, "DataStructures", [])
                @test !isempty(deps_DataStructures)
                @test startswith(deps_DataStructures[1]["version"], "0.17")

                deps_SubdirPackage = get(main_deps, "SubdirPackage", [])
                @test !isempty(deps_SubdirPackage)
                @test deps_SubdirPackage[1]["path"] == "."

                test_deps_SubdirPackage = get(test_deps, "SubdirPackage", [])
                @test !isempty(test_deps_SubdirPackage)
                @test test_deps_SubdirPackage[1]["path"] == ".."

                @test main_manifest["project_hash"] ==
                      expected_project_hash(joinpath(dir, "libs", "SubdirPackage", "Project.toml"))
                @test test_manifest["project_hash"] ==
                      expected_project_hash(joinpath(dir, "libs", "SubdirPackage", "test", "Project.toml"))
            end
        end
    end

    @testset "merged resolution promotes weakdeps used by tests" begin
        mktempdir() do dir
            cd(dir) do
                # Main project has JuMP as weakdep
                main_toml = """
                name = "TestPackage"
                uuid = "598b003f-0677-49cf-8d2a-39b1658b755a"
                version = "0.1.0"

                [deps]

                [weakdeps]
                JuMP = "4076af6c-e467-56ae-b986-b466b2749572"

                [extensions]
                JuMPExt = "JuMP"

                [compat]
                julia = "1.10"
                JuMP = "1.28"

                [workspace]
                projects = ["test"]
                """
                write("Project.toml", main_toml)

                mkdir("src")
                write("src/TestPackage.jl", "module TestPackage\nend\n")

                # Test project requires JuMP as a regular dependency
                mkdir("test")
                test_toml = """
                [deps]
                TestPackage = "598b003f-0677-49cf-8d2a-39b1658b755a"
                JuMP = "4076af6c-e467-56ae-b986-b466b2749572"

                [compat]
                JuMP = "1.28"

                [sources.TestPackage]
                path = ".."
                """
                write("test/Project.toml", test_toml)

                run(`$(Base.julia_cmd()) $downgrade_jl "" ".,test" "forcedeps"`)

                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]

                deps_JuMP = get(deps, "JuMP", [])
                @test !isempty(deps_JuMP)
                @test startswith(deps_JuMP[1]["version"], "1.28")
            end
        end
    end

    @testset "source package also a registry dependency gets a single manifest entry" begin
        mktempdir() do dir
            cd(dir) do
                # A [sources] path package (OrderedCollections, using the registry
                # uuid) that is ALSO a registry dependency of another resolved
                # package (DataStructures depends on OrderedCollections). The
                # resolver emits a registry entry for OrderedCollections; the
                # path entry must REPLACE it, not duplicate it. The current
                # runtime julia_version ("1") is used because [sources] projects
                # currently fail cross-runtime resolution (1.10-stdlib jlls like
                # MbedTLS_jll have no source path on a 1.12 runtime) even
                # without this fix.
                mkdir("LocalOC")
                write(
                    "LocalOC/Project.toml",
                    """
                    name = "OrderedCollections"
                    uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
                    version = "1.6.0"
                    """
                )
                mkpath("LocalOC/src")
                write("LocalOC/src/OrderedCollections.jl", "module OrderedCollections\nend\n")

                toml_content = """
                name = "TestPackage"
                uuid = "598b003f-0677-49cf-8d2a-39b1658b755a"
                version = "0.1.0"

                [deps]
                OrderedCollections = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
                DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                [compat]
                julia = "1.10"
                DataStructures = "0.18"

                [sources.OrderedCollections]
                path = "LocalOC"
                """
                write("Project.toml", toml_content)
                mkdir("src")
                write("src/TestPackage.jl", "module TestPackage\nend\n")

                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1"`)

                # The manifest must parse (Pkg rejects duplicate-name entries)
                # and contain exactly one OrderedCollections entry: the path one.
                env = Pkg.Types.EnvCache("Project.toml")
                manifest = TOML.parsefile("Manifest.toml")
                deps_OC = manifest["deps"]["OrderedCollections"]
                @test length(deps_OC) == 1
                @test deps_OC[1]["path"] == "LocalOC"
                @test deps_OC[1]["uuid"] == "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
            end
        end
    end

    @testset "merged resolution: test extra depending on the main package" begin
        # Regression for the duplicate main-package manifest entry. When a
        # project uses [extras]+[targets].test and a test extra transitively
        # depends on the main package, the merged resolve installs the main
        # package FROM THE REGISTRY too. add_main_package_to_manifest then has
        # to replace that registry stanza with the path stanza; blindly
        # appending it leaves two [[deps.<MainPkg>]] entries with the same uuid,
        # and Pkg rejects the manifest with "Invalid manifest format: ...'s
        # dependency on <MainPkg> is ambiguous" (exit 1) at set_manifest_project_hash.
        #
        # Mirrors SciML/LinearSolve.jl, whose test extra AlgebraicMultigrid
        # depends on LinearSolve. Here the registered pair
        # DataStructures -> OrderedCollections plays the same roles, with the
        # local package masquerading as the registered OrderedCollections so the
        # resolver emits a registry entry under the main package's uuid. The
        # current runtime julia_version ("1") is used because the resolver
        # currently fails cross-runtime resolution for [sources]/path projects.
        mktempdir() do dir
            cd(dir) do
                toml_content = """
                name = "OrderedCollections"
                uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
                version = "1.6.0"

                [deps]

                [extras]
                DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                [compat]
                julia = "1.10"
                DataStructures = "0.18"

                [targets]
                test = ["DataStructures"]
                """
                write("Project.toml", toml_content)
                mkdir("src")
                write("src/OrderedCollections.jl", "module OrderedCollections\nend\n")

                # Before the fix this exits 1 with the "ambiguous" manifest error.
                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1"`)

                @test isfile("Manifest.toml")

                # (a) The manifest must re-parse via Pkg (it rejects duplicate
                # name/uuid stanzas with the ambiguity error).
                Pkg.Types.EnvCache("Project.toml")

                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]

                # The test extra and its transitive dep are present.
                @test haskey(deps, "DataStructures")

                # (b) Exactly one stanza for the main package, and it is the path
                # entry pointing at the project dir, not the registry stanza.
                main_entries = get(deps, "OrderedCollections", [])
                @test length(main_entries) == 1
                @test main_entries[1]["path"] == "."
                @test main_entries[1]["uuid"] == "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
                @test main_entries[1]["version"] == "1.6.0"
            end
        end
    end

    @testset "merged resolution: source sibling in main [deps] (monorepo root)" begin
        # Regression for SciML/OptimalUncertaintyQuantification.jl Downgrade Core /
        # Downgrade Sublibraries. A monorepo ROOT (or a sublibrary) lists an
        # unregistered in-repo sibling directly in its main [deps] and pins it via
        # [sources], AND uses [extras]+[targets].test (merged resolution path).
        # create_merged_project starts from deepcopy(main_project), which retains
        # the sibling in [deps]/[compat]/[sources]; the resolver then errors
        # "unknown package UUID: <sibling>" before resolving anything. The merged
        # project must strip source packages from [deps]/[compat]/[sources], the
        # same way the non-merged path does.
        mktempdir() do dir
            cd(dir) do
                # Unregistered in-repo sibling with a made-up uuid.
                mkpath("lib/MySib/src")
                write(
                    "lib/MySib/Project.toml",
                    """
                    name = "MySib"
                    uuid = "11111111-2222-3333-4444-555555555555"
                    version = "0.1.0"
                    """
                )
                write("lib/MySib/src/MySib.jl", "module MySib\nend\n")

                # Root package depends on the sibling (in [deps], pinned via
                # [sources]) plus a real registry dep, and declares old-style test
                # deps via [extras]/[targets].test to force the merged path.
                write(
                    "Project.toml",
                    """
                    name = "RootPkg"
                    uuid = "598b003f-0677-49cf-8d2a-39b1658b755a"
                    version = "0.1.0"

                    [deps]
                    MySib = "11111111-2222-3333-4444-555555555555"
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                    [extras]
                    DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                    [compat]
                    julia = "1.10"
                    MySib = "0.1"
                    JSON = "0.20, 0.21"
                    DataStructures = "0.17, 0.18"

                    [sources]
                    MySib = { path = "lib/MySib" }

                    [targets]
                    test = ["DataStructures"]
                    """
                )
                mkdir("src")
                write("src/RootPkg.jl", "module RootPkg\nusing MySib\nend\n")

                # Before the fix this exits 1 with
                # "unknown package UUID: 11111111-...". MySib is in the skip list
                # (the workflow skips [sources] names), but that only prevents
                # compat-rewriting -- the resolver still chokes on it in [deps].
                run(`$(Base.julia_cmd()) $downgrade_jl "MySib" "." "deps" "1.10"`)

                @test isfile("Manifest.toml")
                # Manifest must re-parse via Pkg.
                Pkg.Types.EnvCache("Project.toml")

                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]

                # Registry dep was minimized.
                deps_JSON = get(deps, "JSON", [])
                @test !isempty(deps_JSON)
                @test startswith(deps_JSON[1]["version"], "0.20")

                # The source sibling is re-added to the manifest as a path dep.
                deps_MySib = get(deps, "MySib", [])
                @test !isempty(deps_MySib)
                @test deps_MySib[1]["path"] == joinpath("lib", "MySib")
                @test deps_MySib[1]["uuid"] == "11111111-2222-3333-4444-555555555555"

                # The original Project.toml is restored (still lists the source).
                restored = TOML.parsefile("Project.toml")
                @test haskey(restored["deps"], "MySib")
                @test haskey(restored, "sources") && haskey(restored["sources"], "MySib")
            end
        end
    end

    @testset "direct path-source runtime dependencies participate in minimum resolution" begin
        mktempdir() do dir
            cd(dir) do
                mkpath("LocalA/src")
                write(
                    "LocalA/Project.toml",
                    """
                    name = "LocalA"
                    uuid = "11111111-1111-1111-1111-111111111111"
                    version = "0.1.0"

                    [deps]
                    DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                    Preferences = "21216c6a-2e73-6563-6e65-726566657250"
                    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"

                    [compat]
                    DataStructures = "0.18"
                    julia = "1.10"
                    JSON = "0.21"
                    Preferences = "1.4.0"
                    StaticArrays = "1.8, 1.9"
                    """
                )
                write(
                    "LocalA/src/LocalA.jl",
                    "module LocalA\nusing DataStructures, JSON, Preferences, StaticArrays\nend\n"
                )

                mkpath("LocalB/src")
                write(
                    "LocalB/Project.toml",
                    """
                    name = "LocalB"
                    uuid = "22222222-2222-2222-2222-222222222222"
                    version = "0.1.0"

                    [deps]
                    Preferences = "21216c6a-2e73-6563-6e65-726566657250"
                    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"

                    [compat]
                    julia = "1.10"
                    Preferences = "1"
                    StaticArrays = "1.9.8"
                    """
                )
                write(
                    "LocalB/src/LocalB.jl",
                    "module LocalB\nusing Preferences, StaticArrays\nend\n"
                )

                mkpath("src")
                mkpath("test")
                write("src/RootPkg.jl", "module RootPkg\nusing LocalA, LocalB\nend\n")
                write(
                    "test/runtests.jl",
                    "using Test, BenchmarkTools, RootPkg\n@test true\n"
                )
                write(
                    "Project.toml",
                    """
                    name = "RootPkg"
                    uuid = "33333333-3333-3333-3333-333333333333"
                    version = "0.1.0"

                    [deps]
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                    LocalA = "11111111-1111-1111-1111-111111111111"
                    LocalB = "22222222-2222-2222-2222-222222222222"

                    [sources]
                    LocalA = {path = "LocalA"}
                    LocalB = {path = "LocalB"}

                    [compat]
                    julia = "1.10"
                    BenchmarkTools = "1.5.0"
                    JSON = "0.21.4"
                    LocalA = "0.1"
                    LocalB = "0.1"

                    [weakdeps]
                    DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                    [extras]
                    BenchmarkTools = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
                    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

                    [targets]
                    test = ["BenchmarkTools", "Test"]
                    """
                )

                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "alldeps" "1"`)

                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]
                @test only(deps["DataStructures"])["version"] == "0.18.0"
                @test only(deps["Preferences"])["version"] == "1.4.0"
                @test only(deps["StaticArrays"])["version"] == "1.9.8"
                @test only(deps["JSON"])["version"] == "0.21.4"
                @test only(deps["BenchmarkTools"])["version"] == "1.5.0"
                local_a = only(deps["LocalA"])
                local_b = only(deps["LocalB"])
                @test local_a["path"] == "LocalA"
                @test Set(local_a["deps"]) ==
                    Set(["DataStructures", "JSON", "Preferences", "StaticArrays"])
                @test local_b["path"] == "LocalB"
                @test Set(local_b["deps"]) == Set(["Preferences", "StaticArrays"])
                @test Set(only(deps["RootPkg"])["deps"]) ==
                    Set(["JSON", "LocalA", "LocalB"])
                run(`$(Base.julia_cmd()) --project=. -e 'using Pkg; Pkg.test(; allow_reresolve = false)'`)

                restored = TOML.parsefile("Project.toml")
                @test Set(keys(restored["sources"])) == Set(["LocalA", "LocalB"])
                @test haskey(restored["weakdeps"], "DataStructures")
                @test !haskey(restored["deps"], "DataStructures")
                @test !haskey(restored["deps"], "Preferences")
                @test !haskey(restored["deps"], "StaticArrays")
                @test !haskey(restored["deps"], "BenchmarkTools")
            end
        end
    end

    @testset "nested path sources remain local and constrain minimum resolution" begin
        mktempdir() do dir
            cd(dir) do
                mkpath("LocalB/src")
                write(
                    "LocalB/Project.toml",
                    """
                    name = "LocalB"
                    uuid = "44444444-4444-4444-4444-444444444444"
                    version = "0.1.0"

                    [deps]
                    DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                    [compat]
                    DataStructures = "0.18"
                    julia = "1.10"
                    """
                )
                write(
                    "LocalB/src/LocalB.jl",
                    "module LocalB\nusing DataStructures\nconst selected_version = Base.pkgversion(DataStructures)\nend\n"
                )

                mkpath("LocalA/src")
                write(
                    "LocalA/Project.toml",
                    """
                    name = "LocalA"
                    uuid = "55555555-5555-5555-5555-555555555555"
                    version = "0.1.0"

                    [deps]
                    DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
                    LocalB = "44444444-4444-4444-4444-444444444444"

                    [sources.LocalB]
                    path = "../LocalB"

                    [compat]
                    DataStructures = "0.18.1"
                    LocalB = "0.1"
                    julia = "1.10"
                    """
                )
                write(
                    "LocalA/src/LocalA.jl",
                    "module LocalA\nusing DataStructures, LocalB\nconst selected_version = LocalB.selected_version\nend\n"
                )

                mkpath("src")
                mkpath("test")
                write(
                    "src/RootPkg.jl",
                    "module RootPkg\nusing LocalA\nconst selected_version = LocalA.selected_version\nend\n"
                )
                write(
                    "test/runtests.jl",
                    "using RootPkg, Test\n@test RootPkg.selected_version == v\"0.18.1\"\n"
                )
                write(
                    "Project.toml",
                    """
                    name = "RootPkg"
                    uuid = "66666666-6666-6666-6666-666666666666"
                    version = "0.1.0"

                    [deps]
                    LocalA = "55555555-5555-5555-5555-555555555555"

                    [sources.LocalA]
                    path = "LocalA"

                    [compat]
                    LocalA = "0.1"
                    Test = "1.10"
                    julia = "1.10"

                    [extras]
                    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

                    [targets]
                    test = ["Test"]
                    """
                )

                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1"`)

                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]
                @test only(deps["DataStructures"])["version"] == "0.18.1"
                @test only(deps["LocalA"])["path"] == "LocalA"
                @test Set(only(deps["LocalA"])["deps"]) == Set(["DataStructures", "LocalB"])
                @test only(deps["LocalB"])["path"] == "LocalB"
                @test only(deps["LocalB"])["deps"] == ["DataStructures"]
                run(`$(Base.julia_cmd()) --project=. -e 'using Pkg; Pkg.test(; allow_reresolve = false)'`)

                restored = TOML.parsefile("Project.toml")
                @test Set(keys(restored["sources"])) == Set(["LocalA"])
                @test !haskey(restored["deps"], "LocalB")
                @test !haskey(restored["deps"], "DataStructures")
            end
        end
    end

    @testset "split projects rebase direct path sources in both locked manifests" begin
        mktempdir() do dir
            cd(dir) do
                mkpath("LocalDep/src")
                write(
                    "LocalDep/Project.toml",
                    """
                    name = "LocalDep"
                    uuid = "99999999-9999-9999-9999-999999999999"
                    version = "0.1.0"

                    [deps]
                    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"

                    [compat]
                    StaticArrays = "1.9.8"
                    """
                )
                write("LocalDep/src/LocalDep.jl", "module LocalDep\nusing StaticArrays\nend\n")

                mkpath("LocalTest/src")
                write(
                    "LocalTest/Project.toml",
                    """
                    name = "LocalTest"
                    uuid = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
                    version = "0.1.0"
                    """
                )
                write("LocalTest/src/LocalTest.jl", "module LocalTest\nend\n")

                mkpath("src")
                mkpath("test")
                write("src/RootPkg.jl", "module RootPkg\nusing LocalDep\nend\n")
                write(
                    "test/runtests.jl",
                    "using Test, BenchmarkTools, RootPkg\n@test true\n"
                )
                write(
                    "Project.toml",
                    """
                    name = "RootPkg"
                    uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                    version = "0.1.0"

                    [deps]
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                    LocalDep = "99999999-9999-9999-9999-999999999999"

                    [sources]
                    LocalDep = {path = "LocalDep"}
                    LocalTest = {path = "LocalTest"}

                    [compat]
                    julia = "1.10"
                    JSON = "0.21.4"
                    LocalDep = "0.1"

                    [extras]
                    LocalTest = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

                    [targets]
                    test = ["LocalTest"]
                    """
                )
                original_project = read("Project.toml", String)
                write(
                    "test/Project.toml",
                    """
                    [deps]
                    BenchmarkTools = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
                    RootPkg = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

                    [sources]
                    RootPkg = {path = ".."}

                    [compat]
                    BenchmarkTools = "1.5.0"
                    """
                )

                run(`$(Base.julia_cmd()) $downgrade_jl "" ".,test" "alldeps" "1"`)

                main_manifest = TOML.parsefile("Manifest.toml")
                test_manifest = TOML.parsefile("test/Manifest.toml")
                main_deps = main_manifest["deps"]
                test_deps = test_manifest["deps"]
                @test only(main_deps["StaticArrays"])["version"] == "1.9.8"
                @test only(main_deps["JSON"])["version"] == "0.21.4"
                @test only(main_deps["BenchmarkTools"])["version"] == "1.5.0"
                @test only(main_deps["LocalDep"])["path"] == "LocalDep"
                @test only(main_deps["LocalTest"])["path"] == "LocalTest"
                @test only(test_deps["LocalDep"])["path"] == "../LocalDep"
                @test only(test_deps["LocalTest"])["path"] == "../LocalTest"
                @test only(main_deps["RootPkg"])["path"] == "."
                @test only(test_deps["RootPkg"])["path"] == ".."
                expected_root_deps = VERSION >= v"1.11" ?
                                     Set(["JSON", "LocalDep"]) :
                                     Set(["JSON", "LocalDep", "LocalTest"])
                @test Set(only(test_deps["RootPkg"])["deps"]) == expected_root_deps
                if VERSION >= v"1.11"
                    @test read("Project.toml", String) == original_project
                end

                locked = Dict(
                    name => only(test_deps[name])["version"]
                    for name in ("BenchmarkTools", "JSON", "StaticArrays")
                )
                run(`$(Base.julia_cmd()) --project=test -e 'using Pkg; Pkg.instantiate(); include("test/runtests.jl")'`)
                after = TOML.parsefile("test/Manifest.toml")["deps"]
                @test locked == Dict(
                    name => only(after[name])["version"] for name in keys(locked)
                )
            end
        end
    end

    @testset "root and path-source compat constraints must overlap" begin
        mktempdir() do dir
            cd(dir) do
                mkpath("LocalDep/src")
                write(
                    "LocalDep/Project.toml",
                    """
                    name = "LocalDep"
                    uuid = "77777777-7777-7777-7777-777777777777"
                    version = "0.1.0"

                    [deps]
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                    [compat]
                    JSON = "0.20"
                    """
                )
                write("LocalDep/src/LocalDep.jl", "module LocalDep\nusing JSON\nend\n")

                mkpath("src")
                mkpath("test")
                write("src/RootPkg.jl", "module RootPkg\nusing LocalDep\nend\n")
                write("test/runtests.jl", "using Test, RootPkg\n@test true\n")
                write(
                    "Project.toml",
                    """
                    name = "RootPkg"
                    uuid = "88888888-8888-8888-8888-888888888888"
                    version = "0.1.0"

                    [deps]
                    JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                    LocalDep = "77777777-7777-7777-7777-777777777777"

                    [sources]
                    LocalDep = {path = "LocalDep"}

                    [compat]
                    julia = "1.10"
                    JSON = "=0.21.4"
                    LocalDep = "0.1"

                    [extras]
                    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

                    [targets]
                    test = ["Test"]
                    """
                )

                output = IOBuffer()
                process = run(
                    pipeline(
                        `$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10"`;
                        stdout = output, stderr = output
                    ); wait = false
                )
                wait(process)
                log = String(take!(output))
                @test !success(process)
                @test occursin(
                    "Root project and path source LocalDep require JSON with disjoint compat entries",
                    log
                )
            end
        end
    end

    @testset "direct path sources reject disjoint compat for a promoted dependency" begin
        mktempdir() do dir
            cd(dir) do
                for (name, uuid, constraint) in (
                        ("LocalA", "44444444-4444-4444-4444-444444444444", "0.12"),
                        ("LocalB", "66666666-6666-6666-6666-666666666666", "1.9.9"),
                    )
                    mkpath("$name/src")
                    write(
                        "$name/Project.toml",
                        """
                        name = "$name"
                        uuid = "$uuid"
                        version = "0.1.0"

                        [deps]
                        StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"

                        [compat]
                        StaticArrays = "$constraint"
                        """
                    )
                    write("$name/src/$name.jl", "module $name\nend\n")
                end
                mkdir("test")
                write(
                    "Project.toml",
                    """
                    name = "RootPkg"
                    uuid = "55555555-5555-5555-5555-555555555555"
                    version = "0.1.0"

                    [deps]
                    LocalA = "44444444-4444-4444-4444-444444444444"

                    [sources]
                    LocalA = {path = "LocalA"}

                    [compat]
                    julia = "1.10"
                    LocalA = "0.1"
                    """
                )
                write(
                    "test/Project.toml",
                    """
                    [deps]
                    LocalB = "66666666-6666-6666-6666-666666666666"
                    RootPkg = "55555555-5555-5555-5555-555555555555"

                    [sources]
                    LocalB = {path = "../LocalB"}
                    RootPkg = {path = ".."}

                    [compat]
                    LocalB = "0.1"
                    """
                )

                output = IOBuffer()
                process = run(
                    pipeline(
                        `$(Base.julia_cmd()) $downgrade_jl "" ".,test" "deps" "1.10"`;
                        stdout = output, stderr = output
                    ); wait = false
                )
                wait(process)
                @test !success(process)
                @test occursin("disjoint compat entries", String(take!(output)))
            end
        end
    end

    @testset "direct path sources intersect overlapping compat for a promoted dependency" begin
        mktempdir() do dir
            cd(dir) do
                # Two path sources constrain a shared registry dependency with
                # overlapping, lower-bounded-only ranges. Their intersection is
                # open-upper, so the serializer must emit ">= 0.18.0"; the earlier
                # string(spec)+regex approach instead emitted the unparseable
                # "0.18.0 - *" on Julia 1.11+ and aborted the resolution.
                for (name, uuid, constraint) in (
                        ("LocalA", "44444444-4444-4444-4444-444444444444", ">= 0.17"),
                        ("LocalB", "66666666-6666-6666-6666-666666666666", ">= 0.18"),
                    )
                    mkpath("$name/src")
                    write(
                        "$name/Project.toml",
                        """
                        name = "$name"
                        uuid = "$uuid"
                        version = "0.1.0"

                        [deps]
                        DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                        [compat]
                        DataStructures = "$constraint"
                        """
                    )
                    write("$name/src/$name.jl", "module $name\nend\n")
                end
                mkdir("test")
                write(
                    "Project.toml",
                    """
                    name = "RootPkg"
                    uuid = "55555555-5555-5555-5555-555555555555"
                    version = "0.1.0"

                    [deps]
                    LocalA = "44444444-4444-4444-4444-444444444444"

                    [sources]
                    LocalA = {path = "LocalA"}

                    [compat]
                    julia = "1.10"
                    LocalA = "0.1"
                    """
                )
                write(
                    "test/Project.toml",
                    """
                    [deps]
                    LocalB = "66666666-6666-6666-6666-666666666666"
                    RootPkg = "55555555-5555-5555-5555-555555555555"

                    [sources]
                    LocalB = {path = "../LocalB"}
                    RootPkg = {path = ".."}

                    [compat]
                    LocalB = "0.1"
                    """
                )

                # Resolve for the running Julia rather than a fixed target. The
                # serializer runs during the merge, before the resolver, so the
                # target is irrelevant to what this checks; matching it to the
                # runtime keeps resolution single-runtime. DataStructures 0.18.0
                # resolved for an older target from a newer runtime otherwise pulls
                # a stdlib JLL absent from the newer depot -- the action's
                # documented cross-runtime fragility, unrelated to compat serializing.
                target = string(VERSION.major, '.', VERSION.minor)
                run(`$(Base.julia_cmd()) $downgrade_jl "" ".,test" "deps" $target`)

                @test isfile("Manifest.toml")
                manifest = TOML.parsefile("Manifest.toml")
                # 0.18.0 is the intersection floor; LocalA's ">= 0.17" alone would
                # resolve to 0.17.x, so this also confirms the intersection applied.
                @test only(manifest["deps"]["DataStructures"])["version"] == "0.18.0"
            end
        end
    end

    @testset "no_promote keeps a named weakdep extension out of the joint resolve" begin
        # The merged resolution promotes every weakdep test-extra into ONE joint
        # floor-resolve -- correct, because the extensions coexist in a single test
        # env. A backend that is currently unresolvable on its own (here a nonexistent
        # floor, standing in for Mooncake, whose graph Resolver.jl cannot --min-resolve)
        # makes that joint resolve fail. Naming it in `no_promote` (the 5th arg) keeps
        # it a weakdep so it is never promoted; the joint resolve then succeeds and
        # every OTHER extension is still floor-tested together.
        write_repro() = begin
            write(
                "Project.toml",
                """
                name = "ReproPkg"
                uuid = "598b003f-0677-49cf-8d2a-39b1658b755a"
                version = "0.1.0"

                [deps]
                DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                [weakdeps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                [extensions]
                ReproJSONExt = "JSON"

                [compat]
                julia = "1.10"
                DataStructures = "0.17, 0.18"
                JSON = "0.999"

                [extras]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                [targets]
                test = ["JSON"]
                """,
            )
            mkdir("src")
            write("src/ReproPkg.jl", "module ReproPkg\nend\n")
        end

        # Without no_promote: JSON is promoted, and its unsatisfiable floor fails the run.
        mktempdir() do dir
            cd(dir) do
                write_repro()
                @test_throws ProcessFailedException run(
                    pipeline(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10"`;
                        stdout = devnull, stderr = devnull))
            end
        end

        # With no_promote=JSON: JSON stays a weakdep, the joint resolve succeeds, and
        # JSON is absent from the resolved [deps] (DataStructures is still minimized).
        mktempdir() do dir
            cd(dir) do
                write_repro()
                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10" "JSON"`)
                @test isfile("Manifest.toml")
                deps = TOML.parsefile("Manifest.toml")["deps"]
                @test startswith(deps["DataStructures"][1]["version"], "0.17")
                @test !haskey(deps, "JSON")
            end
        end
    end

    @testset "no_promote also excludes a PURE test-extra (no [weakdeps])" begin
        # Some repos list an AD backend only in [extras]/[targets].test with NO
        # [weakdeps] section (e.g. Optimization.jl's root). `no_promote` must exclude
        # it from promotion too, not just weakdep extras -- otherwise the joint resolve
        # still promotes the unresolvable backend. Here JSON is a pure extra (no
        # [weakdeps]/[extensions]) with a nonexistent floor.
        write_repro() = begin
            write(
                "Project.toml",
                """
                name = "ReproPkg"
                uuid = "598b003f-0677-49cf-8d2a-39b1658b755a"
                version = "0.1.0"

                [deps]
                DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"

                [compat]
                julia = "1.10"
                DataStructures = "0.17, 0.18"
                JSON = "0.999"

                [extras]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                [targets]
                test = ["JSON"]
                """,
            )
            mkdir("src")
            write("src/ReproPkg.jl", "module ReproPkg\nend\n")
        end

        # Without no_promote: the pure extra JSON is promoted -> unsatisfiable -> fails.
        mktempdir() do dir
            cd(dir) do
                write_repro()
                @test_throws ProcessFailedException run(
                    pipeline(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10"`;
                        stdout = devnull, stderr = devnull))
            end
        end

        # With no_promote=JSON: the pure extra is not promoted, the resolve succeeds,
        # and JSON is absent from the resolved [deps].
        mktempdir() do dir
            cd(dir) do
                write_repro()
                run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.10" "JSON"`)
                @test isfile("Manifest.toml")
                deps = TOML.parsefile("Manifest.toml")["deps"]
                @test startswith(deps["DataStructures"][1]["version"], "0.17")
                @test !haskey(deps, "JSON")
            end
        end
    end
end
