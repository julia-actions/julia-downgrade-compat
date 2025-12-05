# julia-downgrade-compat

[![Project Status: Active – The project has reached a stable, usable state and is being actively developed.](https://www.repostatus.org/badges/latest/active.svg)](https://www.repostatus.org/#active)
[![Tests](https://github.com/julia-actions/julia-downgrade-compat/actions/workflows/tests.yml/badge.svg)](https://github.com/julia-actions/julia-downgrade-compat/actions/workflows/tests.yml)

**Accurate checking of compat lower bounds in your Julia package using Resolver.jl.**

Did you set your compat entries a long time ago? Are you sure they are still accurate?

This GitHub action uses Resolver.jl's advanced SAT-based resolver to find and install the minimal
compatible versions of your dependencies. This provides accurate testing of your compat bounds
by finding actual resolutions that respect all constraints, rather than just modifying Project.toml entries.

For example, suppose your Project.toml has this compat entry:
```toml
[compat]
julia = "1.6"
Foo = "1.2.3"
Bar = "0.1.2"
```

Often these compat entries get forgotten about once set. For instance, suppose the latest
version of Foo is v1.4.0, and your package now relies on some feature of Foo v1.4 that is
not present in Foo v1.2. Your package tests will still succeed, because by default they run
with the latest versions of all dependencies, including Foo v1.4. This is because [Pkg.jl treats](https://pkgdocs.julialang.org/v1/compatibility/#Caret-specifiers) `"1.2.3"` is the same as `"^1.2.3"`, which allows the range of `[1.2.3, 2.0.0)`

This action uses Resolver.jl to find the actual minimal versions that satisfy all constraints,
creating a Manifest.toml with these minimal versions. When your tests run, they'll use these
minimal versions and fail if your compat bounds are too low.

## Usage

```yaml
- uses: julia-actions/julia-downgrade-compat@v2
  with:
    # Comma-separated list of packages to not downgrade. This should include any
    # standard libraries because these have versions tied to the Julia version.
    # This option is only used with `mode: 'forcedeps'`.
    # Example: Pkg, TOML
    # Default: ''
    skip: ''

    # Comma-separated list of Julia projects to resolve.
    # Example: ., test, docs
    # Default: .
    projects: '.'

    # Downgrade mode: 'deps' (direct dependencies), 'alldeps' (deps + weakdeps),
    # 'weakdeps' (only weakdeps), 'forcedeps' (deps with strict lower bound verification)
    # Default: 'alldeps'
    mode: 'alldeps'

    # Julia version to use with resolver (requires Julia 1.9+)
    # Default: '1.10'
    julia_version: '1.10'
```

## Example

Here is the action being used as part of a Julia test workflow:

```yaml
jobs:
  test:
    strategy:
      matrix:
        downgrade_mode: ['deps', 'alldeps']
        julia-version: ['1.10', '1']
    steps:
      - uses: actions/checkout@v4
      - uses: julia-actions/setup-julia@v2
        with:
          version: ${{ matrix.julia-version }}
      - uses: julia-actions/julia-downgrade-compat@v2
        with:
          mode: ${{ matrix.downgrade_mode }}
      - uses: julia-actions/julia-buildpkg@v1
      - uses: julia-actions/julia-runtest@v1
        with:
          allow_reresolve: false
          force_latest_compatible_version: false
```

The action requires Julia to be installed, so must occur after `setup-julia`. It runs just
before `julia-buildpkg` so that Resolver.jl creates a Manifest.toml with minimal versions before installing packages.

In this example, we test both `deps` (direct dependencies only) and `alldeps` (deps + weakdeps) scenarios.

## Downgrade Modes

- **`deps`**: Minimize only your direct dependencies (recommended for most packages)
- **`alldeps`**: Minimize direct dependencies and weak dependencies
- **`weakdeps`**: Minimize only weak dependencies
- **`forcedeps`**: Like `deps`, but also verifies that the resolved versions exactly match the lower bounds from your compat entries. If any package resolves to a higher version (because the lower bounds are mutually incompatible), the action will fail with an error indicating which compat bounds need to be increased.

**Recommendation**: Use `deps` mode for most packages as it focuses on testing your actual compat bounds without being affected by issues in transitive dependencies that you can't control.

### When to use `forcedeps`

The `forcedeps` mode is useful when you want strict verification that your compat lower bounds are mutually compatible. This provides behavior similar to v1 of this action.

For example, suppose you have:
```toml
[compat]
Foo = "1"
Bar = "1"
```

With `deps` mode, if Foo v1.0.0 is incompatible with Bar v1.0.0, the resolver will find an alternative solution like Foo v1.0.0 + Bar v1.1.0. Your tests will pass, but you won't know that your stated lower bounds are incompatible.

With `forcedeps` mode, the action will error because Bar resolved to v1.1.0 instead of v1.0.0. This tells you that you need to update your compat to `Bar = "1.1"` to accurately reflect the minimum compatible version.

Note that, when you use `forcedeps`, you usually need to `skip` the stdlibs.

## How it works

This action uses Resolver.jl's advanced SAT-based resolver to find actual minimal versions that satisfy all package constraints. Unlike simple compat modification approaches, Resolver.jl ensures that the resolved versions form a valid, installable dependency tree.

The resolver respects all compat entries in your project and finds the minimal versions that still satisfy all constraints, providing more accurate testing of your actual compatibility bounds.
