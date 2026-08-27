using TOML
using Pkg
using Downloads

ignore_pkgs = filter(!isempty, map(strip, split(ARGS[1], ",")))
dirs = filter(!isempty, map(strip, split(ARGS[2], ",")))
mode = length(ARGS) >= 3 ? ARGS[3] : "deps"
current_julia_minor = string(VERSION.major, ".", VERSION.minor)
julia_version = length(ARGS) >= 4 ? ARGS[4] : current_julia_minor
# Weakdep extensions to keep as weakdeps in the merged project instead of
# promoting them to hard [deps]. The merged resolution otherwise force-min-
# resolves every promoted weakdep together (the extensions all coexist in one
# test env, so testing them together is correct); use this only to exclude a
# backend that is currently unresolvable on its own -- e.g. Mooncake, whose graph
# Resolver.jl cannot --min-resolve (StefanKarpinski/Resolver.jl#24). The excluded
# backend stays a weakdep (installed at latest), every other extension is still
# floor-tested jointly.
no_promote = length(ARGS) >= 5 ? filter(!isempty, map(strip, split(ARGS[5], ","))) : String[]

# The resolver only accepts numeric compat specs, so setup-julia channel
# aliases ("lts", "pre", "min", "nightly", ...) must be converted to a numeric
# major.minor first. Each alias is resolved to what it actually denotes (the
# same thing setup-julia would install for it), not to the runtime Julia:
#   - "lts"/"release": the juliaup version database's channel mapping
#   - "pre": the highest version (prereleases included) in the official
#     versions.json, matching setup-julia's includePrerelease resolution
#   - "min": the lower bound of the project's own `julia` compat entry
#   - "nightly"/"X.Y-nightly": nightlies have no registry presence, so use the
#     runtime Julia / the numeric prefix (under setup-julia these match)
# The versiondb/versions.json are machine-generated with a stable shape, so the
# needed fields are extracted with targeted regexes rather than a JSON parser
# (none is available in stdlib for the Julia versions this action supports).

"""
    compat_lower_bound_minor(compat_str)

Lower bound of a Pkg compat entry as "major.minor", e.g. "1.6, 1.10" -> "1.6",
"^1.10" -> "1.10", "1.6 - 1.12" -> "1.6".
"""
function compat_lower_bound_minor(compat_str::AbstractString)
    first_spec = strip(first(split(compat_str, ",")))
    m = match(r"(\d+)(?:\.(\d+))?", first_spec)
    m === nothing && error("Cannot parse julia compat entry: $compat_str")
    return string(m.captures[1], ".", something(m.captures[2], "0"))
end

function resolve_julia_version_spec(spec::AbstractString, dirs, current_julia_minor)
    spec == "1" && return current_julia_minor
    if spec in ("lts", "release")
        url = "https://raw.githubusercontent.com/JuliaLang/juliaup/main/versiondb/versiondb-x86_64-unknown-linux-gnu.json"
        db = read(Downloads.download(url), String)
        m = match(Regex("\"$spec\"\\s*:\\s*\\{\\s*\"Version\"\\s*:\\s*\"(\\d+\\.\\d+)"), db)
        m === nothing && error("Could not find the \"$spec\" channel in the juliaup version database")
        return String(m.captures[1])
    end
    if spec == "pre"
        vj = read(Downloads.download("https://julialang-s3.julialang.org/bin/versions.json"), String)
        vers = [VersionNumber(m.captures[1])
                for m in eachmatch(r"\"(\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)\"\s*:\s*\{", vj)]
        isempty(vers) && error("Could not parse any versions from versions.json")
        v = maximum(vers)
        return string(v.major, ".", v.minor)
    end
    if spec == "min"
        isempty(dirs) && error("julia_version \"min\" requires at least one project")
        project_file = joinpath(dirs[1], "Project.toml")
        isfile(project_file) || (project_file = joinpath(dirs[1], "JuliaProject.toml"))
        isfile(project_file) || error("julia_version \"min\": no Project.toml in $(dirs[1])")
        compat = get(get(TOML.parsefile(project_file), "compat", Dict()), "julia", nothing)
        compat === nothing &&
            error("julia_version \"min\": no `julia` compat entry in $project_file")
        return compat_lower_bound_minor(compat)
    end
    spec == "nightly" && return current_julia_minor
    m = match(r"^(\d+\.\d+)-[A-Za-z]", spec)
    m !== nothing && return String(m.captures[1])
    # Reject unknown aliases with a clear message instead of the resolver's
    # cryptic "Invalid compat version spec"; anything else (numeric versions
    # and other resolver-understood specs) passes through unchanged.
    occursin(r"^[A-Za-z]+$", spec) &&
        error("Unsupported julia_version channel alias \"$spec\". Use a numeric " *
              "version like \"1.10\" or one of: 1, lts, release, pre, min, " *
              "nightly, <major.minor>-nightly.")
    return spec
end

if julia_version != current_julia_minor
    original_spec = julia_version
    julia_version = resolve_julia_version_spec(julia_version, dirs, current_julia_minor)
    if julia_version != original_spec
        @info "Converted julia_version \"$original_spec\" to \"$julia_version\""
    end
end

if julia_version != current_julia_minor
    @warn "Requested julia_version=$julia_version differs from current runtime Julia $current_julia_minor. Cross-runtime mode may fail."
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

struct DirectPathSource
    name::String
    project::Dict{String, Any}
    project_file::String
end

function find_project_file(dir::AbstractString)
    for filename in ("Project.toml", "JuliaProject.toml")
        project_file = joinpath(dir, filename)
        isfile(project_file) && return project_file
    end
    return nothing
end

"""
    active_project_dependencies(project; include_test_target = false)

Return the dependencies active in the project environment. When
`include_test_target` is true, this also includes extras or weak dependencies
selected by `[targets].test`.
"""
function active_project_dependencies(project; include_test_target = false)
    deps = Dict{String, Any}(get(project, "deps", Dict{String, Any}()))
    include_test_target || return deps

    extras = get(project, "extras", Dict{String, Any}())
    weakdeps = get(project, "weakdeps", Dict{String, Any}())
    test_target = get(get(project, "targets", Dict{String, Any}()), "test", String[])
    for name in test_target
        haskey(deps, name) && continue
        if haskey(extras, name)
            deps[name] = extras[name]
        elseif haskey(weakdeps, name)
            deps[name] = weakdeps[name]
        end
    end
    return deps
end

"""
    test_target_path_sources(project_file) -> Vector{String}

Return local path packages selected by `[targets].test` but absent from runtime
`[deps]`.
"""
function test_target_path_sources(project_file::String)
    project = TOML.parsefile(project_file)
    deps = get(project, "deps", Dict{String, Any}())
    extras = get(project, "extras", Dict{String, Any}())
    weakdeps = get(project, "weakdeps", Dict{String, Any}())
    sources = get(project, "sources", Dict{String, Any}())
    test_target = get(get(project, "targets", Dict{String, Any}()), "test", String[])
    result = String[]

    for name in test_target
        haskey(deps, name) && continue
        source = get(sources, name, nothing)
        (source isa AbstractDict && haskey(source, "path")) || continue

        uuid = get(extras, name, nothing)
        weak_uuid = get(weakdeps, name, nothing)
        if uuid === nothing
            uuid = weak_uuid
            uuid === nothing && continue
        elseif weak_uuid !== nothing && weak_uuid != uuid
            error(
                "Test-target path source $name has uuid $uuid in [extras], " *
                    "but $weak_uuid in [weakdeps]"
            )
        end
        push!(result, name)
    end

    return result
end

"""
    prepare_test_target_path_sources!(project_file; registry_deps) -> Vector{String}

Prepare test-only path sources for a locked `Pkg.test` and return their names.
Weak-only sources are also added to `[extras]`, as Pkg requires every
`[sources]` entry there or in `[deps]`. On Julia 1.11 and newer, hard registry
dependencies used only through these sources are promoted to runtime `[deps]`
so `Pkg.test` preserves their resolved versions. Julia 1.10 and earlier instead
require the path sources themselves in runtime `[deps]` because their test
sandbox does not honor `[sources]`.
"""
function prepare_test_target_path_sources!(
        project_file::String; registry_deps = Dict{String, Any}())
    names = test_target_path_sources(project_file)

    project = TOML.parsefile(project_file)
    deps = VERSION < v"1.11" || !isempty(registry_deps) ?
           get!(project, "deps", Dict{String, Any}()) :
           get(project, "deps", Dict{String, Any}())
    extras = get!(project, "extras", Dict{String, Any}())
    weakdeps = get(project, "weakdeps", Dict{String, Any}())
    changed = false
    anchored = String[]
    added_extras = String[]

    if VERSION >= v"1.11"
        for name in sort!(collect(keys(registry_deps)))
            uuid = registry_deps[name]
            for (section, entries) in (("[deps]", deps), ("[extras]", extras),
                    ("[weakdeps]", weakdeps))
                haskey(entries, name) || continue
                entries[name] == uuid || error(
                    "Test-only path-source dependency $name has uuid $uuid, " *
                        "but $(entries[name]) in $section"
                )
            end

            if haskey(weakdeps, name)
                delete!(weakdeps, name)
                isempty(weakdeps) && delete!(project, "weakdeps")
                changed = true
            end
            if !haskey(deps, name)
                deps[name] = uuid
                changed = true
                push!(anchored, name)
            end
        end
    end

    for name in names
        uuid = get(extras, name, nothing)
        weak_uuid = get(weakdeps, name, nothing)
        if uuid === nothing
            uuid = weak_uuid
            extras[name] = uuid
            changed = true
            push!(added_extras, name)
        end
        if VERSION < v"1.11"
            if weak_uuid !== nothing
                delete!(weakdeps, name)
                isempty(weakdeps) && delete!(project, "weakdeps")
            end
            deps[name] = uuid
            changed = true
        end
    end

    changed || return names
    open(project_file, "w") do io
        TOML.print(io, project)
    end
    if !isempty(anchored)
        @info "Promoted test-only path-source dependencies for locked Pkg.test" anchored
    end
    if !isempty(added_extras)
        @info "Added weak-only test-target path sources to [extras] for Pkg validation" added_extras
    end
    if VERSION < v"1.11" && !isempty(names)
        @info "Promoted test-target path sources for Julia $(VERSION.major).$(VERSION.minor) Pkg.test compatibility" names
    end
    return names
end

"""
    registry_backed_manifest_entries(manifest_file) -> Dict{String, String}

Map package name to uuid for every manifest entry that came from the registry,
i.e. that carries both a resolved `version` and a `git-tree-sha1`. Stdlibs
(no tree hash) and path/url entries (no version, or sourced in-tree) are
excluded, so this is exactly the set of names holding a resolved floor.
"""
function registry_backed_manifest_entries(manifest_file::String)
    entries = Dict{String, String}()
    isfile(manifest_file) || return entries
    manifest = TOML.parsefile(manifest_file)
    # ≥1.7 manifests nest the package tables under `deps`; ≤1.6 manifests put
    # them at the top level next to metadata scalars like `julia_version`.
    deps = get(manifest, "deps", manifest)
    for (name, stanzas) in deps
        stanzas isa AbstractVector || continue
        length(stanzas) == 1 || continue
        entry = only(stanzas)
        entry isa AbstractDict || continue
        haskey(entry, "version") && haskey(entry, "git-tree-sha1") || continue
        uuid = get(entry, "uuid", nothing)
        uuid === nothing || (entries[name] = uuid)
    end
    return entries
end

"""
    promote_test_target_registry_deps!(project_file, manifest_file) -> Vector{String}

Promote registry-backed `[targets].test` dependencies into runtime `[deps]` and
return the names promoted.

`Pkg.test` does not run in the project environment. For an old-style layout it
synthesizes a sandbox project out of `[deps]` plus the `[targets].test` names and
resolves that, and a floor this action wrote to the manifest for a name reachable
only through `[extras]`/`[weakdeps]` does not survive into the sandbox: the
sandbox installs the newest compatible version instead, so the downgrade job
tests versions it never meant to test and reports a false pass. Listing those
names in `[deps]` puts them on the path `Pkg.test` does preserve.

Only names the resolution actually placed in `manifest_file` as registry
packages are promoted. That skips `no_promote` entries (deliberately left out of
the joint floor-resolve, so they have no floor to keep) and stdlibs, and it keeps
the project from declaring a dependency the locked manifest cannot satisfy.
Path- and url-sourced names are left to `prepare_test_target_path_sources!`.
"""
function promote_test_target_registry_deps!(project_file::String, manifest_file::String)
    project = TOML.parsefile(project_file)
    test_target = get(get(project, "targets", Dict{String, Any}()), "test", String[])
    isempty(test_target) && return String[]

    deps = get(project, "deps", Dict{String, Any}())
    extras = get(project, "extras", Dict{String, Any}())
    weakdeps = get(project, "weakdeps", Dict{String, Any}())
    sources = get(project, "sources", Dict{String, Any}())
    resolved = registry_backed_manifest_entries(manifest_file)

    promoted = String[]
    for name in sort!(unique(String.(test_target)))
        haskey(deps, name) && continue
        haskey(sources, name) && continue

        # `Pkg` resolves a test target through [extras] first, then [weakdeps].
        uuid = get(extras, name, nothing)
        weak_uuid = get(weakdeps, name, nothing)
        if uuid === nothing
            uuid = weak_uuid
            uuid === nothing && continue
        elseif weak_uuid !== nothing && weak_uuid != uuid
            error(
                "Test-target dependency $name has uuid $uuid in [extras], " *
                    "but $weak_uuid in [weakdeps]"
            )
        end

        resolved_uuid = get(resolved, name, nothing)
        resolved_uuid === nothing && continue
        resolved_uuid == uuid || error(
            "Test-target dependency $name has uuid $uuid in $project_file, " *
                "but $resolved_uuid in $manifest_file"
        )
        push!(promoted, name)
    end
    isempty(promoted) && return promoted

    deps = get!(project, "deps", Dict{String, Any}())
    for name in promoted
        deps[name] = get(extras, name, get(weakdeps, name, nothing))
        # A name cannot sit in both [deps] and [weakdeps]. Dropping it here
        # matches what the merged project already did for the resolve, and the
        # extension it triggers stays declared in [extensions] and still loads.
        delete!(weakdeps, name)
    end
    isempty(weakdeps) && delete!(project, "weakdeps")

    open(project_file, "w") do io
        TOML.print(io, project)
    end
    @info "Promoted old-style test dependencies into [deps] for locked Pkg.test" promoted
    return promoted
end

"""
    collect_path_sources(project_file; include_test_target = true) -> Vector{DirectPathSource}

Collect local path packages that occur in `[sources]` and are active as runtime
dependencies or, for the root project, in `[targets].test`. Path sources of
those packages are followed recursively using runtime dependencies only.
"""
function collect_path_sources(project_file::String; include_test_target = true)
    result = DirectPathSource[]
    seen = Dict{String, DirectPathSource}()

    function visit(parent_file::String; include_test_target = false)
        parent_file = abspath(parent_file)
        parent_dir = dirname(parent_file)
        parent_project = TOML.parsefile(parent_file)
        deps = active_project_dependencies(parent_project; include_test_target)
        sources = get(parent_project, "sources", Dict{String, Any}())

        for name in sort!(collect(keys(sources)))
            haskey(deps, name) || continue
            source = sources[name]
            source isa AbstractDict || continue
            haskey(source, "path") || continue

            source_dir = normpath(abspath(joinpath(parent_dir, source["path"])))
            source_file = find_project_file(source_dir)
            source_file === nothing && error(
                "Path source $name from $parent_file has no project file at $source_dir"
            )
            source_file = abspath(source_file)
            source_project = TOML.parsefile(source_file)
            declared_name = get(source_project, "name", name)
            declared_name == name || error(
                "Path source $name from $parent_file declares package name $declared_name"
            )
            declared_uuid = get(source_project, "uuid", nothing)
            declared_uuid == deps[name] || error(
                "Path source $name from $parent_file has uuid $declared_uuid, " *
                    "expected $(deps[name])"
            )

            if haskey(seen, name)
                previous = seen[name]
                get(previous.project, "uuid", nothing) == declared_uuid || error(
                    "Path source $name resolves to different uuids"
                )
                previous.project_file == source_file || error(
                    "Path source $name resolves to both $(previous.project_file) and $source_file"
                )
                continue
            end

            path_source = DirectPathSource(name, source_project, source_file)
            seen[name] = path_source
            push!(result, path_source)
            visit(source_file)
        end
        return
    end

    visit(project_file; include_test_target)
    return result
end

"""
    test_only_path_source_dependencies(project_file; no_promote) -> Dict{String, Any}

Return hard non-local dependencies introduced by path sources that are active
only through `[targets].test`. Julia 1.11 and newer must see these as root
dependencies or `Pkg.test` resolves that test-only graph independently of the
locked manifest.
"""
function test_only_path_source_dependencies(
        project_file::String; no_promote = String[])
    all_sources = collect_path_sources(project_file; include_test_target = true)
    runtime_source_names = Set(
        source.name for source in
        collect_path_sources(project_file; include_test_target = false)
    )
    local_source_names = Set(source.name for source in all_sources)
    result = Dict{String, Any}()
    owners = Dict{String, String}()

    for source in all_sources
        source.name in runtime_source_names && continue
        for name in sort!(collect(keys(get(source.project, "deps", Dict{String, Any}()))))
            name in local_source_names && continue
            name in no_promote && continue
            uuid = source.project["deps"][name]
            if haskey(result, name) && result[name] != uuid
                error(
                    "Test-only path sources $(owners[name]) and $(source.name) require " *
                        "$name with different uuids $(result[name]) and $uuid"
                )
            end
            result[name] = uuid
            owners[name] = source.name
        end
    end
    return result
end

function parse_compat_constraint(constraint)
    # Pkg exposes no public parser or serializer for Project.toml's compat
    # grammar. The internal access is isolated here and in compat_constraint_string
    # instead of duplicating that grammar.
    return Pkg.Versions.semver_spec(constraint)
end

# A VersionBound holds up to three significant components in `t`, with `n`
# recording how many are set (`n == 0` is an unbounded end). These fields are
# stable across the Julia versions this action supports, unlike the printed form
# of a VersionSpec, whose hyphen spacing changed between 1.10 and 1.11.
compat_bound_string(bound) = join(bound.t[1:bound.n], '.')

function compat_range_string(range)
    lower, upper = range.lower, range.upper
    # A [compat] floor always has a lower bound, so intersections of real compat
    # entries never yield one without it; refuse rather than emit a spec that
    # semver_spec cannot parse back.
    lower.n == 0 && error("Cannot serialize a compat constraint with no lower bound")
    upper.n == 0 && return ">= " * compat_bound_string(lower)
    return compat_bound_string(lower) * " - " * compat_bound_string(upper)
end

function compat_constraint_string(spec)
    # Serialize each VersionRange as an explicit two-endpoint compat range read
    # from the parsed bounds, so the result round-trips through
    # parse_compat_constraint independently of how Pkg renders the spec. The
    # assertion turns any unforeseen range shape into a loud error rather than a
    # silently wrong constraint.
    constraint = join((compat_range_string(range) for range in spec.ranges), ", ")
    parse_compat_constraint(constraint) == spec || error(
        "Could not serialize intersected compat constraint $spec"
    )
    return constraint
end

function intersect_compat_constraints(left::String, right::String)
    result = intersect(parse_compat_constraint(left), parse_compat_constraint(right))
    return isempty(result) ? nothing : compat_constraint_string(result)
end

function merge_compat_constraint!(compat, name, constraint, owners)
    constraint === nothing && return
    if !haskey(compat, name)
        compat[name] = constraint
        return
    end

    existing = compat[name]
    intersection = intersect_compat_constraints(existing, constraint)
    intersection === nothing && error(
        "$owners require $name with disjoint compat entries $existing and $constraint"
    )
    compat[name] = intersection
    return
end

"""
    add_direct_path_source_dependencies!(merged, project_files)

Add hard registry dependencies that are missing from `merged` but required by a
path source active at runtime or in `[targets].test`. Dependencies already owned
by the root project keep the root UUID, and their compat is intersected with each
path source's constraint. When two path sources add the same missing dependency,
their UUIDs must agree and their compat constraints are intersected.

A path source's weak dependencies remain weak in the merged project, but their
UUIDs and compat constraints participate when another package installs them.
"""
function add_direct_path_source_dependencies!(merged, project_files::Vector{String})
    path_sources = reduce(
        vcat, collect_path_sources.(project_files);
        init = DirectPathSource[]
    )
    isempty(path_sources) && return

    deps = get!(merged, "deps", Dict{String, Any}())
    compat = get!(merged, "compat", Dict{String, Any}())
    weakdeps = get!(merged, "weakdeps", Dict{String, Any}())
    root_owned = Set(keys(deps))
    local_source_names = Set(source.name for source in path_sources)
    promoted_by = Dict{String, String}()

    for source in path_sources
        source_deps = get(source.project, "deps", Dict{String, Any}())
        source_weakdeps = get(source.project, "weakdeps", Dict{String, Any}())
        source_compat = get(source.project, "compat", Dict{String, Any}())
        for name in sort!(collect(keys(source_deps)))
            uuid = source_deps[name]
            constraint = get(source_compat, name, nothing)
            if name in local_source_names
                @info "Leaving direct path dependency $name local while reading $(source.name)"
                continue
            end

            if name in root_owned
                deps[name] == uuid || error(
                    "Root dependency $name has uuid $(deps[name]), but path source " *
                        "$(source.name) requires $uuid"
                )
                merge_compat_constraint!(
                    compat, name, constraint, "Root project and path source $(source.name)"
                )
                continue
            end

            if haskey(weakdeps, name)
                weakdeps[name] == uuid || error(
                    "Root weak dependency $name has uuid $(weakdeps[name]), but path " *
                        "source $(source.name) requires $uuid"
                )
                deps[name] = uuid
                delete!(weakdeps, name)
                isempty(weakdeps) && delete!(merged, "weakdeps")
                push!(root_owned, name)
                @info "Promoting root weak dependency required by $(source.name): $name"
                merge_compat_constraint!(
                    compat, name, constraint, "Root project and path source $(source.name)"
                )
                continue
            end

            if haskey(promoted_by, name)
                deps[name] == uuid || error(
                    "Path sources $(promoted_by[name]) and $(source.name) require " *
                        "$name with different uuids $(deps[name]) and $uuid"
                )
                merge_compat_constraint!(
                    compat, name, constraint,
                    "Path sources $(promoted_by[name]) and $(source.name)"
                )
                continue
            end

            deps[name] = uuid
            promoted_by[name] = source.name
            if constraint !== nothing
                if haskey(compat, name) && compat[name] != constraint
                    error(
                        "Project compat for promoted dependency $name is $(compat[name]), " *
                            "but path source $(source.name) requires $constraint"
                    )
                end
                compat[name] = constraint
            end
            @info "Adding runtime dependency from direct path source $(source.name): $name"
        end

        for name in sort!(collect(keys(source_weakdeps)))
            name in local_source_names && continue

            uuid = source_weakdeps[name]
            if haskey(deps, name)
                deps[name] == uuid || error(
                    "Dependency $name has uuid $(deps[name]), but path source " *
                        "$(source.name) requires weak dependency $uuid"
                )
            elseif haskey(weakdeps, name)
                weakdeps[name] == uuid || error(
                    "Weak dependency $name has uuid $(weakdeps[name]), but path source " *
                        "$(source.name) requires $uuid"
                )
            else
                weakdeps[name] = uuid
            end
            merge_compat_constraint!(
                compat, name, get(source_compat, name, nothing),
                "Project and path source $(source.name)"
            )
        end
    end
    isempty(weakdeps) && delete!(merged, "weakdeps")
    return
end

"""
    create_merged_project(main_project_file, test_project_file, merged_dir)

Create a merged Project.toml that combines dependencies from both the main
project and test project. This ensures that when tests run (which combine
both environments), the resolved versions are compatible.

Returns the source packages excluded from the merge.
"""
function create_merged_project(main_project_file::String, test_project_file::String, merged_dir::String;
        no_promote = String[])
    main_project = TOML.parsefile(main_project_file)
    test_project = TOML.parsefile(test_project_file)

    # Get source packages from both projects (e.g., the main package itself)
    source_pkgs = get_source_packages(main_project_file)
    if main_project_file != test_project_file
        union!(source_pkgs, get_source_packages(test_project_file))
    end

    # Start with a copy of the main project
    merged = deepcopy(main_project)

    # Remove workspace section (not needed for resolution)
    delete!(merged, "workspace")

    # Strip in-tree [sources] path/url packages from the merged project. They are
    # not registered, so if they remain in [deps]/[compat]/[sources] the resolver
    # errors "unknown package UUID: ..." (e.g. a monorepo root whose [deps] are its
    # own unregistered lib/* sources). The merge logic below already skips ADDING
    # source packages from extras/test-deps, but a source package listed directly
    # in the main project's [deps] (a monorepo root depending on its siblings)
    # would otherwise survive the deepcopy. They are re-added to the manifest as
    # path deps after resolution (add_source_packages_to_manifest).
    for section_name in ("deps", "compat", "sources")
        if haskey(merged, section_name)
            for pkg in source_pkgs
                delete!(merged[section_name], pkg)
            end
            isempty(merged[section_name]) && delete!(merged, section_name)
        end
    end

    # Merge extras from main project into deps (old-style test dependencies)
    # This ensures that even in the "new style" with test/Project.toml, any
    # legacy extras in the root project that might still be used are included.
    # For the "old style" case where test_project_file == main_project_file,
    # this is where the test dependencies are actually added to [deps].
    if haskey(main_project, "extras")
        deps = get!(merged, "deps", Dict{String, Any}())
        for (pkg, uuid) in main_project["extras"]
            if pkg ∉ source_pkgs
                # An extra named in `no_promote` is NOT promoted into the merged
                # [deps], so it is excluded from the joint floor-resolve. A weakdep
                # extra stays a weakdep; a pure test extra stays in [extras]; either
                # way it is installed at latest and never force-min-resolved. Used to
                # exclude a backend that is currently unresolvable on its own (e.g.
                # Mooncake); every other extension is still promoted and floor-tested
                # together. (Not gated on [weakdeps] membership: some repos list an AD
                # backend only in [extras]/[targets].test with no [weakdeps] section.)
                if pkg in no_promote
                    @info "Not promoting $pkg into merged [deps] (listed in no_promote)"
                    continue
                end

                if !haskey(deps, pkg)
                    deps[pkg] = uuid
                    @info "Adding main project extra to merged project: $pkg"
                end

                if haskey(merged, "weakdeps") && haskey(merged["weakdeps"], pkg)
                    delete!(merged["weakdeps"], pkg)
                    @info "Promoting $pkg from weakdep to dependency in merged project"
                end
            end
        end
    end

    # Merge deps from test project (excluding source packages)
    # If a package is weak in main but strong in test, promote it to strong
    # in the merged project by removing it from weakdeps.
    if main_project_file != test_project_file
        test_deps = get(test_project, "deps", Dict())
        if !haskey(merged, "deps")
            merged["deps"] = Dict{String, Any}()
        end
        for (pkg, uuid) in test_deps
            if pkg ∉ source_pkgs
                if !haskey(merged["deps"], pkg)
                    merged["deps"][pkg] = uuid
                    @info "Adding test dependency to merged project: $pkg"
                end

                if haskey(merged, "weakdeps") && haskey(merged["weakdeps"], pkg)
                    delete!(merged["weakdeps"], pkg)
                    @info "Promoting $pkg from weakdep to dependency in merged project"
                end
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
    end

    # Remove empty [weakdeps] section after promotions
    if haskey(merged, "weakdeps") && isempty(merged["weakdeps"])
        delete!(merged, "weakdeps")
    end

    project_files = main_project_file == test_project_file ?
                    [main_project_file] : [main_project_file, test_project_file]
    add_direct_path_source_dependencies!(merged, project_files)

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
    normalized = unique(normpath.(dirs))
    normalized_set = Set(normalized)

    # Keep the existing root workspace behavior, but also support nested
    # subpackages where the test environment lives in a sibling `test/` dir.
    if "." in normalized_set && "test" in normalized_set
        return (true, ".", "test")
    end

    for test_dir in normalized
        basename(test_dir) == "test" || continue

        main_dir = dirname(test_dir)
        main_dir in normalized_set || continue

        return (true, main_dir, test_dir)
    end

    return (false, nothing, nothing)
end

"""
    remove_manifest_entries_by_uuid!(manifest, uuid)

Remove from a parsed manifest any package stanza whose `uuid` equals `uuid`,
returning the names of the packages that were removed. Handles both manifest
formats: Julia ≥1.7 manifests nest the package tables under a top-level `deps`
table, while older (≤1.6) manifests place them directly at the top level. Only
entries matching `uuid` are touched; everything else is left intact.
"""
function remove_manifest_entries_by_uuid!(manifest::AbstractDict, uuid::AbstractString)
    # In ≥1.7 manifests the per-package arrays live under `deps`; in ≤1.6 they
    # live at the top level alongside metadata keys like `julia_version`.
    deps = get(manifest, "deps", manifest)
    removed = String[]
    for (name, entries) in collect(deps)
        # Skip metadata scalars present in old-style top-level manifests.
        entries isa AbstractVector || continue
        if any(e -> e isa AbstractDict && get(e, "uuid", nothing) == uuid, entries)
            delete!(deps, name)
            push!(removed, name)
        end
    end
    return removed
end

function path_manifest_entry(project, path)
    entry = Dict{String, Any}(
        "path" => path,
        "uuid" => project["uuid"],
    )

    hard_deps = sort!(collect(keys(get(project, "deps", Dict{String, Any}()))))
    isempty(hard_deps) || (entry["deps"] = hard_deps)

    for section in ("extensions", "weakdeps")
        metadata = get(project, section, nothing)
        metadata isa AbstractDict && !isempty(metadata) &&
            (entry[section] = deepcopy(metadata))
    end

    version = get(project, "version", nothing)
    version === nothing || (entry["version"] = version)
    return entry
end

function replace_manifest_path_entry!(manifest, pkg_name, project, path)
    uuid = project["uuid"]
    removed = remove_manifest_entries_by_uuid!(manifest, uuid)
    deps = get(manifest, "deps", manifest)
    haskey(deps, pkg_name) && pkg_name ∉ removed && push!(removed, pkg_name)
    deps[pkg_name] = [path_manifest_entry(project, path)]
    return removed
end

"""
    add_main_package_to_manifest(manifest_file, main_project_file)

Add the main package itself to the manifest as a path dependency.
This is needed because the main package is excluded from resolution
(it's a local source), but the manifest needs to include it for
workspace projects to work correctly.

If the resolver already emitted a registry entry for the main package, that
entry is removed first. This happens in the merged-resolution path whenever a
test extra transitively depends on the main package (e.g. LinearSolve's test
extra AlgebraicMultigrid depends on LinearSolve): the merged resolve installs
the main package from the registry, so blindly appending the path stanza would
leave two `[[deps.<MainPkg>]]` entries with the same name and uuid. Pkg then
rejects the manifest with "Invalid manifest format: ...'s dependency on
<MainPkg> is ambiguous". The path entry must win, since the main package is
sourced locally, not from the registry. The replacement entry retains the
package's dependency, weak-dependency, and extension metadata so Pkg can load
extensions without refreshing the locked manifest.
"""
function add_main_package_to_manifest(
        manifest_file::String, main_project_file::String; path::String = ".")
    if !isfile(manifest_file)
        @warn "Manifest file not found: $manifest_file"
        return
    end

    main_project = TOML.parsefile(main_project_file)

    # Get main package info
    pkg_name = get(main_project, "name", nothing)
    pkg_uuid = get(main_project, "uuid", nothing)
    if pkg_name === nothing || pkg_uuid === nothing
        @warn "Main project missing name or uuid, cannot add to manifest"
        return
    end

    manifest = TOML.parsefile(manifest_file)
    removed = replace_manifest_path_entry!(manifest, pkg_name, main_project, path)
    if !isempty(removed)
        @info "Removed resolver-emitted registry entry for main package $pkg_name"
    end

    open(manifest_file, "w") do io
        TOML.print(io, manifest; sorted = true)
    end

    return @info "Added main package $pkg_name to manifest"
end

"""
    set_manifest_project_hash(manifest_file, project_file)

Update `project_hash` in `manifest_file` so it matches what Pkg expects for
`project_file`. This avoids spurious "project dependencies changed" warnings
and test-time re-resolution in downstream actions.
"""
function set_manifest_project_hash(manifest_file::String, project_file::String)
    if !isfile(manifest_file)
        @warn "Manifest file not found: $manifest_file"
        return
    end
    if !isfile(project_file)
        @warn "Project file not found: $project_file"
        return
    end

    manifest = TOML.parsefile(manifest_file)
    env = Pkg.Types.EnvCache(project_file)

    resolve_hash = if isdefined(Pkg.Types, :workspace_resolve_hash)
        Pkg.Types.workspace_resolve_hash(env)
    elseif isdefined(Pkg.Types, :project_resolve_hash)
        Pkg.Types.project_resolve_hash(env.project)
    else
        error("Could not compute project hash: no supported Pkg.Types hash API found")
    end

    manifest["project_hash"] = string(resolve_hash)

    open(manifest_file, "w") do io
        TOML.print(io, manifest)
    end

    @info "Updated project_hash in $manifest_file to match $project_file"
end

"""
    add_source_packages_to_manifest(manifest_file, project_file, manifest_dir, source_pkgs)

Re-add local path-sourced packages to `manifest_file` after resolution.

The resolver runs with these packages removed from the project (they cannot be
resolved from the registry), so they are absent from the resulting manifest even
though they remain in the project's `[deps]`. Without this, the build step fails
with errors like "expected package X to be listed in the manifest" / "X is listed
in Project.toml but absent from Manifest.toml" (see #3021). Each such package is
written back as a path dependency pointing at the same location given in
`[sources]`, mirroring `add_main_package_to_manifest`. Dependency,
weak-dependency, and extension metadata is copied from each source project.

Packages sourced solely for `[targets].test` are included when this manifest was
produced from the merged test environment. Active nested path sources are
included recursively.

If the resolver already emitted a registry entry for a source package (which
happens whenever another resolved package depends on it), that entry is removed
first — appending without removal would leave two `[[deps.X]]` entries with the
same name and Pkg rejects the manifest with "Invalid manifest format: X's
dependency on ... is ambiguous". The path source must win, since that is the
whole point of the `[sources]` override.
"""
function add_source_packages_to_manifest(
        manifest_file::String, project_file::String, manifest_dir::AbstractString, source_pkgs;
        include_test_target = false
    )
    isempty(source_pkgs) && return
    if !isfile(manifest_file)
        @warn "Manifest file not found: $manifest_file"
        return
    end

    path_sources = collect_path_sources(project_file; include_test_target)
    isempty(path_sources) && return
    manifest_dir = abspath(manifest_dir)

    added_pkgs = String[]
    manifest = TOML.parsefile(manifest_file)
    manifest_deps = get(manifest, "deps", manifest)
    for source in path_sources
        pkg = source.name
        source_path = dirname(source.project_file)
        pkg_path = relpath(source_path, manifest_dir)
        uuid = get(source.project, "uuid", nothing)
        if uuid === nothing
            @warn "Could not determine uuid for source package $pkg, skipping manifest entry"
            continue
        end

        had_registry_entry = haskey(manifest_deps, pkg)
        replace_manifest_path_entry!(manifest, pkg, source.project, pkg_path)
        had_registry_entry &&
            @info "Removed resolver-emitted registry entry for source package $pkg"
        push!(added_pkgs, pkg)
        @info "Added source package $pkg to manifest as a path dependency"
    end
    isempty(added_pkgs) && return
    return open(manifest_file, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
end

"""
    resolve_directory(dir, resolver_path, resolver_mode, julia_version, mode, ignore_pkgs, no_promote)

Resolve dependencies for a single directory. Source packages are omitted from a
temporary merged project and restored to the resolved manifest as path entries.
Returns the source packages found in the directory (for use in forcedeps checking).
"""
function resolve_directory(
        dir::AbstractString, resolver_path::AbstractString, resolver_mode::AbstractString,
        julia_version::AbstractString, mode::AbstractString, ignore_pkgs,
        no_promote = String[])
    project_files = [joinpath(dir, "Project.toml"), joinpath(dir, "JuliaProject.toml")]
    filter!(isfile, project_files)
    isempty(project_files) &&
        error("could not find Project.toml or JuliaProject.toml in $dir")

    project_file = first(project_files)
    manifest_file = joinpath(dir, "Manifest.toml")
    project = TOML.parsefile(project_file)

    has_test_target = haskey(project, "targets") && haskey(project["targets"], "test")
    has_test_dependencies = haskey(project, "extras") || haskey(project, "weakdeps")
    if has_test_target && has_test_dependencies
        @info "Project $dir has test dependencies and [targets].test, using merged resolution"
        merged_dir = mktempdir()
        source_pkgs = create_merged_project(
            project_file, project_file, merged_dir; no_promote)

        try
            @info "Running resolver on merged project (extras) for $dir with --min=@$resolver_mode"
            run(`$(Base.julia_cmd()) --project=$resolver_path/bin $resolver_path/bin/resolve.jl $merged_dir --min=@$resolver_mode --julia=$julia_version`)
            @info "Successfully resolved minimal versions for $dir (with extras)"

            # Copy manifest back to the project directory
            merged_manifest = joinpath(merged_dir, "Manifest.toml")
            if isfile(merged_manifest)
                cp(merged_manifest, manifest_file; force = true)

                # Add the main package itself and other source packages back to the manifest
                prepare_test_target_path_sources!(
                    project_file;
                    registry_deps = test_only_path_source_dependencies(
                        project_file; no_promote
                    )
                )
                promote_test_target_registry_deps!(project_file, manifest_file)
                add_main_package_to_manifest(manifest_file, project_file; path = ".")
                if !isempty(source_pkgs)
                    add_source_packages_to_manifest(
                        manifest_file, project_file, dir, source_pkgs;
                        include_test_target = true
                    )
                end
                set_manifest_project_hash(manifest_file, project_file)
            end
        finally
            rm(merged_dir, recursive = true)
        end
    else
        source_pkgs = get_source_packages(project_file)
        if isempty(source_pkgs)
            @info "Running resolver on $dir with --min=@$resolver_mode"
            run(`$(Base.julia_cmd()) --project=$resolver_path/bin $resolver_path/bin/resolve.jl $dir --min=@$resolver_mode --julia=$julia_version`)
            @info "Successfully resolved minimal versions for $dir"
        else
            merged_dir = mktempdir()
            source_pkgs = create_merged_project(
                project_file, project_file, merged_dir; no_promote
            )
            try
                @info "Running resolver on $dir with path-source constraints and --min=@$resolver_mode"
                run(`$(Base.julia_cmd()) --project=$resolver_path/bin $resolver_path/bin/resolve.jl $merged_dir --min=@$resolver_mode --julia=$julia_version`)
                @info "Successfully resolved minimal versions for $dir with path-source constraints"
                merged_manifest = joinpath(merged_dir, "Manifest.toml")
                isfile(merged_manifest) && cp(merged_manifest, manifest_file; force = true)
            finally
                rm(merged_dir, recursive = true)
            end

            add_source_packages_to_manifest(manifest_file, project_file, dir, source_pkgs)
        end
        set_manifest_project_hash(manifest_file, project_file)
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
    versions_match_ignoring_build(actual, expected)

Return true if two versions are equal, ignoring SemVer build metadata
(the `+...` suffix). This allows `1.2.3` and `1.2.3+4` to match.
"""
function versions_match_ignoring_build(actual::VersionNumber, expected::VersionNumber)
    return actual.major == expected.major &&
           actual.minor == expected.minor &&
           actual.patch == expected.patch &&
           actual.prerelease == expected.prerelease
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
        if !versions_match_ignoring_build(actual, expected)
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
    @info "Merging main and test projects for combined resolution" main_dir test_dir

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
    source_pkgs = create_merged_project(
        main_project_file, test_project_file, merged_dir; no_promote)

    # Run resolver on merged project
    @info "Running resolver on merged project with --min=@$resolver_mode"
    run(`$(Base.julia_cmd()) --project=$resolver_path/bin $resolver_path/bin/resolve.jl $merged_dir --min=@$resolver_mode --julia=$julia_version`)
    @info "Successfully resolved minimal versions for merged project"

    # Copy manifest to main project directory
    merged_manifest = joinpath(merged_dir, "Manifest.toml")
    main_manifest = joinpath(main_dir, "Manifest.toml")
    test_manifest = joinpath(test_dir, "Manifest.toml")
    if isfile(merged_manifest)
        cp(merged_manifest, main_manifest; force = true)
        @info "Copied merged manifest to $main_manifest"

        cp(merged_manifest, test_manifest; force = true)
        @info "Copied merged manifest to $test_manifest"

        prepare_test_target_path_sources!(
            main_project_file;
            registry_deps = test_only_path_source_dependencies(
                main_project_file; no_promote
            )
        )
        prepare_test_target_path_sources!(
            test_project_file;
            registry_deps = test_only_path_source_dependencies(
                test_project_file; no_promote
            )
        )
        main_source_pkgs = get_source_packages(main_project_file)
        test_source_pkgs = get_source_packages(test_project_file)
        for (manifest, manifest_dir) in (
                (main_manifest, main_dir), (test_manifest, test_dir)
            )
            add_source_packages_to_manifest(
                manifest, main_project_file, manifest_dir, main_source_pkgs;
                include_test_target = true
            )
            add_source_packages_to_manifest(
                manifest, test_project_file, manifest_dir, test_source_pkgs;
                include_test_target = true
            )
        end
        # Add this last because test/Project.toml commonly lists the main
        # package as a path source, which would otherwise replace this entry.
        add_main_package_to_manifest(main_manifest, main_project_file; path = ".")
        add_main_package_to_manifest(test_manifest, main_project_file; path = "..")
        # Ensure each manifest has the project hash corresponding to the project
        # that will consume it (main root and test environment respectively).
        set_manifest_project_hash(main_manifest, main_project_file)
        set_manifest_project_hash(test_manifest, test_project_file)
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

    # Process any remaining directories that weren't part of the merged pair.
    # For nested subpackages, the merged main/test paths are not "."/"test", so
    # compare normalized paths rather than filtering only the root names.
    other_dirs = filter(d -> normpath(d) != main_dir && normpath(d) != test_dir, dirs)
    for dir in other_dirs
        resolve_directory(
            dir, resolver_path, resolver_mode, julia_version, mode, ignore_pkgs, no_promote)
    end
else
    # Independent resolution: process each directory separately
    for dir in dirs
        resolve_directory(
            dir, resolver_path, resolver_mode, julia_version, mode, ignore_pkgs, no_promote)
    end
end
