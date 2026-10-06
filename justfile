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

# Apply lake/migrations/ and lake/views.sql to a local lake under .tmp/lake/ (never the bucket).
lake-migrate *args:
    scripts/lake-migrate.sh {{args}}

# lake/ as .tmp/marola-oods-lake-<tag>.tar.gz, as release.yml builds it for a v* tag.
lake-contract tag:
    scripts/lake-contract.sh {{tag}} .tmp

# The oods-lake agent skill: caps, attribution, evals, and every SQL block run on a local lake.
skill-check *args:
    scripts/skill-check.sh {{args}}

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
    scripts/lake-contract.sh --self-test
    scripts/skill-check.sh
    scripts/skill-check.sh --self-test
    agents-check
    docs-lint

# The devkit hooks' contract: fast checks at commit, the full gate at push.
precommit:
    scripts/oods-tree-check.sh
    agents-check

prepush:
    just quality
