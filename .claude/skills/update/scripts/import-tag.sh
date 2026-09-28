#!/usr/bin/env bash
#
# Stages the upstream runtime files of a new OpenMetadata release into the index.
#
#   import-tag.sh <version>          e.g. import-tag.sh 2.0.3
#
# Fetches tag <version>-release from origin (upstream), replaces bin/ conf/ bootstrap/ LICENSE
# NOTICE and the shaded-deps placeholder sources with the tag's versions, drops the upstream demo
# JWT keys and keeps our patched bootstrap/openmetadata-ops.sh. Nothing is committed: review
# `git status` and the diffs printed at the end, then commit with the message the script prints.

set -euo pipefail

VERSION="${1:?openmetadata version, e.g. 2.0.3}"
TAG="${VERSION}-release"
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

IMPORTED="bin conf bootstrap LICENSE NOTICE openmetadata-shaded-deps/elasticsearch-dep/src openmetadata-shaded-deps/opensearch-dep/src"
OURS_INSIDE_IMPORT="bootstrap/openmetadata-ops.sh"

fail() { echo "import-tag: ERROR: $*" >&2; exit 1; }

[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "working tree has uncommitted changes; commit or stash first"

PREV=$(sed -n 's#.*<openmetadata.version>\(.*\)</openmetadata.version>.*#\1#p' pom.xml | head -1)
[ -n "$PREV" ] || fail "cannot read openmetadata.version from pom.xml"
[ "$PREV" != "$VERSION" ] || fail "pom.xml already says ${VERSION}"

git fetch -q origin "tag" "$TAG" || fail "tag ${TAG} not found on origin"
git rev-parse -q --verify "${PREV}-release^{commit}" >/dev/null 2>&1 || git fetch -q origin tag "${PREV}-release" || true
SHA=$(git rev-parse --short "${TAG}^{commit}")

# shellcheck disable=SC2086
git rm -rq $IMPORTED
# shellcheck disable=SC2086
git checkout -q "$TAG" -- $IMPORTED
git rm -qf --ignore-unmatch conf/private_key.der conf/public_key.der
# shellcheck disable=SC2086
git checkout -q HEAD -- $OURS_INSIDE_IMPORT

echo "import-tag: staged ${TAG} (${SHA}) runtime files; previous version ${PREV}"
echo
echo "--- files that upstream changed between ${PREV}-release and ${TAG} in paths we patch ourselves:"
if git rev-parse -q --verify "${PREV}-release^{commit}" >/dev/null 2>&1; then
  git diff --stat "${PREV}-release" "$TAG" -- $OURS_INSIDE_IMPORT bin/openmetadata.sh \
    openmetadata-shaded-deps openmetadata-dist || true
else
  echo "  (tag ${PREV}-release is not available locally, skip)"
fi
echo
echo "--- staged changes:"
git status --short | head -40
echo
echo "Commit with:"
echo "  git commit -m 'Import OpenMetadata ${VERSION} runtime files (tag ${TAG}, ${SHA})'"
