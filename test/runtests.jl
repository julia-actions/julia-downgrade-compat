using Test

downgrade_jl = joinpath(dirname(@__DIR__), "downgrade.jl")

specs = [
    (
        strict = "v0",
        ignore = "Pkg0",
        compats = [
            ("julia", "1.6", "1.6"),
            ("Pkg0", "1.2", "1.2"),
            ("Pkg1", "1", "~1.0.0"),
            ("Pkg2", "1.2", "~1.2.0"),
            ("Pkg3", "1.2.3", "~1.2.3"),
            ("Pkg4", "0", "=0.0.0"),
            ("Pkg5", "0.2", "=0.2.0"),
            ("Pkg6", "0.2.3", "=0.2.3"),
            ("Pkg7", "0.0.3", "=0.0.3"),
            ("Pkg8", "0.0.0", "=0.0.0"),
            ("Pkg9", "^1.2.3", "~1.2.3"),
            ("Pkg10", "~1.2.3", "~1.2.3"),
            ("Pkg11", "=1.2.3", "=1.2.3"),
            ("Pkg12", "^1, ~2, =3", "~1.0.0"),
            ("Pkg13_jll", "1.2.3", "~1.2.3"),
        ]
    )
    (
        strict = "true",
        ignore = "Pkg0",
        compats = [
            ("julia", "1.6", "1.6"),
            ("Pkg0", "1.2", "1.2"),
            ("Pkg1", "1", "=1.0.0"),
            ("Pkg2", "1.2", "=1.2.0"),
            ("Pkg3", "1.2.3", "=1.2.3"),
            ("Pkg4", "0", "=0.0.0"),
            ("Pkg5", "0.2", "=0.2.0"),
            ("Pkg6", "0.2.3", "=0.2.3"),
            ("Pkg7", "0.0.3", "=0.0.3"),
            ("Pkg8", "0.0.0", "=0.0.0"),
            ("Pkg9", "^1.2.3", "=1.2.3"),
            ("Pkg10", "~1.2.3", "=1.2.3"),
            ("Pkg11", "=1.2.3", "=1.2.3"),
            ("Pkg12", "^1, ~2, =3", "=1.0.0"),
            ("Pkg13_jll", "1.2.3", "=1.2.3"),
        ]
    )
    (
        strict = "false",
        ignore = "Pkg0",
        compats = [
            ("julia", "1.6", "1.6"),
            ("Pkg0", "1.2", "1.2"),
            ("Pkg1", "1", "~1.0.0"),
            ("Pkg2", "1.2", "~1.2.0"),
            ("Pkg3", "1.2.3", "~1.2.3"),
            ("Pkg4", "0", "~0.0.0"),
            ("Pkg5", "0.2", "~0.2.0"),
            ("Pkg6", "0.2.3", "~0.2.3"),
            ("Pkg7", "0.0.3", "~0.0.3"),
            ("Pkg8", "0.0.0", "~0.0.0"),
            ("Pkg9", "^1.2.3", "~1.2.3"),
            ("Pkg10", "~1.2.3", "~1.2.3"),
            ("Pkg11", "=1.2.3", "=1.2.3"),
            ("Pkg12", "^1, ~2, =3", "~1.0.0"),
            ("Pkg13_jll", "1.2.3", "~1.2.3"),
        ]
    )
]

function make_toml(compats)
    io = IOBuffer()
    println(io, "name = \"MyProject\"")
    println(io)
    println(io, "[compat]")
    for (pkg, compat) in compats
        println(io, pkg, " = \"", compat, "\"")
    end
    println(io)
    println(io, "# some comment")
    String(take!(io))
end

function test_downgrade(; strict, ignore, compats, file)
    @info "testing $strict $ignore $file"
    mktempdir() do dir
        cd(dir) do 
            toml1 = make_toml([(pkg, compat) for (pkg, compat, _) in compats])
            toml2 = make_toml([(pkg, compat) for (pkg, _, compat) in compats])
            write("Project.toml", toml1)
            run(`$(Base.julia_cmd()) $downgrade_jl $ignore $strict`)
            toml3 = read("Project.toml", String)
            @test toml3 != toml1
            @test toml3 == toml2
        end
    end
end

@testset "julia-downgrade-compat" begin
    @testset "basic $(spec.strict) $(spec.ignore) $file" for spec in specs, file in ["Project.toml", "JuliaProject.toml"]
        test_downgrade(; spec..., file)
    end
end
