#!/usr/bin/env bash
#
# Rewrites the version numbers of the build for a new OpenMetadata release.
#
#   bump-version.sh <version> [build-suffix]      e.g. bump-version.sh 2.0.3        -> 2.0.3-sber.1
#                                                      bump-version.sh 2.0.3 sber.2 -> 2.0.3-sber.2
#
# Touches only version tags: openmetadata.version and the project/parent versions in the root pom
# and the openmetadata-shaded-deps, openmetadata-dist and openmetadata-docker poms, plus the
# hard-coded artifact version of the two shaded modules (must equal openmetadata.version, the
# enforcer checks it). Pins are not touched: compare them separately.

set -euo pipefail

VERSION="${1:?openmetadata version, e.g. 2.0.3}"
SUFFIX="${2:-sber.1}"
BUILD_VERSION="${VERSION}-${SUFFIX}"
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

PREV=$(sed -n 's#.*<openmetadata.version>\(.*\)</openmetadata.version>.*#\1#p' pom.xml | head -1)
# first <version> in the root pom is the project version (there is no <parent>)
PREV_BUILD=$(awk 'match($0, /<version>[^<]*<\/version>/) { print substr($0, RSTART+9, RLENGTH-19); exit }' pom.xml)
[ -n "$PREV" ] && [ -n "$PREV_BUILD" ] || { echo "bump-version: cannot read versions from pom.xml" >&2; exit 1; }

POMS="pom.xml openmetadata-shaded-deps/pom.xml openmetadata-shaded-deps/elasticsearch-dep/pom.xml \
      openmetadata-shaded-deps/opensearch-dep/pom.xml openmetadata-dist/pom.xml openmetadata-docker/pom.xml"

# BSD and GNU sed differ on -i; write through a temp file instead.
for f in $POMS; do
  sed -e "s#<version>${PREV_BUILD}</version>#<version>${BUILD_VERSION}</version>#g" \
      -e "s#<openmetadata.version>${PREV}</openmetadata.version>#<openmetadata.version>${VERSION}</openmetadata.version>#" \
      "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
for f in openmetadata-shaded-deps/elasticsearch-dep/pom.xml openmetadata-shaded-deps/opensearch-dep/pom.xml; do
  sed -e "s#^  <version>${PREV}</version>#  <version>${VERSION}</version>#" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

echo "bump-version: ${PREV} (${PREV_BUILD}) -> ${VERSION} (${BUILD_VERSION})"
grep -n -E "<version>${BUILD_VERSION}</version>|<version>${VERSION}</version>|<openmetadata.version>" $POMS
echo
echo "left-overs of the previous version (should be only comments, if anything):"
grep -n -E "${PREV//./\\.}" $POMS || echo "  none"
