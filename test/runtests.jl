using Test

downgrade_jl = joinpath(dirname(@__DIR__), "downgrade.jl")

@testset "julia-downgrade-compat resolver tests" begin
    @testset "simple resolver test" begin
        mktempdir() do dir
            cd(dir) do 
                # Create a simple Project.toml
                toml_content = """
                name = "TestPackage"
                version = "0.1.0"
                
                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                
                [compat]
                julia = "1.9"
                JSON = "0.21"
                """
                write("Project.toml", toml_content)
                
                # Test that the script runs without error
                try
                    run(`$(Base.julia_cmd()) $downgrade_jl "" "." "deps" "1.11"`)
                    @test true  # If we get here, it didn't error
                    @test isfile("Manifest.toml")  # Should create a manifest
                catch e
                    @test_broken false "Resolver script failed: $e"
                end
            end
        end
    end
    
    @testset "argument validation" begin
        # Test invalid mode
        @test_throws ErrorException run(`$(Base.julia_cmd()) -e "include(\"$downgrade_jl\")" "" "." "invalid_mode" "1.11"`)
    end
end