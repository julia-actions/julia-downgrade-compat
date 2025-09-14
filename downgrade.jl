ignore_pkgs = filter(!isempty, map(strip, split(ARGS[1], ",")))
dirs = filter(!isempty, map(strip, split(ARGS[2], ",")))
mode = length(ARGS) >= 3 ? ARGS[3] : "deps"
julia_version = length(ARGS) >= 4 ? ARGS[4] : "1.10"

mode in ["deps", "alldeps", "all"] || error("mode must be deps, alldeps, or all")

@info "Using Resolver.jl with mode: $mode"

# Clone the resolver if not already present
resolver_path = "/tmp/resolver"
if !isdir(resolver_path)
    @info "Cloning Resolver.jl"
    run(`git clone https://github.com/StefanKarpinski/Resolver.jl.git $resolver_path`)
end

# Install dependencies
run(`julia --project=$resolver_path/bin -e "using Pkg; Pkg.instantiate()"`)

# Process each directory
for dir in dirs
    project_files = [joinpath(dir, "Project.toml"), joinpath(dir, "JuliaProject.toml")]
    filter!(isfile, project_files)
    isempty(project_files) && error("could not find Project.toml or JuliaProject.toml in $dir")
    
    @info "Running resolver on $dir with --min=@$mode"
    run(`julia --project=$resolver_path/bin $resolver_path/bin/resolve.jl $dir --min=@$mode --julia=$julia_version`)
    @info "Successfully resolved minimal versions for $dir"
end
