---
name: update
description: Update this branch (build/no-source-dist) to a new OpenMetadata release; with no version given it finds the newest release that is both tagged upstream and published on Maven Central. Use whenever the user asks to update, bump, upgrade or move the distribution/build/repackaging to another or the latest OpenMetadata version or tag (e.g. "/update", "обнови до 2.0.3", "обнови openmetadata", "есть ли новая версия", "подними версию", "переедь на новый тег"), or asks to re-check the pins against upstream. Do not use for merging or rebasing upstream branches; this branch has no shared history with upstream by design.
---

# Update the no-source distribution to a new OpenMetadata release

This branch builds the OpenMetadata tar.gz and Docker image from the jars upstream publishes
to Maven Central, with vulnerable transitive libraries pinned in the root `pom.xml`. It has no
git history in common with upstream: the runtime files (`bin/`, `conf/`, `bootstrap/`, `LICENSE`,
`NOTICE`) are imported from the release tag as a snapshot. Updating therefore means two commits and a tag:

1. **Import** the tag's runtime files (mechanical, scripted).
2. **Adapt** the build: bump versions, reconcile the pins with what upstream ships, refresh
   `libs.lock`, and prove the classpath still works.
3. **Tag** the adapt commit `<ver>-no-src`.

README.md section «Обновление версии OpenMetadata» is the human description of the same
procedure; keep the two in sync if you change either.

The optional argument is the upstream version, e.g. `/update 2.0.3`. The tag is always
`<version>-release`.

## 0. Pick the version and check preconditions

**No argument given** (the usual case): run
`bash .claude/skills/update/scripts/latest-release.sh`. It prints the newest `X.Y.Z-release`
tag on `origin` that is newer than `openmetadata.version` in `pom.xml` **and** has all six
`org.open-metadata:*` artifacts on Maven Central. Upstream tags first and publishes later, so
"newest tag" and "newest buildable release" differ for a while; the script skips the unpublished
ones. Tell the user which version was chosen and why in one line (e.g. «Обновляю 2.0.2 → 2.0.4;
2.0.5 уже затегирован, но на Central его ещё нет») and proceed. Two exceptions:
- the script exits 1 (nothing newer, or only unpublished tags): report that and stop;
- the chosen version changes the major (`2.x` → `3.x`): ask before continuing, a major usually
  moves several library families at once and the user may prefer to wait for a patch release.
`latest-release.sh --all` lists every candidate with its status when the user wants to choose.

**Argument given**: use it, but still verify it the same way, each failure has a different fix:

- The tag exists: `git ls-remote --tags origin '<ver>-release'`.
- The jars are published: `https://repo1.maven.org/maven2/org/open-metadata/<a>/<ver>/<a>-<ver>.pom`
  returns 200 for `platform`, `openmetadata-service`, `openmetadata-mcp`, `openmetadata-ui`,
  `elasticsearch-deps`, `opensearch-deps`. If anything is 404, stop and tell the user, the build
  cannot work yet.

In both cases:

- On branch `build/no-source-dist` with no uncommitted changes (`git status --porcelain
  --untracked-files=no` empty).
- `origin` points at upstream (`github.com/open-metadata/OpenMetadata`), `fork` at the user's
  fork. Tags come from `origin`, pushes go to `fork`.
- Note the current version from `pom.xml` (`openmetadata.version`), call it `<prev>` below.

## 1. Import commit

Run `bash .claude/skills/update/scripts/import-tag.sh <ver>`. It fetches the tag, replaces the
imported paths, drops the demo keys `conf/*.der`, restores our patched
`bootstrap/openmetadata-ops.sh`, and prints:

- the upstream diffstat between `<prev>-release` and `<ver>-release` for the files we patch
  ourselves (`bootstrap/openmetadata-ops.sh`, `bin/openmetadata.sh`) and for
  `openmetadata-shaded-deps/`, `openmetadata-dist/`;
- the commit message to use.

If upstream changed `openmetadata-ops.sh`, look at `git diff <prev>-release <ver>-release --
bootstrap/openmetadata-ops.sh` and port the change into our copy by hand: our version differs
from upstream only by sourcing `conf/openmetadata-env.sh` and passing `$OPENMETADATA_OPTS`.
Then commit exactly as the script suggests; the sha in the message is how provenance is kept
without upstream history.

## 2. Adapt commit

### 2a. Versions

`bash .claude/skills/update/scripts/bump-version.sh <ver>` rewrites `openmetadata.version`, the
build version `<ver>-sber.1` in every pom and the hard-coded `<version>` of the two shaded
modules (the enforcer fails the build if they differ from `openmetadata.version`). If this is a
re-release of the same upstream version, pass the suffix: `bump-version.sh <ver> sber.2`.

### 2b. What upstream changed in the build itself

The upstream poms are not in this branch, read them from the tag:

```bash
git diff <prev>-release <ver>-release -- openmetadata-shaded-deps openmetadata-dist/pom.xml
git show <ver>-release:pom.xml            # upstream root pom ("platform")
git show <ver>-release:openmetadata-service/pom.xml
```

Look for three things:

- `elasticsearch-java` / `opensearch-java` versions in `openmetadata-shaded-deps/*/pom.xml`:
  ours must match, they are the whole point of those modules.
- New shaded artifacts or new modules that `openmetadata-dist/pom.xml` depends on upstream
  (today: `openmetadata-service`, `openmetadata-mcp`, `openmetadata-ui`). Mirror them in our
  `openmetadata-dist/pom.xml`.
- New relocations or excludes in the upstream shade config that our modules lack.

### 2c. Pins against what upstream really ships

Do not compare against upstream's pom text. Upstream's `dependencyManagement` applies to its
own reactor only, so the versions upstream *ships* are what matters, and the way to see them is
to resolve the graph with `platform:<ver>` as parent. `tools/compare-upstream.sh <ver>` does
exactly that and diffs the result with `openmetadata-dist/libs.lock`. Run it **after** the first
build in 2d has refreshed `libs.lock`.

The root pom imports `org.open-metadata:platform:${openmetadata.version}` as a BOM, so upstream's
managed versions already apply to our graph and the comparison should come out almost clean by
itself. Two consequences to keep in mind: the import replays upstream's version for anything we
do not pin, even when a newer one is reachable transitively (that is why `commons-compress` and
`commons-lang3` carry explicit pins); and an upstream entry that carries an `exclusion` is lost
when one of our family BOMs manages the same artifact, which is why `dropwizard-core` is copied
explicitly with its `log4j-over-slf4j` exclusion. Then read the two lists:

- `only in libs.lock` at a **lower** version than the upstream counterpart: a stale pin. Remove
  it if upstream's version is now acceptable, or raise it. This is the case to hunt for; a stale
  pin silently downgrades a library the service was compiled against (the 1.12.6 →2.0.2 update
  had `google-cloud-secretmanager 2.28.0` dragging the whole gRPC/gax family below upstream).
- `only in libs.lock` at a **higher** version: a deliberate SCA pin. Keep it unless it now
  contradicts something (e.g. a major bump upstream made: Spring 6→7, Netty 4.1→4.2). Update
  the `<!-- upstream X -->` comments in `pom.xml` so the next person knows what upstream has.
- A whole family unified on one version (all Jackson modules, all JDBI artifacts) while upstream
  ships a mix: intended, our BOM imports do that.
- Pairs that must move together: `protobuf-java` with `protobuf-java-util`; `netty-*` with
  `reactor-netty`; `reactor-netty` with `reactor-core`; the JDBI BOM with `dropwizard-jdbi3`.

JDBI deserves a special check every time: `openmetadata-service` is compiled against
`jdbi3-sqlobject` 3.37.x and 3.38+ breaks `handle.attach()` with a `ClassCastException`. The
`JdbiAttachSmoke` step in the build catches this, but if upstream finally moves JDBI, drop our
pin rather than keep it.

Also read the enforcer's `requireUpperBoundDeps` warnings in the build log (advisory only). They
list libraries some dependency wants newer than we resolve; most are known and harmless
(Jackson below what Dropwizard 5 declares, JDBI 3.37 below 3.49), new ones deserve a look.

### 2d. Build, lock, verify

```bash
mvn -B -ntp -pl openmetadata-dist -am clean verify -Ddocker.skip=true -Dlock.mode=update
```

`-Dlock.mode=update` rewrites `openmetadata-dist/libs.lock` and `duplicate-classes.baseline`;
`-Ddocker.skip=true` because the base image lives in the internal registry. Iterate with 2c until
`compare-upstream.sh` shows nothing lower than upstream, then run once more **without**
`-Dlock.mode=update` so the committed lock is proven to pass in check mode. The build is green
only when all four print: `OpenMetadataApplication check` exits 0, `JdbiAttachSmoke: attached N/N`,
`check-dist: jdeps: all classes ... on the classpath`, `check-dist: libs.lock: runtime jar set unchanged`.

Sanity-check the tarball: `tar tzf openmetadata-dist/target/openmetadata-<ver>-sber.1.tar.gz | awk -F/ '{print $2}' | sort | uniq -c`
must show `bin`, `bootstrap`, `conf`, `libs`, and `conf/` must not contain `.der` files.

### 2e. Docs and commit

- README: the current tag is named in the intro («Сейчас это `<prev>-release`»), update it.
  Do not rewrite the procedure unless you changed it.
- Commit message: what moved and why, in the style of the previous adapt commits (`git log`):
  the pins raised/removed with their upstream values, anything unusual the comparison showed,
  and the JDBI status. `git diff HEAD~1 -- pom.xml openmetadata-dist/libs.lock` is the
  reviewer's view; make the message answer the questions that diff raises.

## 3. Tag

Right after the adapt commit run `bash .claude/skills/update/scripts/tag-release.sh`. It puts an
annotated tag `<ver>-no-src` (e.g. `2.0.4-no-src`) on HEAD, mirroring upstream's `<ver>-release`.
Tag the adapt commit specifically, not a later docs or skill commit: the tag marks the tree the
tar.gz was verified from. The script refuses to move an existing tag. That happens on a re-release
of the same upstream version (`-sber.2`): the tag names the upstream version only, so decide with
the user whether the new build should take it over (`git tag -d <tag> && git push fork
:refs/tags/<tag>`, then rerun) or stay untagged.

## 4. Report and push

Report to the user: the two commits and the tag, the pin changes with upstream values, the jar
count delta in `libs.lock`, the smoke results, anything skipped (Docker). Push only when asked;
the branch tracks `fork`, and the tag does not travel with the branch:

```bash
git push fork build/no-source-dist && bash .claude/skills/update/scripts/tag-release.sh --push
```

## Things that go wrong

- **Stale jars in `target/libs`**: `copy-dependencies` never deletes; the dist pom now wipes the
  directory in `prepare-package`, so a build after a pin change is trustworthy. If the check
  ever reports two versions of one artifact, that guard is broken.
- **`libs.lock` mismatch that is only ordering**: `check-dist.sh` forces `LC_ALL=C`; if the lock
  still differs by order alone, someone regenerated it without the script.
- **Auto-merged source files**: none, on purpose. If you find yourself running `git merge` or
  `git rebase` against an upstream ref, stop; that reintroduces upstream history the user does
  not want in this branch.
- **`compare-upstream.sh` downloads a lot** the first time (it resolves the full upstream graph);
  the local Maven cache is shared with the build, so it is a one-off.
