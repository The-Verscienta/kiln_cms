#!/usr/bin/env bash
# Parallel-session collision guard (PreToolUse / Bash).
#
# Reads the hook payload on stdin; prints a PreToolUse decision on stdout.
# Engages only on commands that publish work (`git push`, `gh pr create`).
#
# FAIL OPEN: any unexpected condition exits 0 (allow). A guard that wrongly
# blocks a push is worse than the collision it is trying to prevent.

set -uo pipefail

allow() { exit 0; }

deny() {
  # $1 = reason shown to the model and the user
  jq -cn --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }' 2>/dev/null || allow
  exit 0
}

command -v jq >/dev/null 2>&1 || allow
command -v git >/dev/null 2>&1 || allow

# This script is installed twice: once in the repo (.claude/settings.json, so it
# travels with the branch) and once at user level (~/.claude/settings.json, so
# it still covers worktrees on branches predating it). Both settings sources
# fire, so the user-level copy stands down whenever the repo ships its own —
# otherwise every finding prints twice.
abspath() { printf '%s/%s' "$(cd "$(dirname "$1")" 2>/dev/null && pwd)" "$(basename "$1")"; }
proj_copy="${CLAUDE_PROJECT_DIR:-}/.claude/hooks/parallel-session-guard.sh"
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -x "$proj_copy" ] \
   && [ "$(abspath "$0")" != "$(abspath "$proj_copy")" ]; then
  allow
fi

payload=$(cat 2>/dev/null) || allow
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null) || allow
[ -n "$cmd" ] || allow

is_push=0
is_pr_create=0
case "$cmd" in *"git push"*) is_push=1 ;; esac
case "$cmd" in *"gh pr create"*) is_pr_create=1 ;; esac
[ "$is_push" = 1 ] || [ "$is_pr_create" = 1 ] || allow

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || allow

cur_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# ---------------------------------------------------------------- target ----
# Work out which remote branch this command publishes to. Handles
# `git push`, `git push origin <branch>`, and `git push origin <src>:<dst>`.
target="$cur_branch"
if [ "$is_push" = 1 ]; then
  refspec=$(printf '%s' "$cmd" | sed -n 's/.*git push[^|;&]*/&/p' | tr ' ' '\n' \
    | grep -vE '^(git|push|-.*|--.*|origin|upstream)$' | tail -n 1 || true)
  if [ -n "${refspec:-}" ]; then
    case "$refspec" in
      *:*) target="${refspec##*:}" ;;
      *)   target="$refspec" ;;
    esac
  fi
fi
target="${target#refs/heads/}"
[ -n "$target" ] || allow

# ------------------------------------------------- check 1: remote moved ----
# The failure this exists for: another session rebased or force-pushed the
# branch after you based your work on it. Compare the TRUE remote head against
# the tracking ref you last fetched.
remote_head=$(git ls-remote origin "refs/heads/$target" 2>/dev/null | awk 'NR==1{print $1}' || true)
local_ref=$(git rev-parse -q --verify "refs/remotes/origin/$target" 2>/dev/null || true)

if [ -n "${remote_head:-}" ] && [ -n "${local_ref:-}" ] && [ "$remote_head" != "$local_ref" ]; then
  detail="origin/$target is ${remote_head:0:8} on the remote but ${local_ref:0:8} in your last fetch."
  if git cat-file -e "$remote_head" 2>/dev/null; then
    if ! git merge-base --is-ancestor "$remote_head" HEAD 2>/dev/null; then
      detail="$detail The remote head is NOT an ancestor of your HEAD, so this would discard it."
    fi
  else
    detail="$detail You do not have that commit locally — it was pushed after your last fetch."
  fi
  deny "PARALLEL-SESSION COLLISION GUARD — remote branch moved.

$detail

Another session (or person) has pushed to '$target' since you based your work on it. Do NOT re-run this push as-is; you would either be rejected or overwrite their work.

Do this instead:
  1. git fetch origin $target
  2. Compare: git log --oneline HEAD..origin/$target
  3. Decide whether your work is now stale, needs a re-merge, or is redundant.
  4. Tell the user what changed before pushing again.

If you have confirmed the overwrite is intended, the user must say so explicitly."
fi

# ----------------------------------------- check 2: sibling worktree race ----
# All parallel sessions on this machine share the filesystem, so a sibling
# worktree sitting on the same branch (or naming the same issue) is a
# same-machine collision you can see before it costs a CI round.
self=$(git rev-parse --show-toplevel 2>/dev/null || true)

issue_of() {
  # Split on every non-alphanumeric and keep tokens that are ENTIRELY digits.
  # This catches every convention in use — feat/807-x, fix/917-x, claude/954-x,
  # github-issue-339-x, p1-917-919 — while rejecting the hex worktree suffixes
  # (c543a6, 026a94, b719c2), whose digits always sit against a letter.
  printf '%s' "$1" | tr -c '[:alnum:]' ' ' | tr ' ' '\n' \
    | grep -xE '[0-9]{2,5}' | sort -u | tr '\n' ' '
}
my_issues=$(issue_of "$cur_branch")

collisions=""
while IFS= read -r line; do
  case "$line" in
    worktree\ *) wt="${line#worktree }" ;;
    branch\ *)
      wb="${line#branch }"; wb="${wb#refs/heads/}"
      [ "$wt" = "$self" ] && continue
      if [ -n "$cur_branch" ] && [ "$wb" = "$cur_branch" ]; then
        collisions="$collisions
  - $wt is on the SAME branch ($wb)"
      elif [ -n "$my_issues" ]; then
        for i in $my_issues; do
          case " $(issue_of "$wb") " in
            *" $i "*) collisions="$collisions
  - $wt is on '$wb' — same issue (#$i)" ;;
          esac
        done
      fi
      ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null || true)

if [ -n "$collisions" ]; then
  deny "PARALLEL-SESSION COLLISION GUARD — another worktree is on this work.
$collisions

A sibling worktree on this machine is working the same branch or issue, which means another session is probably mid-flight. Publishing now risks duplicate PRs or a force-push race.

Check before proceeding:
  1. git -C <that worktree> log --oneline -3   (is their work ahead of yours?)
  2. gh pr list --state open --search '<issue number>'
  3. Ask the user whether to continue, hand off, or stand down.

If the user confirms this is intended (e.g. they run several worktrees deliberately), say so and re-run."
fi

allow
