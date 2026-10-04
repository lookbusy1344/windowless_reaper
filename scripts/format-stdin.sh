#!/usr/bin/env bash
# format-stdin.sh <path> — `jj fix` tool: read Swift source on stdin, write the
# formatted result to stdout. --stdin-path lets swiftformat find .swiftformat.

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

path="${1:?usage: format-stdin.sh <path>}"

swiftformat stdin --stdin-path "${path}" --quiet
