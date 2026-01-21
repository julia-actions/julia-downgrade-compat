using TOML

ignore_pkgs = filter(!isempty, map(strip, split(ARGS[1], ",")))
dirs = filter(!isempty, map(strip, split(ARGS[2], ",")))
mode = length(ARGS) >= 3 ? ARGS[3] : "deps"
julia_version = length(ARGS) >= 4 ? ARGS[4] : "1.10"

# Convert "1" to the current running Julia version (e.g., "1.12" for Julia 1.12.3)
# This ensures the resolved manifest matches the Julia version that will read it
if julia_version == "1"
    julia_version = string(VERSION.major, ".", VERSION.minor)
    @info "Converted julia_version \"1\" to \"$julia_version\" (current Julia version)"
end

valid_modes = ["deps", "alldeps", "weakdeps", "forcedeps"]
mode in valid_modes || error("mode must be one of: $(join(valid_modes, ", "))")

"""
    get_source_packages(project_file)

Parse a Project.toml and find packages that have custom sources (path or url).
Returns a Set of package names that should be excluded from resolution
because they are sourced from local paths or URLs (e.g., the main package in test/Project.toml).

In Julia 1.13+, test dependencies often use [sources.PackageName] with path=".."
to reference the main package. These cannot be resolved from the registry.
Packages can also be sourced from URLs, which similarly should be excluded from resolution.
"""
function get_source_packages(project_file::String)
    source_pkgs = Set{String}()

    if !isfile(project_file)
        return source_pkgs
    end

    project = TOML.parsefile(project_file)

    # Check for [sources] section entries with path or url keys
    if !haskey(project, "sources")
        return source_pkgs
    end
    sources = project["sources"]
    for (pkg_name, source_info) in sources
        if source_info isa Dict
            if haskey(source_info, "path")
                push!(source_pkgs, pkg_name)
                @info "Found source package: $pkg_name (path=$(source_info["path"]))"
            elseif haskey(source_info, "url")
                push!(source_pkgs, pkg_name)
                @info "Found source package: $pkg_name (url=$(source_info["url"]))"
            end
        end
    end

    return source_pkgs
end

"""
    remove_source_packages_from_project(project_file, source_pkgs)

Create a modified version of the Project.toml with source packages
removed from [deps], [compat], [extras], and [sources] sections.
Returns the original content so it can be restored later.

Note: We must also remove from [sources] because Pkg validates that any
package in [sources] must be in [deps] or [extras].
"""
function remove_source_packages_from_project(project_file::String, source_pkgs::Set{String})
    if isempty(source_pkgs)
        return nothing  # No modification needed
    end

    original_content = read(project_file, String)
    project = TOML.parsefile(project_file)
    modified = false

    # Remove from [deps], [extras], [compat], and [sources]
    for section_name in ("deps", "extras", "compat", "sources")
        haskey(project, section_name) || continue
        section = project[section_name]
        for pkg in source_pkgs
            haskey(section, pkg) || continue
            delete!(section, pkg)
            modified = true
            @info "Temporarily removing $pkg from [$section_name] for resolution"
        end
    end

    # Remove empty [sources] section
    if haskey(project, "sources") && isempty(project["sources"])
        delete!(project, "sources")
    end

    if modified
        open(project_file, "w") do io
            TOML.print(io, project)
        end
        return original_content
    end

    return nothing
end

"""
    restore_project_file(project_file, original_content)

Restore the original Project.toml content after resolution.
"""
function restore_project_file(project_file::String, original_content::Union{
        String, Nothing})
    if original_content !== nothing
        write(project_file, original_content)
        @info "Restored original Project.toml"
    end
end

"""
    create_merged_project(main_project_file, test_project_file, merged_dir)

Create a merged Project.toml that combines dependencies from both the main
project and test project. This ensures that when tests run (which combine
both environments), the resolved versions are compatible.

Returns a Set of source packages that were excluded from the merge.
"""
function create_merged_project(main_project_file::String, test_project_file::String, merged_dir::String)
    main_project = TOML.parsefile(main_project_file)
    test_project = TOML.parsefile(test_project_file)

    # Get source packages from test project (e.g., the main package itself)
    source_pkgs = get_source_packages(test_project_file)

    # Start with a copy of the main project
    merged = deepcopy(main_project)

    # Remove workspace section (not needed for resolution)
    delete!(merged, "workspace")

    # Merge deps from test project (excluding source packages)
    test_deps = get(test_project, "deps", Dict())
    if !haskey(merged, "deps")
        merged["deps"] = Dict{String, Any}()
    end
    for (pkg, uuid) in test_deps
        if pkg ∉ source_pkgs && !haskey(merged["deps"], pkg)
            merged["deps"][pkg] = uuid
            @info "Adding test dependency to merged project: $pkg"
        end
    end

    # Merge compat entries from test project
    test_compat = get(test_project, "compat", Dict())
    if !haskey(merged, "compat")
        merged["compat"] = Dict{String, Any}()
    end
    for (pkg, compat) in test_compat
        if pkg ∉ source_pkgs
            if haskey(merged["compat"], pkg)
                # Both have compat - keep both constraints (Resolver.jl will find intersection)
                # For simplicity, we keep the main project's compat if they differ
                @info "Package $pkg has compat in both projects, using main project's compat"
            else
                merged["compat"][pkg] = compat
                @info "Adding test compat to merged project: $pkg = \"$compat\""
            end
        end
    end

    # Merge weakdeps from test project
    test_weakdeps = get(test_project, "weakdeps", Dict())
    if !isempty(test_weakdeps)
        if !haskey(merged, "weakdeps")
            merged["weakdeps"] = Dict{String, Any}()
        end
        for (pkg, uuid) in test_weakdeps
            if pkg ∉ source_pkgs && !haskey(merged["weakdeps"], pkg)
                merged["weakdeps"][pkg] = uuid
                @info "Adding test weakdep to merged project: $pkg"
            end
        end
    end

    # Write merged project
    mkpath(merged_dir)
    merged_file = joinpath(merged_dir, "Project.toml")
    open(merged_file, "w") do io
        TOML.print(io, merged)
    end

    @info "Created merged project at $merged_file"
    return source_pkgs
end

"""
    should_merge_projects(dirs)

Check if we should merge the main and test projects for resolution.
Returns (should_merge, main_dir, test_dir) tuple.
"""
function should_merge_projects(dirs)
    # Normalize directory names
    normalized = [d == "." ? "." : rstrip(d, '/') for d in dirs]

    has_main = "." in normalized
    has_test = "test" in normalized

    if has_main && has_test
        return (true, ".", "test")
    end

    return (false, nothing, nothing)
end

"""
    add_main_package_to_manifest(manifest_file, main_project_file)

Add the main package itself to the manifest as a path dependency.
This is needed because the main package is excluded from resolution
(it's a local source), but the manifest needs to include it for
workspace projects to work correctly.
"""
function add_main_package_to_manifest(manifest_file::String, main_project_file::String)
    if !isfile(manifest_file)
        @warn "Manifest file not found: $manifest_file"
        return
    end

    main_project = TOML.parsefile(main_project_file)

    # Get main package info
    pkg_name = get(main_project, "name", nothing)
    pkg_uuid = get(main_project, "uuid", nothing)
    pkg_version = get(main_project, "version", nothing)

    if pkg_name === nothing || pkg_uuid === nothing
        @warn "Main project missing name or uuid, cannot add to manifest"
        return
    end

    # Read the manifest content as text to preserve formatting
    manifest_content = read(manifest_file, String)

    # Build the entry for the main package
    entry_lines = String[]
    push!(entry_lines, "[[deps.$pkg_name]]")
    push!(entry_lines, "path = \".\"")
    push!(entry_lines, "uuid = \"$pkg_uuid\"")
    if pkg_version !== nothing
        push!(entry_lines, "version = \"$pkg_version\"")
    end
    push!(entry_lines, "")

    main_pkg_entry = join(entry_lines, "\n")

    # Append the main package entry to the manifest
    open(manifest_file, "w") do io
        print(io, manifest_content)
        if !endswith(manifest_content, "\n")
            println(io)
        end
        print(io, main_pkg_entry)
    end

    @info "Added main package $pkg_name to manifest"
end

"""
    resolve_directory(dir, resolver_path, resolver_mode, julia_version, mode, ignore_pkgs)

Resolve dependencies for a single directory. Handles source packages by temporarily
removing them from the project file, running the resolver, and then restoring the original.
Returns the source packages found in the directory (for use in forcedeps checking).
"""
function resolve_directory(
        dir::AbstractString, resolver_path::AbstractString, resolver_mode::AbstractString,
        julia_version::AbstractString, mode::AbstractString, ignore_pkgs)
    project_files = [joinpath(dir, "Project.toml"), joinpath(dir, "JuliaProject.toml")]
    filter!(isfile, project_files)
    isempty(project_files) &&
        error("could not find Project.toml or JuliaProject.toml in $dir")

    project_file = first(project_files)
    manifest_file = joinpath(dir, "Manifest.toml")

    # Handle packages with [sources] entries (e.g., test/Project.toml referencing main package)
    # These packages cannot be resolved from the registry, so we temporarily remove them
    source_pkgs = get_source_packages(project_file)
    original_content = remove_source_packages_from_project(project_file, source_pkgs)

    try
        @info "Running resolver on $dir with --min=@$resolver_mode"
        run(`$(Base.julia_cmd()) --project=$resolver_path/bin $resolver_path/bin/resolve.jl $dir --min=@$resolver_mode --julia=$julia_version`)
        @info "Successfully resolved minimal versions for $dir"
    finally
        # Always restore the original Project.toml, even if resolution fails
        restore_project_file(project_file, original_content)
    end

    # For forcedeps mode, verify that the resolved versions match the lower bounds
    # Note: we check against the original project file (now restored), but skip source packages
    if mode == "forcedeps"
        @info "Checking that resolved versions match forced lower bounds for $dir..."
        forcedeps_ignore = union(ignore_pkgs, source_pkgs)
        if !check_forced_lower_bounds(project_file, manifest_file, forcedeps_ignore)
            error("""
                forcedeps check failed for $dir: Some packages did not resolve to their lower bounds.

                This means the lowest compatible versions of your direct dependencies are
                incompatible with each other. To fix this, you need to increase the lower
                bounds in your compat entries to versions that are mutually compatible.

                See the errors above for which packages need their bounds adjusted.
                """)
        end
        @info "All forcedeps checks passed for $dir"
    end

    return source_pkgs
end

"""
    check_for_workspace(project_file)

Check if a project file defines workspaces and print a warning if so.
Workspaces with nested environments are not fully supported.
"""
function check_for_workspace(project_file::String)
    if !isfile(project_file)
        return
    end

    project = TOML.parsefile(project_file)

    if haskey(project, "workspace")
        workspace = project["workspace"]
        projects = get(workspace, "projects", [])
        if length(projects) > 1 || (length(projects) == 1 && projects[1] != "test")
            @warn """Workspace with multiple or non-standard projects detected.
            This action currently only supports merging main (.) and test environments.
            Nested workspaces or additional workspace projects (e.g., docs, integration tests)
            are not fully supported and may not be resolved correctly."""
        end
    end
end

@info "Using Resolver.jl with mode: $mode"

# Clone the resolver
resolver_path = mktempdir()
@info "Cloning Resolver.jl"
run(`git clone https://github.com/StefanKarpinski/Resolver.jl.git $resolver_path`)
# Install dependencies
run(`$(Base.julia_cmd()) --project=$resolver_path/bin -e "using Pkg; Pkg.instantiate()"`)

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
    bounds = Dict{String, VersionNumber}()
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
    versions = Dict{String, VersionNumber}()

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

# Check for workspaces in main project and warn if detected
main_project_candidates = ["./Project.toml", "./JuliaProject.toml"]
for candidate in main_project_candidates
    check_for_workspace(candidate)
end

# Check if we should merge main and test projects
(do_merge, main_dir, test_dir) = should_merge_projects(dirs)

if do_merge
    # Merged resolution: combine main and test projects, resolve together
    @info "Merging main (.) and test projects for combined resolution"

    main_project_file = isfile(joinpath(main_dir, "Project.toml")) ?
                        joinpath(main_dir, "Project.toml") :
                        joinpath(main_dir, "JuliaProject.toml")
    test_project_file = isfile(joinpath(test_dir, "Project.toml")) ?
                        joinpath(test_dir, "Project.toml") :
                        joinpath(test_dir, "JuliaProject.toml")

    if !isfile(main_project_file)
        error("could not find Project.toml or JuliaProject.toml in $main_dir")
    end
    if !isfile(test_project_file)
        error("could not find Project.toml or JuliaProject.toml in $test_dir")
    end

    # Create merged project in temp directory
    merged_dir = mktempdir()
    source_pkgs = create_merged_project(main_project_file, test_project_file, merged_dir)

    # Run resolver on merged project
    @info "Running resolver on merged project with --min=@$resolver_mode"
    run(`$(Base.julia_cmd()) --project=$resolver_path/bin $resolver_path/bin/resolve.jl $merged_dir --min=@$resolver_mode --julia=$julia_version`)
    @info "Successfully resolved minimal versions for merged project"

    # Copy manifest to main project directory
    merged_manifest = joinpath(merged_dir, "Manifest.toml")
    main_manifest = joinpath(main_dir, "Manifest.toml")
    if isfile(merged_manifest)
        cp(merged_manifest, main_manifest; force = true)
        @info "Copied merged manifest to $main_manifest"

        # Add the main package itself to the manifest as a path dependency
        # This is needed for workspace projects where the test project depends on the main package
        add_main_package_to_manifest(main_manifest, main_project_file)
    end

    # For forcedeps mode, verify lower bounds for both projects
    if mode == "forcedeps"
        @info "Checking that resolved versions match forced lower bounds..."
        forcedeps_ignore = union(ignore_pkgs, source_pkgs)

        # Check main project
        if !check_forced_lower_bounds(main_project_file, main_manifest, forcedeps_ignore)
            error("""
                forcedeps check failed: Some packages did not resolve to their lower bounds.

                This means the lowest compatible versions of your direct dependencies are
                incompatible with each other. To fix this, you need to increase the lower
                bounds in your compat entries to versions that are mutually compatible.

                See the errors above for which packages need their bounds adjusted.
                """)
        end

        # Check test project (excluding source packages)
        if !check_forced_lower_bounds(test_project_file, main_manifest, forcedeps_ignore)
            error("""
                forcedeps check failed: Some test dependencies did not resolve to their lower bounds.

                See the errors above for which packages need their bounds adjusted.
                """)
        end

        @info "All forcedeps checks passed for merged project"
    end

    # Process any remaining directories that aren't main or test
    other_dirs = filter(d -> d != "." && d != "test", dirs)
    for dir in other_dirs
        resolve_directory(
            dir, resolver_path, resolver_mode, julia_version, mode, ignore_pkgs)
    end
else
    # Independent resolution: process each directory separately
    for dir in dirs
        resolve_directory(
            dir, resolver_path, resolver_mode, julia_version, mode, ignore_pkgs)
    end
end
