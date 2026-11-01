#!/bin/sh
# Run the MiroFish swarm against UniversalVault.
#
# The model key never touches this repository: export it in your shell first.
#   export OPENCODE_GO_API_KEY=...
#   ./swarm/run.sh
#
# Optional arguments are passed to run.mjs, e.g.
#   ./swarm/run.sh --couples couple-01 --groups first-run
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${MIROFISH_SKILL:-$HOME/.agents/skills/mirofish-swarm}"
: "${OPENCODE_GO_API_KEY:?export OPENCODE_GO_API_KEY (or OPENCODE_KEY) before running}"

node "$SKILL/scripts/proxy.mjs" &
proxy=$!
trap 'kill "$proxy" 2>/dev/null || true' EXIT INT TERM
sleep 1

cd "$ROOT"
node "$SKILL/scripts/run.mjs" --config "$ROOT/swarm/mirofish.config.json" "$@"
echo "report: $ROOT/.mirofish/runs/<id>/report.md"
