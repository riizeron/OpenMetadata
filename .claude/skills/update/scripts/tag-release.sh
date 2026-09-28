#!/usr/bin/env bash
#
# Tags the current commit as a no-source release of the build version in pom.xml.
#
#   tag-release.sh            -> annotated tag <build-version>-no-source, e.g. 2.0.2-sber.1-no-source
#   tag-release.sh --push     -> the same, then push the tag to the fork remote
#
# The tag name carries the full build version (upstream version plus -sber.N) so that a re-release
# of the same upstream version gets its own tag. Refuses to run on a dirty tree or when the tag
# already exists on another commit: a tag that moves is worse than no tag.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

fail() { echo "tag-release: ERROR: $*" >&2; exit 1; }

[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "working tree has uncommitted changes"

BUILD_VERSION=$(awk 'match($0, /<version>[^<]*<\/version>/) { print substr($0, RSTART+9, RLENGTH-19); exit }' pom.xml)
OM_VERSION=$(sed -n 's#.*<openmetadata.version>\(.*\)</openmetadata.version>.*#\1#p' pom.xml | head -1)
[ -n "$BUILD_VERSION" ] && [ -n "$OM_VERSION" ] || fail "cannot read versions from pom.xml"
case "$BUILD_VERSION" in "$OM_VERSION"-*) ;; *) fail "build version ${BUILD_VERSION} does not start with openmetadata.version ${OM_VERSION}" ;; esac

TAG="${BUILD_VERSION}-no-source"
HEAD_SHA=$(git rev-parse HEAD)

if EXISTING=$(git rev-parse -q --verify "refs/tags/${TAG}^{commit}" 2>/dev/null); then
  [ "$EXISTING" = "$HEAD_SHA" ] || fail "tag ${TAG} already points at ${EXISTING:0:9}, not at HEAD; bump -sber.N instead of retagging"
  echo "tag-release: ${TAG} already on HEAD"
else
  git tag -a "$TAG" -m "OpenMetadata ${OM_VERSION} distribution built from published jars (${BUILD_VERSION})"
  echo "tag-release: created ${TAG} at ${HEAD_SHA:0:9}"
fi

if [ "${1:-}" = "--push" ]; then
  git push fork "refs/tags/${TAG}"
  echo "tag-release: pushed ${TAG} to fork"
fi
