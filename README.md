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
with the latest versions of all dependencies, including Foo v1.4.

This action uses Resolver.jl to find the actual minimal versions that satisfy all constraints,
creating a Manifest.toml with these minimal versions. When your tests run, they'll use these
minimal versions and fail if your compat bounds are too low.

## Usage

```yaml
- uses: julia-actions/julia-downgrade-compat@v2
  with:
    # Comma-separated list of packages to not downgrade. This should include any
    # standard libraries because these have versions tied to the Julia version.
    # Example: Pkg, TOML
    # Default: ''
    skip: ''

    # Comma-separated list of Julia projects to resolve.
    # Example: ., test, docs
    # Default: .
    projects: ''

    # Downgrade mode: 'deps' (direct dependencies), 'alldeps' (deps + weakdeps), 'all' (all packages)
    # Default: 'alldeps'
    mode: ''

    # Julia version to use with resolver (requires Julia 1.9+)
    # Default: '1.10'
    julia_version: ''
```

## Example

Here is the action being used as part of a Julia test workflow:

```yaml
jobs:
  test:
    strategy:
      matrix:
        downgrade_mode: ['alldeps']
        julia-version: ['1.10', '1']
    steps:
      - uses: actions/checkout@v4
      - uses: julia-actions/setup-julia@v1
        with:
          version: ${{ matrix.julia-version }}
      - uses: julia-actions/julia-downgrade-compat@v2
        with:
          mode: ${{ matrix.downgrade_mode }}
          skip: Pkg, TOML
      - uses: julia-actions/julia-buildpkg@v1
      - uses: julia-actions/julia-runtest@v1
        with:
          ALLOW_RERESOLVE: false
```

The action requires Julia to be installed, so must occur after `setup-julia`. It runs just
before `julia-buildpkg` so that Resolver.jl creates a Manifest.toml with minimal versions before installing packages.

In this example, we test both `deps` (direct dependencies only) and `alldeps` (deps + weakdeps) scenarios. 

The `skip:` input says that we should not attempt to downgrade `Pkg` or `TOML`.

## Downgrade Modes

- **`deps`**: Minimize only your direct dependencies (recommended for most packages)
- **`alldeps`**: Minimize direct dependencies and weak dependencies 
- **`all`**: Minimize all packages (may test issues in transitive dependencies)

**Recommendation**: Use `deps` mode for most packages as it focuses on testing your actual compat bounds without being affected by issues in transitive dependencies that you can't control.

## How it works

This action uses Resolver.jl's advanced SAT-based resolver to find actual minimal versions that satisfy all package constraints. Unlike simple compat modification approaches, Resolver.jl ensures that the resolved versions form a valid, installable dependency tree.

The resolver respects all compat entries in your project and finds the minimal versions that still satisfy all constraints, providing more accurate testing of your actual compatibility bounds.
