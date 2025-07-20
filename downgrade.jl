function downgrade(file, ignore_pkgs, strict)
    lines = readlines(file)
    compat = false
    for (i, line) in pairs(lines)
        if startswith(line, "[compat]")
            compat = true
        elseif startswith(line, "[")
            compat = false
        elseif startswith(strip(line), "#") || isempty(strip(line))
            continue
        elseif compat
            # parse the compat line
            m = match(r"^([A-Za-z0-9_]+)( *= *\")([^\"]*)(\".*)", line)
            if m === nothing
                error("cannot parse compat line: $line")
            end
            pkg, eq, ver, post = m.captures
            # skip julia and any ignored packages
            if pkg == "julia" || pkg in ignore_pkgs
                println("skipping $pkg: $ver")
                continue
            end
            # just take the first part a list compat
            ver2 = strip(split(ver, ",")[1])
            if occursin(" - ", ver2)
                error("range specifiers not supported")
            end
            # separate the operator from the version
            if ver2[1] in "^~="
                op = ver2[1]
                ver2 = ver2[2:end]
            elseif isnumeric(ver2[1])
                op = '^'
            else
                println("skipping $pkg: $ver")
                continue
            end
            # parse the version
            ver2 = VersionNumber(ver2)
            # select a new operator
            if strict == "true"
                op = '='
            elseif strict == "v0" && ver2.major == 0
                op = '='
            elseif op == '^'
                op = '~'
            end
            # output the new compat entry
            ver2 = "$op$ver2"
            if ver == ver2
                println("skipping $pkg: $ver")
                continue
            end
            lines[i] = "$pkg$eq$ver2$post"
            println("downgrading $pkg: $ver -> $ver2")
        end
    end
    open(file, "w") do io
        for line in lines
            println(io, line)
        end
    end
end

ignore_pkgs = filter(!isempty, map(strip, split(ARGS[1], ",")))
strict = ARGS[2]
dirs = filter(!isempty, map(strip, split(ARGS[3], ",")))
use_resolver = length(ARGS) >= 4 ? ARGS[4] : "false"
resolver_julia_version = length(ARGS) >= 5 ? ARGS[5] : "1.11"

strict in ["true", "false", "v0"] || error("strict must be true, false or v0")
use_resolver in ["false", "deps", "alldeps", "all"] || error("use_resolver must be false, deps, alldeps, or all")

if use_resolver != "false"
    # Use Resolver.jl for more accurate downgrade resolution
    @info "Using Resolver.jl with mode: $use_resolver"
    
    # Clone the resolver if not already present
    resolver_path = "/tmp/resolver"
    if !isdir(resolver_path)
        @info "Cloning Resolver.jl"
        run(`git clone https://github.com/StefanKarpinski/Resolver.jl.git $resolver_path`)
        # Install dependencies
        run(`julia --project=$resolver_path/bin -e "using Pkg; Pkg.instantiate()"`)
    end
    
    # Process each directory
    for dir in dirs
        project_files = [joinpath(dir, "Project.toml"), joinpath(dir, "JuliaProject.toml")]
        filter!(isfile, project_files)
        isempty(project_files) && error("could not find Project.toml or JuliaProject.toml in $dir")
        
        @info "Running resolver on $dir with --min=@$use_resolver"
        try
            run(`julia --project=$resolver_path/bin $resolver_path/bin/resolve.jl $dir --min=@$use_resolver --julia=$resolver_julia_version`)
            @info "Successfully resolved minimal versions for $dir"
        catch e
            @warn "Resolver failed for $dir: $e"
            # Fall back to traditional downgrade method
            for file in project_files
                @info "Falling back to traditional downgrade for $file"
                downgrade(file, ignore_pkgs, strict)
            end
        end
    end
else
    # Use traditional compat entry modification
    for dir in dirs
        files = [joinpath(dir, "Project.toml"), joinpath(dir, "JuliaProject.toml")]
        filter!(isfile, files)
        isempty(files) && error("could not find Project.toml or JuliaProject.toml in $dir")
        for file in files
            @info "downgrading $file"
            downgrade(file, ignore_pkgs, strict)
        end
    end
end
