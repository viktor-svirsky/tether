#!/usr/bin/env bash
# Reads a run's jobs as GitHub's API returns them (gh api repos/O/R/actions/runs/ID/jobs) on stdin.
# Exits 0 when some job was cancelled without a runner ever picking it up: no runner and no steps.
# That's the macos-26 runner never starting the job (#87), and rerunning it is all it needs. Exits 1
# for anything else, including a run cancelled after it started. scripts/test-never-started.sh tests it.
set -euo pipefail

python3 -c '
import json, sys
jobs = json.load(sys.stdin)["jobs"]
stuck = any(j["conclusion"] == "cancelled" and not j["steps"] and not j.get("runner_name") for j in jobs)
sys.exit(0 if stuck else 1)
'
