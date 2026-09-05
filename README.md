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
    # This option is only used with `mode: 'forcedeps'`.
    # Example: Pkg, TOML
    # Default: ''
    skip: ''

    # Comma-separated list of Julia projects to resolve.
    # Example: ., test
    # Default: .
    projects: '.'

    # Downgrade mode: 'deps' (direct dependencies), 'alldeps' (deps + weakdeps),
    # 'weakdeps' (only weakdeps), 'forcedeps' (deps with strict lower bound verification)
    # Default: 'alldeps'
    mode: 'alldeps'

    # Julia version to use with resolver (requires Julia 1.9+)
    # Default: '1' (converted to current runtime Julia major.minor)
    # Channel aliases are also accepted and resolve to the version they
    # denote: 'lts' / 'release' (from the juliaup version database),
    # 'pre' (latest version including prereleases), 'min' (the project's
    # julia compat lower bound), 'nightly' / '1.12-nightly' (current
    # runtime Julia / the alias's numeric prefix).
    julia_version: '1'
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

### Julia versions before 1.12

On Julia `< 1.12`, `Pkg.test` may still re-resolve package versions for split test environments
(for example when using both `Project.toml` and `test/Project.toml`), even with
`allow_reresolve: false` in `julia-actions/julia-runtest`.

For strict lower-bound testing on Julia `< 1.12`, run tests manually from the locked test
environment instead of using `julia-actions/julia-runtest`:

```yaml
- uses: julia-actions/julia-downgrade-compat@v2
  with:
    skip: LinearAlgebra,Printf,SparseArrays,DelimitedFiles,Test
    projects: .,test
    mode: forcedeps
- name: Run tests
  run: |
    julia --project=test --color=yes -e '
      import Pkg
      Pkg.develop(Pkg.PackageSpec(path=pwd()))
      Pkg.instantiate()
      Pkg.status(; mode=Pkg.PKGMODE_MANIFEST)
      include("test/runtests.jl")
    '
```

For Julia `>= 1.12`, using `julia-actions/julia-runtest` with
`allow_reresolve: false` and `force_latest_compatible_version: false` is recommended.

When possible, run the action on the same Julia version that you pass as `julia_version`.
Cross-runtime resolution may fail; matching runtime and target version is recommended and the default for `julia_version`.

### Local path sources

For a dependency configured with `[sources]` and `path`, including one selected
only by `[targets].test`, the action includes hard registry dependencies that
are declared by the local package but missing from the active project in the
minimum-version resolution. It follows active path sources recursively, so
local monorepo dependencies remain local throughout the locked build and test.
Dependencies already declared by the active project retain their UUID and have
their compat intersected with the local packages' constraints. If the root and
local constraints, or constraints from two local packages, do not overlap, the
action reports the conflict before producing a locked manifest.

When a local path package appears only in `[targets].test`, Julia 1.11 and newer
honor its `[sources]` entry but resolve its dependency graph independently while
constructing the `Pkg.test` sandbox. This can upgrade a dependency above the
locked minimum even with `allow_reresolve=false`. The action therefore promotes
the test-only path graph's hard non-local dependencies to root `[deps]` in the
checkout. The local package itself remains a test dependency. A weak-only test
source is added to `[extras]` because Pkg requires every `[sources]` entry to
appear in `[deps]` or `[extras]`; its `[weakdeps]` entry remains intact.

Julia 1.10 and earlier do not honor `[sources]` while constructing the
`Pkg.test` sandbox. On those versions, the action also promotes test-only path
packages to `[deps]` in the checkout so the locked test can use them. Weak-only
test packages are also removed from `[weakdeps]` as part of that compatibility
fallback.

These promotions intentionally leave `Project.toml` modified for subsequent
locked build and test steps.

This support does not promote path-package weak dependencies.

### Old-style test dependencies

A package that declares its test dependencies with `[extras]`/`[weakdeps]` and
`[targets].test`, rather than a `test/Project.toml`, has no environment of its
own for `Pkg.test` to lock. Pkg instead synthesizes a sandbox project from
`[deps]` plus the `[targets].test` names and resolves that, which discards the
minimum this action resolved for a name reachable only through `[extras]` or
`[weakdeps]` and installs the newest compatible version in its place — even with
`allow_reresolve: false`. The downgrade job then passes against versions it never
meant to test.

For floor-resolved registry test extras, the action uses Julia's
[shared-manifest support](https://julialang.org/blog/2023/04/julia-1.9-highlights/):
it writes `.julia-downgrade-compat/Manifest.toml` and points the project's
`manifest` field there. This keeps test-only manifest entries available to
`Pkg.build` and `Pkg.test`, including versions with build metadata, while preserving the
original `[deps]`, `[extras]`, `[weakdeps]`, `[targets]`, and compatibility bounds.
The ordinary `Manifest.toml` remains available as the resolver output.

Only test extras with registry entries in the resolved manifest require this
shared manifest; `no_promote` entries and stdlibs alone do not. Path-source
handling remains as described above. The action intentionally leaves the
`manifest` field and shared manifest in place for subsequent locked steps.

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
