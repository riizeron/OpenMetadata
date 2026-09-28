#!/usr/bin/env bash
#
# Post-build checks for the OpenMetadata distribution classpath.
#
#   check-dist.sh <libs-dir> <libs.lock> <duplicate-classes.baseline> [check|update]
#
# 1. jdeps: every class referenced by openmetadata-service must be resolvable from <libs-dir>.
# 2. Duplicate classes: pairs of jars that ship the same class. Pairs listed in the baseline are
#    tolerated (they exist in upstream too); any NEW pair fails the build.
# 3. libs.lock: the exact list of jar files must match the committed lock file, so that any change
#    of the runtime set shows up in code review.
#
# "update" rewrites libs.lock and the baseline from the current build instead of comparing.

set -euo pipefail
# sort/comm order must not depend on the machine's locale, or libs.lock differs between hosts
export LC_ALL=C

LIBS_DIR="${1:?libs dir}"
LOCK_FILE="${2:?libs.lock}"
BASELINE_FILE="${3:?duplicate-classes.baseline}"
MODE="${4:-check}"

fail() { echo "check-dist: ERROR: $*" >&2; exit 1; }
info() { echo "check-dist: $*"; }

[ -d "$LIBS_DIR" ] || fail "libs dir not found: $LIBS_DIR"
SERVICE_JAR=$(ls "$LIBS_DIR"/openmetadata-service-*.jar 2>/dev/null | head -1)
[ -n "$SERVICE_JAR" ] || fail "openmetadata-service jar not found in $LIBS_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- 1. jdeps
if command -v jdeps >/dev/null 2>&1; then
  jdeps --multi-release 21 -cp "$LIBS_DIR/*" -verbose:class "$SERVICE_JAR" 2>"$TMP/jdeps.err" \
    | grep "not found" | awk '{print $3}' | sort -u > "$TMP/missing.txt" || true
  if [ -s "$TMP/missing.txt" ]; then
    echo "classes referenced by $(basename "$SERVICE_JAR") but missing from the classpath:" >&2
    sed 's/^/  /' "$TMP/missing.txt" >&2
    fail "$(wc -l < "$TMP/missing.txt" | tr -d ' ') missing classes"
  fi
  info "jdeps: all classes referenced by openmetadata-service are on the classpath"
else
  info "WARNING: jdeps not found on PATH, skipping missing-class check"
fi

# ---------------------------------------------------------------- 2. duplicate classes
# artifact name without version, e.g. "netty-common-4.1.137.Final.jar" -> "netty-common"
strip_version() { sed -E 's/-[0-9]+(\.[0-9]+)*([.-][A-Za-z0-9]+)*\.jar$//'; }

list_classes() {
  if command -v unzip >/dev/null 2>&1; then unzip -Z1 "$1"; else jar tf "$1"; fi
}

: > "$TMP/classes.txt"
for jar in "$LIBS_DIR"/*.jar; do
  name=$(basename "$jar" | strip_version)
  # a jar without classes (aggregator/resources-only) makes grep exit 1; that is not an error
  list_classes "$jar" 2>/dev/null \
    | { grep '\.class$' || true; } | { grep -v -E '^META-INF/|module-info\.class$' || true; } \
    | sed "s#^#$name #" >> "$TMP/classes.txt"
done
# pairs of artifacts sharing at least one class, one "a b" line per pair (a < b)
awk '{cls=$2; art=$1; if (cls in first) { a=first[cls]; b=art; if (a!=b) { if (a>b){t=a;a=b;b=t}; print a, b } } else first[cls]=art }' \
  "$TMP/classes.txt" | sort -u > "$TMP/dup-pairs.txt"

if [ "$MODE" = "update" ]; then
  cp "$TMP/dup-pairs.txt" "$BASELINE_FILE"
  info "wrote $(wc -l < "$BASELINE_FILE" | tr -d ' ') duplicate-class pairs to $BASELINE_FILE"
else
  [ -f "$BASELINE_FILE" ] || fail "baseline not found: $BASELINE_FILE (run with -Dlock.mode=update once)"
  sort -u "$BASELINE_FILE" > "$TMP/baseline.txt"
  comm -13 "$TMP/baseline.txt" "$TMP/dup-pairs.txt" > "$TMP/new-pairs.txt"
  comm -23 "$TMP/baseline.txt" "$TMP/dup-pairs.txt" > "$TMP/gone-pairs.txt"
  if [ -s "$TMP/new-pairs.txt" ]; then
    echo "NEW jar pairs shipping the same classes (not in $BASELINE_FILE):" >&2
    sed 's/^/  /' "$TMP/new-pairs.txt" >&2
    fail "duplicate classes introduced; fix the dependency or add the pair to the baseline deliberately"
  fi
  if [ -s "$TMP/gone-pairs.txt" ]; then
    info "NOTE: these baseline pairs no longer overlap and can be removed from $BASELINE_FILE:"
    sed 's/^/  /' "$TMP/gone-pairs.txt"
  fi
  info "duplicate classes: no new overlapping jar pairs"
fi

# ---------------------------------------------------------------- 3. libs.lock
ls "$LIBS_DIR" | grep '\.jar$' | sort > "$TMP/libs.txt"
if [ "$MODE" = "update" ]; then
  cp "$TMP/libs.txt" "$LOCK_FILE"
  info "wrote $(wc -l < "$LOCK_FILE" | tr -d ' ') jars to $LOCK_FILE"
else
  [ -f "$LOCK_FILE" ] || fail "lock file not found: $LOCK_FILE (run with -Dlock.mode=update once)"
  if ! diff -u "$LOCK_FILE" "$TMP/libs.txt" > "$TMP/lock.diff"; then
    echo "runtime jar set differs from $LOCK_FILE:" >&2
    grep -E '^[-+][^-+]' "$TMP/lock.diff" | sed 's/^/  /' >&2
    fail "review the change, then refresh the lock with: mvn -pl openmetadata-dist -am package -Dlock.mode=update"
  fi
  info "libs.lock: runtime jar set unchanged ($(wc -l < "$TMP/libs.txt" | tr -d ' ') jars)"
fi
