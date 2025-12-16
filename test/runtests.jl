using Test
using TOML
using Pkg

downgrade_jl = joinpath(dirname(@__DIR__), "downgrade.jl")

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
                    `$(Base.julia_cmd()) $downgrade_jl "" "." "forcedeps" "1.10"`,
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

                # Parse the manifest
                manifest = TOML.parsefile("Manifest.toml")
                deps = manifest["deps"]

                # Verify TestPackage is in the manifest as a path dependency
                deps_TestPackage = get(deps, "TestPackage", [])
                @test !isempty(deps_TestPackage)
                @test deps_TestPackage[1]["path"] == "."
                @test deps_TestPackage[1]["uuid"] == "598b003f-0677-49cf-8d2a-39b1658b755a"

                # Verify Test stdlib is in the manifest
                deps_Test = get(deps, "Test", [])
                @test !isempty(deps_Test)

                # Verify the test/Project.toml was restored (still has sources section)
                test_project = TOML.parsefile("test/Project.toml")
                @test haskey(test_project, "sources")
                @test haskey(test_project["sources"], "TestPackage")
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
end
