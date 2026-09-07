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

## nightly.yml

Tiers 2 and 3: real `terraform plan`, and for some modules real
`apply`/`destroy`, against the sandbox project via Workload Identity
Federation. Runs on a schedule and on manual dispatch only — never on a
pull request.
