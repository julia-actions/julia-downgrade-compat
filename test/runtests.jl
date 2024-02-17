using Test

downgrade_jl = joinpath(dirname(@__DIR__), "downgrade.jl")

specs = [
    (
        strict = "v0",
        ignore = "Pkg0, Pkg00",
        compats = [
            ("julia", "1.6", "1.6"),
            ("Pkg0", "1.2", "1.2"),
            ("Pkg00", "1.3", "1.3"),
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
        ignore = "Pkg0, Pkg00",
        compats = [
            ("julia", "1.6", "1.6"),
            ("Pkg0", "1.2", "1.2"),
            ("Pkg00", "1.3", "1.3"),
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
        ignore = "Pkg0, Pkg00",
        compats = [
            ("julia", "1.6", "1.6"),
            ("Pkg0", "1.2", "1.2"),
            ("Pkg00", "1.3", "1.3"),
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
            toml1a = make_toml([(pkg, compat) for (pkg, compat, _) in compats])
            toml2a = make_toml([(pkg, compat) for (pkg, _, compat) in compats])
            toml1b = toml1a * "# foo\n"
            toml2b = toml2a * "# foo\n"
            mkdir("foo")
            write(file, toml1a)
            write(joinpath("foo", file), toml1b)
            run(`$(Base.julia_cmd()) $downgrade_jl $ignore $strict "., foo"`)
            toml3a = read(file, String)
            toml3b = read(joinpath("foo", file), String)
            @test toml3a != toml1a
            @test toml3a == toml2a
            @test toml3b != toml1b
            @test toml3b == toml2b
        end
    end
end

@testset "julia-downgrade-compat" begin
    @testset "basic $(spec.strict) $(spec.ignore) $file" for spec in specs, file in ["Project.toml", "JuliaProject.toml"]
        test_downgrade(; spec..., file=file)
    end
end
