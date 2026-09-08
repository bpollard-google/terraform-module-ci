#!/usr/bin/env bash
# Runs every input to the module CI gate against one module directory.
#
# "The same gate" means all four of the gate's jobs, not the convenient ones.
# From ci/.github/workflows/module-ci.yml:
#
#   lint     terraform fmt -check -recursive, init, validate, tflint
#   test     terraform test
#   security checkov against the module's own .checkov.baseline
#   docs     terraform-docs, inject, fail-on-diff
#
# Two callers, one list. demo/seed.sh runs this before it pushes the fallback
# branch, and the agent runner runs it before it opens a pull request; a subset
# in either of them would let a branch be produced under the word "verified"
# that reddens on the first click. Two copies of the list would drift the first
# time one of them gained a flag, which is the same defect arriving later.
#
# Seven tools run below. FIVE of them CHECK, and each one stops the run — init,
# validate, tflint, terraform test, checkov. TWO of them APPLY: `fmt` and
# `terraform-docs` rewrite the directory rather than confirm it, carry no
# failure branch, and cannot stop the run. CI runs both of them as checks
# (`fmt -check`, terraform-docs with fail-on-diff), so normalising here is what
# makes them green there — but the branch is green because this script made it
# so, not because a gate confirmed it. Worth keeping straight: a claim to have
# "verified" all seven would overstate two.
#
# The contract, for a caller that has to act on the result rather than just
# stop. Every run this script is allowed to finish reporting on ends in exactly
# one of these, and every marker goes to stderr:
#
#   exit 0                                      every gate passed
#   non-zero  GATE_FAILED: <gate>               that gate rejected the module
#   non-zero  GATES_INCOMPLETE: <reason> — ...  no check returned a verdict
#   non-zero  GATES_UNAPPLIED: <step> — ...     every check passed, but the
#                                               directory was not normalised,
#                                               so it must not be pushed
#
#   <gate>    init | validate | tflint | test | checkov
#   <reason>  usage | missing-tool | fmt | signal:INT | signal:TERM | signal:HUP
#             | unknown
#   <step>    terraform-docs | signal:INT | signal:TERM | signal:HUP
#
# Every marker carries a single-token second field, so a caller can name what
# stopped the run in every case rather than only when a gate was the thing that
# said no. That is the point of the whole scheme: a wrapper that reports failure
# with nothing to name gives an operator no way to act, and a build loop with
# nothing to name will retry three times against a fault no model can fix. The
# em dash separates the token from prose meant for a human; split on whitespace
# and take the second field.
#
# `unknown` should be unreachable: it is what a non-verdict failure between the
# checks would report, and every check has a verdict branch. It exists so the
# grammar is total, and a caller seeing it has found a bug in this script.
#
# The qualifier on "every run" is load-bearing: bash runs no EXIT trap for a
# fatal signal it has not trapped. INT, TERM and HUP are trapped below and do
# report — `timeout` sends TERM, so a timed-out run is reported. Any *other*
# fatal signal, KILL and PIPE included but also USR1, XCPU and the rest, exits
# non-zero carrying no marker at all. A caller must treat an unmarked non-zero
# as "the script never got to say", not as a pass.
#
# The last two lines are why the second is trustworthy. `fmt` and
# `terraform-docs` carry no failure branch by design, so under `set -e` either
# of them used to exit in silence — a "failure" with no gate named, which a
# caller building a blocked-issue comment out of the gate name has nothing to
# say about. They are also not the same failure, and one message for both would
# be wrong half the time: the two applying tools sit on opposite sides of the
# five checks. `fmt` runs first, so its failure means nothing was verified.
# `terraform-docs` runs last, after every check has passed, so its failure
# means the module is fine and the *docs injection* broke — telling an operator
# "no gate reached a verdict" there would be a false statement about a module
# that passed all five.
#
# Self-contained on purpose: this script sources nothing. demo/push-content.sh
# rsyncs ci/ into the public terraform-module-ci repository, where
# demo/lib/common.sh does not exist, and the agent's container image copies
# this file in on its own; a sourced helper would leave both of those copies
# dying at their first line, at runtime, in front of whoever was relying on
# them. The two helpers it needs are duplicated below, and
# demo/tests/test_gates.sh pins their output against the originals.
#
# Usage: ci/gates.sh <module-dir>
set -euo pipefail

# Duplicated from demo/lib/common.sh rather than sourced; see above. The
# duplication is deliberate and asserted: test_gates.sh runs both copies and
# compares what they print, so a change to the shared library that this file
# did not follow reddens rather than quietly diverging.
die() { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# A failing gate says two things, and neither is redundant.
#
# `GATE_FAILED: <name>` is for the caller that has to act on which gate failed
# — the agent runner reads it to decide what to fix and re-run, and a caller
# parsing the human sentence instead would break the first time the wording
# improved.
#
# The sentence is for the operator watching the stream, and it is the exact one
# demo/seed.sh printed while this block lived inside it. demo/tests/test_seed.sh
# pins four of them by exact string, so the wording is interface, not prose: a
# single generic message would delete assertions that took spec 1 several
# rounds to get right.
named_gate=false
gate_failed() {  # <gate name> <operator sentence>
  named_gate=true
  printf 'GATE_FAILED: %s\n' "$1" >&2
  die "$2"
}

# Every other way out. Under `set -e` a preflight refusal, a missing tool, or a
# failure of either applying tool leaves through here without a gate having
# said anything, and the caller still has to be told *which* nothing it got —
# an unnamed failure is the one thing a blocked-issue comment cannot be written
# from.
#
# Which of the two markers applies depends on how far the run got, and the
# token on how it stopped. `checks_passed` is the boundary: before it no verdict
# exists on anything, after it all five verdicts are in and only normalisation
# can still fail. `incomplete_reason` tracks the phase, so the token is the
# phase that was in progress rather than a guess made after the fact.
checks_passed=false
incomplete_reason=unknown

emit_unapplied() {  # <step token>
  printf 'GATES_UNAPPLIED: %s — every check passed but %s was not normalised\n' \
    "$1" "$mod" >&2
}

emit_incomplete() {  # <reason token>
  printf 'GATES_INCOMPLETE: %s — no check returned a verdict on %s\n' \
    "$1" "${mod:-<no module directory given>}" >&2
}

report_unnamed_exit() {
  local status=$?
  [[ "$status" -ne 0 ]] || return 0
  [[ "$named_gate" == false ]] || return 0
  # terraform-docs is the only normalising step after the checks, so past that
  # boundary it is the only thing this can have been.
  if [[ "$checks_passed" == true ]]; then
    emit_unapplied terraform-docs
  else
    emit_incomplete "$incomplete_reason"
  fi
}
trap report_unnamed_exit EXIT

# A trapped signal reports and then re-raises itself, so the exit status stays
# the conventional 128+n rather than becoming a plain 1 that hides what
# happened. Without the re-raise, a handler that merely returned would let the
# run carry on to the next gate — worse than not trapping at all.
#
# It consults `checks_passed` for the same reason the EXIT trap does: a TERM
# delivered during doc injection arrives after five passing verdicts, and
# reporting "no check returned a verdict" about that run would be false. Only
# the token says signal; which marker carries it is decided by how far the run
# had got, exactly as for any other unnamed exit.
on_signal() {  # <signal name>
  if [[ "$checks_passed" == true ]]; then
    emit_unapplied "signal:$1"
  else
    emit_incomplete "signal:$1"
  fi
  trap - EXIT "$1"
  kill -s "$1" $$
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

incomplete_reason=usage
usage='usage: ci/gates.sh <module-dir>'
[[ $# -eq 1 ]] || die "$usage"
mod="$1"
[[ -n "$mod" ]] || die "$usage"
[[ -d "$mod" ]] || die "not a module directory: $mod ($usage)"

# The same four the callers require of themselves. Checked here as well because
# a missing tool is otherwise a command-not-found part-way through the gate,
# after fmt has already rewritten the directory.
incomplete_reason=missing-tool
require_cmd terraform terraform-docs tflint checkov

# $mod is used as given, never resolved with `cd`+`pwd`: callers pass a path
# they will go on to commit and push from, and on a platform where the
# temporary directory is a symlink a resolved copy would no longer match it.
#
# fmt carries no verdict branch, so a directory that does not parse leaves
# through the EXIT trap; the token is set here so the trap can say it was fmt
# and not, say, the preflight.
incomplete_reason=fmt
terraform fmt -recursive "$mod" >/dev/null
# Reset before the checks: past this line an unnamed non-zero is a bug in this
# script rather than a phase with a name, and reporting a stale `fmt` would
# send whoever reads it to the wrong place.
incomplete_reason=unknown
terraform -chdir="$mod" init -backend=false -input=false >/dev/null \
  || gate_failed init "the fallback branch does not initialise"
terraform -chdir="$mod" validate >/dev/null \
  || gate_failed validate "the fallback branch does not validate; it was not pushed"
# --init is a no-op once the google ruleset is cached, and CI runs it too.
tflint --chdir="$mod" --init >/dev/null \
  || gate_failed tflint "could not initialise tflint against the fallback branch"
# Not silenced: when this fails, the findings are the diagnostic.
tflint --chdir="$mod" --recursive --format compact \
  || gate_failed tflint "the fallback branch does not pass tflint; it was not pushed"
terraform -chdir="$mod" test >/dev/null \
  || gate_failed test "the fallback branch does not pass its own tests; it was not pushed"
checkov -d "$mod" --framework terraform --baseline "$mod/.checkov.baseline" \
  --compact --quiet \
  || gate_failed checkov "the fallback branch does not pass checkov; it was not pushed"

# Every check has now returned a verdict, and all five were pass. Anything that
# goes wrong below this line is normalisation, not a judgement on the module —
# which is the whole difference between GATES_UNAPPLIED and GATES_INCOMPLETE.
checks_passed=true

terraform-docs markdown table --output-file README.md --output-mode inject \
  "$mod" >/dev/null
