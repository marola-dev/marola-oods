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

# Every gate CI runs.
quality:
    #!/usr/bin/env bash
    set -euo pipefail
    for tool in shellcheck actionlint agents-check; do command -v "$tool" >/dev/null || { echo "quality: $tool not installed — run inside 'nix develop'" >&2; exit 1; }; done
    shellcheck --severity=error scripts/*.sh
    actionlint
    scripts/oods-tree-check.sh
    scripts/oods-tree-check.sh --self-test
    scripts/app-image.sh --self-test
    agents-check

# The devkit hooks' contract: fast checks at commit, the full gate at push.
precommit:
    scripts/oods-tree-check.sh
    agents-check

prepush:
    just quality
