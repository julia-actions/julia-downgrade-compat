# How to make a new release of this action

Let `vX.Y.Z` be the new version that you want to release.

1. Create a new `vX.Y.Z` release:
    - Go to https://github.com/julia-actions/julia-downgrade-compat/releases
    - Click on "Draft a new release"
    - Click on "Tag: Select tag", and type `vX.Y.Z` (e.g. `v2.3.4`). Then click the "Create new tag" button. Make sure you include the `v` at the beginning of the tag!
    - For release title, type `vX.Y.Z`.
    - Click the green "Publish release" button at the bottom of the page.
2. Force-update the `vX` and `vX.Y` tags, using the following commands:

```bash
git clone git@github.com:julia-actions/julia-downgrade-compat.git
cd julia-downgrade-compat

git fetch --all

git tag -d vX
git tag -d vX.Y
git tag vX vX.Y.Z
git tag vX.Y vX.Y.Z
git push --force origin vX
git push --force origin vX.Y
```
