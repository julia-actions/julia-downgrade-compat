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
                write("DevTool/Project.toml", """
                name = "DevTool"
                uuid = "11111111-1111-1111-1111-111111111111"
                version = "0.1.0"
                """)
                mkdir("DevTool/src")
                write("DevTool/src/DevTool.jl", "module DevTool\nend\n")

                # Package under test: a registry dep plus a path-sourced test dep
                # that is referenced from [targets].
                mkdir("SubPackage")
                write("SubPackage/Project.toml", """
                name = "SubPackage"
                uuid = "22222222-2222-2222-2222-222222222222"
                version = "0.1.0"

                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"

                [extras]
                DevTool = "11111111-1111-1111-1111-111111111111"
                Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

                [sources]
                DevTool = {path = "../DevTool"}

                [compat]
                julia = "1.10"
                JSON = "0.20, 0.21"

                [targets]
                test = ["DevTool", "Test"]
                """)

                # Before the fix this throws a ProcessFailedException.
                run(`$(Base.julia_cmd()) $downgrade_jl "" "SubPackage" "deps" "1.10"`)

                @test isfile(joinpath("SubPackage", "Manifest.toml"))
                manifest = TOML.parsefile(joinpath("SubPackage", "Manifest.toml"))
                deps_JSON = get(manifest["deps"], "JSON", [])
                @test !isempty(deps_JSON)
                @test startswith(deps_JSON[1]["version"], "0.20")

                # The original Project.toml must be restored verbatim, including
                # the [targets] and [sources] entries that were stripped.
                restored = TOML.parsefile(joinpath("SubPackage", "Project.toml"))
                @test restored["targets"]["test"] == ["DevTool", "Test"]
                @test haskey(restored["sources"], "DevTool")
                @test haskey(restored["extras"], "DevTool")
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
                write("CorePkg/Project.toml", """
                name = "CorePkg"
                uuid = "33333333-3333-3333-3333-333333333333"
                version = "1.2.3"
                """)
                mkdir("CorePkg/src")
                write("CorePkg/src/CorePkg.jl", "module CorePkg\nend\n")

                # Package under test: a registry dep plus a path-sourced dep in [deps].
                mkdir("SubPackage")
                write("SubPackage/Project.toml", """
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
                """)

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
end
