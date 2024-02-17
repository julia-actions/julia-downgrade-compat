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
```

## Example

For example, here is the action being used as part of a standard Julia test workflow:
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
          skip: Pkg,TOML
      - uses: julia-actions/julia-buildpkg@v1
      - uses: julia-actions/julia-runtest@v1
```

The action requires Julia to be installed, so must occur after `setup-julia`. It runs just
before `julia-buildpkg` so that the Project.toml is modified before installing any packages.

In this example, we are running the test suite with the latest version of Julia 1.* and
also Julia 1.6, corresponding to `matrix.version`. The `if:` entry only runs the downgrade
action when it is Julia 1.6 running. This means we get one run using latest Julia 1.* and
latest packages, and one run using Julia 1.6 and old packages.

The `skip:` input says that we should not attempt to downgrade `Pkg` or `TOML`.

## Supported compat entries

Compats like `1`, `1.2`, `1.2.3`, `^1.2.3`, `~1.2.3`, `=1.2.3`, `1.2.3, 2.3.4` are all supported.

Compats like `1.2.3 - 1.2.5` are not supported.

For list compats like `1.2.3, 2.3.4`, all but the first entry is ignored. Therefore you should put the lowest entry first.
