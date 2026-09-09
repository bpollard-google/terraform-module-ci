# terraform-module-ci

Reusable GitHub Actions workflows shared by every serviceops Terraform module.

Managed in the `terraformer` repository under `ci/`. Do not edit here —
changes are overwritten by `demo/push-content.sh`.

## module-ci.yml

Tier-1 pull request gate. Runs lint, test, security and docs, then an
aggregator job named `gate`.

Branch protection should require the single check `ci / gate`, never the
individual job names. Required check names for reusable workflows are
nested as `<caller job> / <called job>`, so listing `lint` would never match
and every pull request would block forever on a check that never reports.

Needs no cloud credentials. Never grant it `id-token: write`.

## gates.sh

The same seven tools the workflows above run, as one script:
`ci/gates.sh <module-dir>`. Every run it is allowed to finish reporting on ends
in exactly one of these, and every marker goes to stderr:

| Exit | Marker | Meaning |
| --- | --- | --- |
| 0 | none | every gate passed |
| non-zero | `GATE_FAILED: <gate>` | that gate rejected the module, followed by the sentence an operator reads |
| non-zero | `GATES_INCOMPLETE: <reason> — <prose>` | no check returned a verdict |
| non-zero | `GATES_UNAPPLIED: <step> — <prose>` | every check passed, but the directory was not normalised, so it must not be pushed |

    <gate>    init | validate | tflint | test | checkov
    <reason>  usage | missing-tool | fmt | signal:INT | signal:TERM
              | signal:HUP | unknown
    <step>    terraform-docs | signal:INT | signal:TERM | signal:HUP

Every marker carries a single-token second field: split on whitespace and take
field two. The em dash separates it from prose meant for a human. The point of
the token is that a caller can name what stopped the run in *every* case, not
only when a gate was the thing that said no — a wrapper reporting failure with
nothing to name gives an operator no way to act, and a retry loop nothing to
fix. `unknown` should be unreachable and means a bug in `gates.sh`.

The last two markers are separate because the two applying tools sit on
opposite sides of the five checks: `fmt` runs first, so its failure means
nothing was verified, while `terraform-docs` runs last, so its failure means
the module passed everything and only the doc injection broke.

A non-zero exit carrying **no** marker means the script was killed before it
could speak, not that it passed. `INT`, `TERM` and `HUP` are trapped and do
report — a `timeout` sends `TERM`, so a timed-out run is reported. Any other
fatal signal is not: `KILL` cannot be trapped at all, and `PIPE`, `USR1`,
`XCPU`, `ALRM` and the rest are trappable but are not handled.

Five of the seven are checks that can fail the run — init, validate, tflint,
`terraform test` and checkov. The other two, `fmt` and `terraform-docs`, are
*applied* rather than checked: they rewrite the directory so that CI's
`fmt -check` and fail-on-diff have nothing to report.

It exists so that the pipeline's producers — `demo/seed.sh` and the agent
runner — put a branch through the identical list before pushing it, instead
of each keeping a copy that drifts.

It sources nothing and depends on no other file in this repository, so the
copy published here and the copy baked into the agent's container image both
run as they stand.

## nightly.yml

Tiers 2 and 3: real `terraform plan`, and for some modules real
`apply`/`destroy`, against the sandbox project via Workload Identity
Federation. Runs on a schedule and on manual dispatch only — never on a
pull request.
