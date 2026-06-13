# Rebasing the `insitu-cache` dev branches onto upstream forks

> When the user says "rebase our dev branches", "pull the latest from main"
> on the submodule forks, or "update from upstream", this is the procedure.

## TL;DR — happy path (no uncommitted changes)

```bash
# From the parent repo root:
scripts/rebase_dev_branches.sh --push
git commit                                          # commits parent's submodule SHA bump
```

That's it. The script handles the rest.

## TL;DR — with uncommitted changes

```bash
scripts/rebase_dev_branches.sh --commit-wip --push
# inspect, optionally amend the auto-generated wip-rebase commits
git commit                                          # parent
```

## What this is rebasing

Two forks owned by the user (`Aquaticfuller`):

- **`core`** submodule (`Aquaticfuller/gvsoc-core`)
- **`pulp`** submodule (`Aquaticfuller/gvsoc-pulp`)

Both forks use **`master`** as the default branch (not `main`), and both have a
**`insitu-cache`** dev branch where the InSitu cache work lives. We rebase
`insitu-cache` onto `origin/master` to pick up the upstream improvements while
keeping our 2 commits (the cache integration + a validation-fixes commit) on
top.

The parent repo's `main` branch records the submodule SHAs, so after rebasing
we must bump those pointers.

## Why rebase rather than merge

The dev branch carries a small, well-defined set of commits (the cache
integration + the validation fixes). Rebasing keeps that linear and easy to
read in the history. Merging would clutter the dev branch with merge commits
every time we pull upstream.

## Procedure (manual — what the script does)

### 0. Inspect state

```bash
echo "core:"; git -C core status --short; git -C core branch --show-current
echo "pulp:"; git -C pulp status --short; git -C pulp branch --show-current
```

Record the current `insitu-cache` tip SHAs on each submodule — these are your
recovery hooks if the rebase goes sideways:

```bash
git -C core rev-parse insitu-cache
git -C pulp rev-parse insitu-cache
```

### 1. Handle uncommitted work

If `git status` shows modified files in either submodule, do **not** rebase
yet. Pick one:

- **Commit them** with a meaningful message (preferred — preserves intent).
- **Stash them** if you want to defer them: `git -C <sub> stash`. After
  rebasing, `git -C <sub> stash pop`.
- **Discard them** (rare; only if you're sure they're already captured
  elsewhere): `git -C <sub> restore .` or `git -C <sub> reset --hard HEAD`.

### 2. Fetch + rebase each submodule

```bash
for sub in core pulp; do
    git -C "$sub" fetch origin
    git -C "$sub" checkout insitu-cache
    git -C "$sub" rebase origin/master
done
```

If a rebase hits a conflict:

```bash
git -C <sub> status                  # see which files conflict
# edit files to resolve
git -C <sub> add <resolved-files>
git -C <sub> rebase --continue       # or --skip / --abort
```

### 3. Force-push the rewritten branches

After rebase, the local branch has different SHAs than `origin/insitu-cache`.
Push with **`--force-with-lease`** (refuses to push if the remote moved while
you weren't looking):

```bash
git -C core push --force-with-lease origin insitu-cache
git -C pulp push --force-with-lease origin insitu-cache
```

### 4. Update the parent repo's submodule pointers

```bash
# At the parent repo root:
git diff --submodule              # sanity-check the SHA diffs
git add core pulp
git commit -m "submodules: rebase insitu-cache onto upstream master

Bump core and pulp submodules to the rebased insitu-cache tips. No
conflicts during either rebase."
```

You can push the parent commit when you're ready:

```bash
git push origin main
```

## Recovery if something went wrong

The pre-rebase tip SHAs you recorded in step 0 are your safety net. To roll
back:

```bash
git -C core  reset --hard <pre-rebase-core-sha>
git -C pulp  reset --hard <pre-rebase-pulp-sha>

# Then, if you already force-pushed, force-push the rollback too:
git -C core  push --force-with-lease origin insitu-cache
git -C pulp  push --force-with-lease origin insitu-cache
```

If you didn't write the pre-rebase SHAs down, they're still in the reflog for
~90 days:

```bash
git -C core reflog insitu-cache | head -10
```

## Conventions captured here

- **`--force-with-lease`, not `--force`.** Lease-based push refuses to
  overwrite the remote if anyone else has pushed since your last fetch.
  Cheap insurance.
- **Don't push the parent repo automatically.** The submodule force-push is
  authorized; the parent push is a separate decision because it touches the
  team-visible `main` branch.
- **Don't skip git hooks** (`--no-verify`, `--no-gpg-sign`). If a hook fails,
  fix the underlying issue.
- **Keep commits on the dev branch small** — one for the integration, one
  for accumulated bug fixes (named `validation:` if from a validation
  round). This keeps each rebase trivial.

## Reference — last successful run

| Date | core pre→post | pulp pre→post | Upstream master tips | Conflicts |
|---|---|---|---|---|
| 2026-04-21 | 75eadf74 → 671a27a5 | 7fe2cb8 → 0d3625d | core 455488f8, pulp abcddd6 | none |
| 2026-06-02 | 671a27a5 → 233850f4 | 0d3625d → 3d15e5d | core 26c86fd4 (+5), pulp abcddd6 | none; engine→a6d92918 |
| 2026-06-08 | edfc99d2 → 9364002e | cd04829 → b8d08e4 | core 6ca5e8f9 (+15), pulp 4319260 (+7) | none; engine→5863c25e; new elfutils-dev build dep (scripts/setup_elfutils_headers.sh) |
