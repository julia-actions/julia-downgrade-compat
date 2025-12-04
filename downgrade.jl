using TOML

ignore_pkgs = filter(!isempty, map(strip, split(ARGS[1], ",")))
dirs = filter(!isempty, map(strip, split(ARGS[2], ",")))
mode = length(ARGS) >= 3 ? ARGS[3] : "deps"
julia_version = length(ARGS) >= 4 ? ARGS[4] : "1.10"

valid_modes = ["deps", "alldeps", "weakdeps", "forcedeps"]
mode in valid_modes || error("mode must be one of: $(join(valid_modes, ", "))")

@info "Using Resolver.jl with mode: $mode"

# Clone the resolver
resolver_path = mktempdir()
@info "Cloning Resolver.jl"
run(`git clone https://github.com/StefanKarpinski/Resolver.jl.git $resolver_path`)
# Install dependencies
run(`julia --project=$resolver_path/bin -e "using Pkg; Pkg.instantiate()"`)

"""
    get_lower_bounds(project_file, ignore_pkgs)

Parse the compat section of a Project.toml and extract the lower bound version
for each package. Returns a Dict mapping package names to their lower bound VersionNumber.

Uses the same logic as v1 of the action:
- For compat like "1.2.3", extracts v1.2.3
- For compat like "^1.2.3", extracts v1.2.3
- For comma-separated ranges like "1.2, 1.3", uses first entry
- Skips julia and ignored packages
"""
function get_lower_bounds(project_file::String, ignore_pkgs)
    bounds = Dict{String,VersionNumber}()
    lines = readlines(project_file)
    in_compat = false

    for line in lines
        stripped = strip(line)
        if startswith(stripped, "[compat]")
            in_compat = true
            continue
        elseif startswith(stripped, "[")
            in_compat = false
            continue
        elseif !in_compat || startswith(stripped, "#") || isempty(stripped)
            continue
        end

        # Parse the compat line
        m = match(r"^([A-Za-z0-9_]+)\s*=\s*\"([^\"]*)\"", stripped)
        if m === nothing
            continue
        end

        pkg, ver = m.captures

        # Skip julia and any ignored packages
        if pkg == "julia" || pkg in ignore_pkgs
            continue
        end

        # Take the first part of a comma-separated list
        ver = strip(split(ver, ",")[1])

        # Handle range specifiers (skip them)
        if occursin(" - ", ver)
            @warn "Range specifier not supported for forcedeps check: $pkg = \"$ver\""
            continue
        end

        # Remove operator prefix if present
        if !isempty(ver) && ver[1] in "^~="
            ver = ver[2:end]
        elseif !isempty(ver) && !isnumeric(ver[1])
            # Unknown format, skip
            continue
        end

        try
            bounds[pkg] = VersionNumber(ver)
        catch
            @warn "Could not parse version for $pkg: $ver"
        end
    end

    return bounds
end

"""
    get_resolved_versions(manifest_file)

Parse a Manifest.toml and extract the resolved versions for each package.
Returns a Dict mapping package names to their resolved VersionNumber.
"""
function get_resolved_versions(manifest_file::String)
    versions = Dict{String,VersionNumber}()

    if !isfile(manifest_file)
        return versions
    end

    # Parse the manifest
    manifest = TOML.parsefile(manifest_file)

    # Handle different manifest formats
    deps = get(manifest, "deps", manifest)

    for (pkg, entries) in deps
        if pkg in ("julia_version", "manifest_format")
            continue
        end

        # entries can be a vector of dicts or a dict
        entry = entries isa Vector ? first(entries) : entries

        if haskey(entry, "version")
            try
                versions[pkg] = VersionNumber(entry["version"])
            catch
                # Skip packages without parseable versions
            end
        end
    end

    return versions
end

"""
    check_forced_lower_bounds(project_file, manifest_file, ignore_pkgs)

Verify that the resolved versions in the manifest match the lower bounds
from the compat entries in the project file. Returns true if all match,
otherwise prints errors and returns false.
"""
function check_forced_lower_bounds(project_file::String, manifest_file::String, ignore_pkgs)
    lower_bounds = get_lower_bounds(project_file, ignore_pkgs)
    resolved = get_resolved_versions(manifest_file)

    all_match = true

    for (pkg, expected) in lower_bounds
        if !haskey(resolved, pkg)
            @warn "Package $pkg from compat not found in resolved manifest"
            continue
        end

        actual = resolved[pkg]

        # Check if the major.minor.patch matches
        # We compare the full version, but note that the lower bound might be
        # less specific (e.g., "1.2" means v1.2.0)
        if actual != expected
            @error "forcedeps check failed: $pkg resolved to $actual but lower bound is $expected"
            all_match = false
        else
            @info "forcedeps check passed: $pkg = $expected"
        end
    end

    return all_match
end

# Determine the resolver mode to use
# For forcedeps, we use "deps" mode and then verify the results
resolver_mode = mode == "forcedeps" ? "deps" : mode

# Process each directory
for dir in dirs
    project_files = [joinpath(dir, "Project.toml"), joinpath(dir, "JuliaProject.toml")]
    filter!(isfile, project_files)
    isempty(project_files) && error("could not find Project.toml or JuliaProject.toml in $dir")

    project_file = first(project_files)
    manifest_file = joinpath(dir, "Manifest.toml")

    @info "Running resolver on $dir with --min=@$resolver_mode"
    run(`julia --project=$resolver_path/bin $resolver_path/bin/resolve.jl $dir --min=@$resolver_mode --julia=$julia_version`)
    @info "Successfully resolved minimal versions for $dir"

    # For forcedeps mode, verify that the resolved versions match the lower bounds
    if mode == "forcedeps"
        @info "Checking that resolved versions match forced lower bounds..."
        if !check_forced_lower_bounds(project_file, manifest_file, ignore_pkgs)
            error("""
                forcedeps check failed: Some packages did not resolve to their lower bounds.

                This means the lowest compatible versions of your direct dependencies are
                incompatible with each other. To fix this, you need to increase the lower
                bounds in your compat entries to versions that are mutually compatible.

                See the errors above for which packages need their bounds adjusted.
                """)
        end
        @info "All forcedeps checks passed for $dir"
    end
end
