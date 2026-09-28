#!/usr/bin/env bash
#
# Compares the runtime jar set of our distribution with what upstream itself ships.
#
#   compare-upstream.sh <openmetadata-version> [libs.lock]
#
# Upstream's platform pom manages transitive versions only inside the upstream reactor, so resolving
# openmetadata-service from a plain consumer pom does NOT give the classpath upstream ships. This
# script resolves the same three artifacts with platform:<ver> as the parent, which applies the
# upstream dependencyManagement to the whole graph exactly as openmetadata-dist does upstream.
#
# Output: jars only in our libs.lock and jars only in upstream's resolution. A jar that is only on
# our side at a LOWER version than upstream's is a stale pin; a HIGHER one is a deliberate pin.

set -euo pipefail
export LC_ALL=C

VERSION="${1:?openmetadata version, e.g. 2.0.2}"
LOCK_FILE="${2:-$(cd "$(dirname "$0")/.." && pwd)/openmetadata-dist/libs.lock}"
[ -f "$LOCK_FILE" ] || { echo "compare-upstream: libs.lock not found: $LOCK_FILE" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/pom.xml" <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.open-metadata</groupId>
    <artifactId>platform</artifactId>
    <version>${VERSION}</version>
    <relativePath/>
  </parent>
  <groupId>scratch</groupId>
  <artifactId>upstream-resolve</artifactId>
  <version>${VERSION}</version>
  <packaging>pom</packaging>
  <dependencies>
    <dependency><groupId>org.open-metadata</groupId><artifactId>openmetadata-service</artifactId><version>${VERSION}</version></dependency>
    <dependency><groupId>org.open-metadata</groupId><artifactId>openmetadata-mcp</artifactId><version>${VERSION}</version></dependency>
    <dependency><groupId>org.open-metadata</groupId><artifactId>openmetadata-ui</artifactId><version>${VERSION}</version></dependency>
  </dependencies>
</project>
EOF

echo "compare-upstream: resolving org.open-metadata:*:${VERSION} with platform:${VERSION} as parent"
mvn -B -ntp -q -f "$TMP/pom.xml" dependency:list -DincludeScope=runtime -Dsort=true \
  -DoutputFile="$TMP/deps.txt" > "$TMP/mvn.log" 2>&1 \
  || { cat "$TMP/mvn.log" >&2; echo "compare-upstream: dependency:list failed" >&2; exit 1; }

# "   g:a:jar:v:scope -- ..." or "   g:a:jar:classifier:v:scope -- ..."  ->  a-v[-classifier].jar
awk '{ n = split($1, p, ":"); if (p[3] != "jar") next;
       if (n == 5) print p[2] "-" p[4] ".jar";
       else if (n == 6) print p[2] "-" p[5] "-" p[4] ".jar" }' "$TMP/deps.txt" | sort -u > "$TMP/upstream.txt"
grep '\.jar$' "$LOCK_FILE" | sort -u > "$TMP/ours.txt"

echo "compare-upstream: ours $(wc -l < "$TMP/ours.txt" | tr -d ' ') jars, upstream $(wc -l < "$TMP/upstream.txt" | tr -d ' ') jars"
echo "--- only in $(basename "$LOCK_FILE") (our pins, or our shaded-deps exclusions):"
comm -23 "$TMP/ours.txt" "$TMP/upstream.txt" | sed 's/^/  + /'
echo "--- only in upstream ${VERSION} (the version upstream ships instead):"
comm -13 "$TMP/ours.txt" "$TMP/upstream.txt" | sed 's/^/  - /'
