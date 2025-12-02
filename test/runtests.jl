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
                run(`$(Base.julia_cmd()) $downgrade_jl "." "deps" "1.10"`)

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

    @testset "invalid cases" begin
        # Test invalid mode
        mktempdir() do dir
            cd(dir) do
                write("Project.toml", "name = \"Test\"")
                @test_throws ProcessFailedException run(
                    `$(Base.julia_cmd()) $downgrade_jl "." "invalid_mode" "1.10"`,
                )
            end
        end

        # Test missing Project.toml
        mktempdir() do dir
            cd(dir) do
                @test_throws ProcessFailedException run(
                    `$(Base.julia_cmd()) $downgrade_jl "." "deps" "1.10"`,
                )
            end
        end
    end
end
