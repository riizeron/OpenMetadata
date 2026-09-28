#!/usr/bin/env bash
#
# Prints the newest OpenMetadata release that can actually be repackaged.
#
#   latest-release.sh            -> e.g. "2.0.3"
#   latest-release.sh --all      -> every candidate newer than the current one, with its status
#
# A release qualifies when upstream has the tag <ver>-release AND all six org.open-metadata
# artifacts of that version are on Maven Central. Upstream tags first and publishes hours or
# days later, so the newest tag is not always buildable; pre-releases (rc, beta, ...) are skipped.
# Exit 1 with a message when nothing newer than pom.xml's openmetadata.version qualifies.

set -euo pipefail
export LC_ALL=C

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
CURRENT=$(sed -n 's#.*<openmetadata.version>\(.*\)</openmetadata.version>.*#\1#p' pom.xml | head -1)
[ -n "$CURRENT" ] || { echo "latest-release: cannot read openmetadata.version from pom.xml" >&2; exit 1; }

ARTIFACTS="platform openmetadata-service openmetadata-mcp openmetadata-ui elasticsearch-deps opensearch-deps"
CENTRAL="https://repo1.maven.org/maven2/org/open-metadata"

published() {
  local v="$1" a
  for a in $ARTIFACTS; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$CENTRAL/$a/$v/$a-$v.pom")" = "200" ] || return 1
  done
}

# tags like 2.0.3-release, newest first; sort -V orders 2.0.10 after 2.0.9
CANDIDATES=$(git ls-remote --tags origin 'refs/tags/[0-9]*.[0-9]*.[0-9]*-release' \
  | sed 's#.*refs/tags/##; s#-release$##' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
  | { cat; echo "$CURRENT"; } | sort -uV | sed "1,/^${CURRENT//./\\.}\$/d" | sort -rV)

[ -n "$CANDIDATES" ] || { echo "latest-release: no release tag newer than ${CURRENT} on origin" >&2; exit 1; }

BEST=""
for v in $CANDIDATES; do
  if published "$v"; then
    status="published"; [ -z "$BEST" ] && BEST="$v"
  else
    status="tag only, not on Maven Central yet"
  fi
  [ "${1:-}" = "--all" ] && echo "$v  $status"
  [ "${1:-}" != "--all" ] && [ -n "$BEST" ] && break
done

if [ -z "$BEST" ]; then
  echo "latest-release: tags newer than ${CURRENT} exist but none is on Maven Central yet" >&2; exit 1
fi
[ "${1:-}" = "--all" ] || echo "$BEST"
