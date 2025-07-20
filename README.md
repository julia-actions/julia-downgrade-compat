# julia-downgrade-compat

[![Project Status: Active – The project has reached a stable, usable state and is being actively developed.](https://www.repostatus.org/badges/latest/active.svg)](https://www.repostatus.org/#active)
[![Tests](https://github.com/julia-actions/julia-downgrade-compat/actions/workflows/tests.yml/badge.svg)](https://github.com/julia-actions/julia-downgrade-compat/actions/workflows/tests.yml)

**Easy-peasy checking of compat lower bounds in your Julia package.**

Did you set your compat entries a long time ago? Are you sure they are still accurate?

This GitHub action does one simple thing: it modifies Project.toml so that that oldest
compatible versions of dependencies get installed, instead of the newest. When used as part
of a testing workflow, this can check that your compat lower bounds are correct.

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

This action will modify the compat to:
```toml
[compat]
julia = "1.6"
Foo = "~1.2.3"
Bar = "=0.1.2"
```

Now your package tests will run against Foo v1.2 and fail, indicating that the compat lower
bounds are too low.

## Usage

```yaml
- uses: julia-actions/julia-downgrade-compat@v1
  with:
    # Comma-separated list of packages to not downgrade. This should include any
    # standard libraries because these have versions tied to the Julia version.
    # Example: Pkg, TOML
    # Default: ''
    skip: ''

    # When strict, a compat entry like "1.2.3" becomes "=1.2.3" so that exactly
    # v1.2.3 is installed. When not strict, it becomes "~1.2.3" so that patch
    # upgrades are allowed (v1.2.*). This entry can be 'true' (strict), 'false'
    # (not strict) or 'v0' (strict for "0.*.*" and not strict otherwise).
    # Default: 'v0'
    strict: ''

    # Comma-separated list of Julia projects to modify. The Project.toml files in all of
    # these directories will be modified.
    # Example: ., test, docs
    # Default: .
    projects: ''

    # Use Resolver.jl for more accurate downgrade resolution.
    # Options: 'false' (use traditional compat modification), 'deps' (minimize direct deps),
    # 'alldeps' (minimize deps + weakdeps), 'all' (minimize all packages)
    # Default: 'false'
    use_resolver: ''

    # Julia version to use with the resolver (requires Julia 1.9+)
    # Default: '1.11'
    resolver_julia_version: ''
```

## Examples

### Traditional compat-based downgrade testing

Here is the action being used as part of a standard Julia test workflow:
```yaml
jobs:
  test:
    strategy:
      matrix:
        version: ['1', '1.6']
    steps:
      - uses: actions/checkout@v4
      - uses: julia-actions/setup-julia@v1
        with:
          version: ${{ matrix.version }}
      - uses: julia-actions/julia-downgrade-compat@v1
        if: ${{ matrix.version == '1.6' }}
        with:
          skip: Pkg, TOML
      - uses: julia-actions/julia-buildpkg@v1
      - uses: julia-actions/julia-runtest@v1
```

### Advanced resolver-based downgrade testing

For more accurate downgrade testing using Resolver.jl:
```yaml
jobs:
  test:
    strategy:
      matrix:
        downgrade_mode: ['deps', 'alldeps']
    steps:
      - uses: actions/checkout@v4
      - uses: julia-actions/setup-julia@v1
        with:
          version: '1.11'
      - uses: julia-actions/julia-downgrade-compat@v1
        with:
          use_resolver: ${{ matrix.downgrade_mode }}
          skip: Pkg, TOML
      - uses: julia-actions/julia-buildpkg@v1
      - uses: julia-actions/julia-runtest@v1
```

The action requires Julia to be installed, so must occur after `setup-julia`. It runs just
before `julia-buildpkg` so that the Project.toml is modified or resolved before installing any packages.

In the traditional example, we run the test suite with the latest version of Julia 1.* and
also Julia 1.6. The `if:` entry only runs the downgrade action when it is Julia 1.6 running.

In the resolver example, we test both `deps` (direct dependencies only) and `alldeps` (deps + weakdeps) scenarios. This provides more targeted testing of your actual compat bounds without being affected by transitive dependency issues.

The `skip:` input says that we should not attempt to downgrade `Pkg` or `TOML`.

## Traditional vs Resolver-based Approaches

### Traditional Approach (default)
- Modifies compat entries in Project.toml to force installation of older versions
- Simple and fast, but may not always find a valid resolution
- Tests the literal bounds you specify, but not necessarily what users will actually get
- May fail if older versions have incompatible dependencies

### Resolver-based Approach (use_resolver)
- Uses Resolver.jl's advanced SAT-based resolver for accurate downgrade resolution
- Finds actual minimal versions that satisfy all constraints
- Options:
  - `deps`: Minimize only your direct dependencies (recommended)
  - `alldeps`: Minimize direct dependencies and weak dependencies 
  - `all`: Minimize all packages (may test issues in transitive dependencies)
- More accurate representation of what users with conservative package managers will get
- Automatically handles Julia version selection as part of resolution

**Recommendation**: Use `deps` mode for most packages as it focuses on testing your actual compat bounds without being affected by issues in transitive dependencies that you can't control.

## Supported compat entries

Compats like `1`, `1.2`, `1.2.3`, `^1.2.3`, `~1.2.3`, `=1.2.3`, `1.2.3, 2.3.4` are all supported.

Compats like `1.2.3 - 1.2.5` are not supported.

For list compats like `1.2.3, 2.3.4`, all but the first entry is ignored. Therefore you should put the lowest entry first.
