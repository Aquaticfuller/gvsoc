#!/usr/bin/env bash
#
# Rebase the `insitu-cache` dev branches in the `core` and `pulp` submodule forks
# onto their respective `origin/master`, and update the parent repo's submodule
# pointers.
#
# Usage:
#   scripts/rebase_dev_branches.sh                     # interactive: refuses to proceed
#                                                      # if working trees are dirty
#   scripts/rebase_dev_branches.sh --commit-wip        # commit any uncommitted
#                                                      # validation changes first
#                                                      # under a 'wip-rebase: ...'
#                                                      # commit message
#   scripts/rebase_dev_branches.sh --push              # force-push --force-with-lease
#                                                      # the rebased branches at the
#                                                      # end (after rebase succeeds)
#
# Run from the parent repo root.
#
# See prompt/rebase_dev_branches_runbook.md for the full procedure, recovery,
# and why each step is here.

set -euo pipefail

# --- Constants. Adjust these if branch names change. -------------------------
DEV_BRANCH=insitu-cache
UPSTREAM_BRANCH=origin/master          # default branch on both forks
SUBMODULES=(core pulp)

# --- Args. ------------------------------------------------------------------
COMMIT_WIP=0
PUSH=0
for arg in "$@"; do
    case "$arg" in
        --commit-wip) COMMIT_WIP=1 ;;
        --push)       PUSH=1 ;;
        -h|--help)
            sed -n '2,/^set -e/p' "$0" | sed -e 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# --- Sanity checks. ---------------------------------------------------------

if [ ! -f .gitmodules ] || [ ! -d core ] || [ ! -d pulp ]; then
    echo "FAIL: run this from the parent repo root (containing .gitmodules + core/ + pulp/)" >&2
    exit 1
fi

# --- Step 0: record pre-rebase SHAs as a recovery hint. ---------------------

echo "==> Pre-rebase SHAs (recovery: git -C <sub> reset --hard <sha>)"
for sub in "${SUBMODULES[@]}"; do
    sha=$(git -C "$sub" rev-parse "$DEV_BRANCH")
    echo "    $sub/$DEV_BRANCH = $sha"
done

# --- Step 1: handle uncommitted work in each submodule. ---------------------

for sub in "${SUBMODULES[@]}"; do
    if ! git -C "$sub" diff --quiet HEAD; then
        if [ "$COMMIT_WIP" -eq 1 ]; then
            echo "==> $sub: committing dirty working tree as 'wip-rebase: ...'"
            git -C "$sub" add -u
            git -C "$sub" commit -m "wip-rebase: dirty tree at rebase time

Auto-captured by scripts/rebase_dev_branches.sh --commit-wip so the
subsequent rebase is non-destructive. Squash / amend / split this into
proper commit(s) before pushing if you care about history."
        else
            echo "FAIL: $sub has uncommitted changes. Either commit them, stash, or" >&2
            echo "      re-run with --commit-wip." >&2
            git -C "$sub" status --short >&2
            exit 1
        fi
    fi
done

# --- Step 2: fetch + rebase each submodule onto $UPSTREAM_BRANCH. -----------

for sub in "${SUBMODULES[@]}"; do
    echo "==> $sub: fetch origin"
    git -C "$sub" fetch --quiet origin

    cur_branch=$(git -C "$sub" branch --show-current)
    if [ "$cur_branch" != "$DEV_BRANCH" ]; then
        echo "==> $sub: switching to $DEV_BRANCH (was on '$cur_branch')"
        git -C "$sub" checkout "$DEV_BRANCH"
    fi

    behind=$(git -C "$sub" rev-list --count "$DEV_BRANCH".."$UPSTREAM_BRANCH")
    ahead=$(git -C "$sub" rev-list --count "$UPSTREAM_BRANCH".."$DEV_BRANCH")
    echo "==> $sub: $DEV_BRANCH is $behind commits behind $UPSTREAM_BRANCH and $ahead ahead"

    if [ "$behind" -eq 0 ]; then
        echo "    nothing to do for $sub"
        continue
    fi

    if ! git -C "$sub" rebase "$UPSTREAM_BRANCH"; then
        echo "FAIL: rebase conflict in $sub. Resolve manually:" >&2
        echo "        git -C $sub status" >&2
        echo "        # edit files, then:" >&2
        echo "        git -C $sub add <files> && git -C $sub rebase --continue" >&2
        echo "      To bail: git -C $sub rebase --abort" >&2
        exit 1
    fi
done

# --- Step 3: optionally force-push the rebased branches. -------------------

if [ "$PUSH" -eq 1 ]; then
    for sub in "${SUBMODULES[@]}"; do
        echo "==> $sub: push --force-with-lease origin $DEV_BRANCH"
        git -C "$sub" push --force-with-lease origin "$DEV_BRANCH"
    done
else
    echo "==> Skipping push. To push:"
    for sub in "${SUBMODULES[@]}"; do
        echo "        git -C $sub push --force-with-lease origin $DEV_BRANCH"
    done
fi

# --- Step 4: update parent's submodule pointers. ---------------------------

if ! git diff --quiet -- "${SUBMODULES[@]}"; then
    echo "==> Parent: staging updated submodule pointers"
    git add "${SUBMODULES[@]}"
    cat <<'MSG'
==> Parent: ready to commit. Suggested message:

submodules: rebase insitu-cache onto upstream master

Bump core and pulp submodules to the rebased insitu-cache tips. No
conflicts during either rebase.

==> Inspect with: git diff --staged --submodule
==> Commit with:  git commit
MSG
else
    echo "==> Parent: submodule pointers already match (nothing to commit)"
fi

echo "==> Done."
