set shell := ["bash", "-euo", "pipefail", "-c"]
set allow-duplicate-recipes

# The devkit's shared recipes (uprd, pr, stack, issue-*, ...), from the tree `nix develop` links.
import? '.devkit/devkit.just'

default:
    @just --list

# Every file under data/oods/ (besides .gitkeep) is one of MIP-0056's formats.
oods-tree-check:
    scripts/oods-tree-check.sh

# The pinned app image oods-check.yml pulls and runs a smoke command against.
app-image:
    scripts/app-image.sh

# Apply the lake's pending migrations (specs/001-beach-persistence/contracts/migrations/), then
# views.sql: a local lake under .tmp/lake/ by default; `--b2` is a person's run, never CI's.
lake-migrate *args:
    scripts/lake-migrate.sh {{args}}

# Every gate CI runs, plus docs-lint (MIP-0074 §7; no devkit workflow runs it in CI yet).
quality:
    #!/usr/bin/env bash
    set -euo pipefail
    for tool in shellcheck actionlint agents-check docs-lint duckdb; do command -v "$tool" >/dev/null || { echo "quality: $tool not installed — run inside 'nix develop'" >&2; exit 1; }; done
    shellcheck --severity=error scripts/*.sh
    actionlint
    scripts/oods-tree-check.sh
    scripts/oods-tree-check.sh --self-test
    scripts/app-image.sh --self-test
    scripts/lake-migrate.sh --self-test
    agents-check
    docs-lint

# The devkit hooks' contract: fast checks at commit, the full gate at push.
precommit:
    scripts/oods-tree-check.sh
    agents-check

prepush:
    just quality
