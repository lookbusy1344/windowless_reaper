#!/usr/bin/env bash
# Regenerate Sources/wreaper/BuildInfo.swift with a release version + commit.
#
# Used by CI (.github/workflows/release.yml) and scripts/release.sh. The
# committed BuildInfo.swift holds dev placeholders; this overwrites them so the
# binary's `--version` reports the tag that produced it.
#
#   scripts/stamp-version.sh <version> [commit]
#
# <version> has no leading 'v' (e.g. 1.2.0). [commit] defaults to the short
# hash of HEAD.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

VERSION="${1:?usage: stamp-version.sh <version> [commit]}"
COMMIT="${2:-$(git rev-parse --short=12 HEAD)}"

# Reject anything that could break out of the generated Swift string literal.
[[ "$VERSION" =~ ^[0-9A-Za-z.+-]+$ ]] || { echo "stamp-version.sh: bad version '$VERSION'" >&2; exit 2; }
[[ "$COMMIT" =~ ^[0-9A-Za-z]+$ ]] || { echo "stamp-version.sh: bad commit '$COMMIT'" >&2; exit 2; }

cat > Sources/wreaper/BuildInfo.swift <<EOF
/// Build-time version stamp.
///
/// The committed copy holds dev placeholders. Release builds overwrite this
/// file via \`scripts/stamp-version.sh <version>\`, which substitutes the git
/// tag and the short commit hash. \`scripts/release.sh\` and the \`release.yml\`
/// GitHub workflow both stamp before \`swift build -c release\`, so the embedded
/// \`--version\` string matches the tag that produced the binary.
enum BuildInfo {
    static let version = "$VERSION"
    static let commit = "$COMMIT"
}
EOF

echo "stamped BuildInfo.swift: $VERSION ($COMMIT)"
