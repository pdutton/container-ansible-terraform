# Docker Hub Publishing and CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the four composed variants to `docker.io/pdutton/ansible-terraform` under an eleven-tag scheme, and build, smoke-test and publish them from GitHub Actions.

**Architecture:** The Makefile owns the tag scheme and the push, so both can be run and debugged locally; the workflow is a thin driver that calls `make push-<variant>`. A shared `TAG_SET_SH` snippet defines the tag list once and is expanded by both `tag-%` and `push-%`. The two version axes are joined into one composite `$version` string at detection time and carried whole, so the tag math never has to split them apart to build a tag — only to validate one.

**Tech Stack:** GNU Make, Podman, GitHub Actions, Docker Hub.

**Spec:** `docs/superpowers/specs/2026-08-09-dockerhub-publish-design.md`
**Sibling pattern:** `~/projects/container-ansible/primary/` and `~/projects/container-terraform/primary/` — their `Makefile` and `.github/workflows/build.yml` are the reference implementations. Read both before starting.

## Global Constraints

- Registry default: `REGISTRY ?= docker.io/pdutton`. Local image name stays `ansible-terraform`.
- `LOCAL_IMAGE = localhost/$(IMAGE)` already exists and is already used everywhere. **No bare `$(IMAGE)` may be introduced as an image reference.** The one legitimate bare use is inside `clean`'s grep pattern, which matches podman output rather than naming an image.
- `LATEST_VARIANT := ubuntu-stable`. A Terraform prerelease must never be reachable as `latest`.
- **Eleven tags** after a full build: `alpine-stable`, `alpine-development`, `ubuntu-stable`, `ubuntu-development`, `alpine-13.0.0-1.15.8`, `alpine-14.2.0-1.16.0-beta2`, `ubuntu-13.1.0-1.15.8`, `ubuntu-14.2.0-1.16.0-beta2`, `alpine`, `ubuntu`, `latest`. (Version components drift; the count and the shapes do not.)
- **There is no intermediate tag, ever.** No `alpine-13-1.15`, no single-axis `alpine-13` or `alpine-1.15`. Every published tag either names a channel or names both versions exactly.
- The version tag derives from the **detected** versions, read out of the freshly built image. Nothing about a version may be typed into the Makefile.
- `push-%` must depend on `test-%`. A smoke-test failure must block publishing.
- The push source must be `$(LOCAL_IMAGE)`, never a bare short name.
- Workflow: publish only on non-`pull_request` **AND** `refs/heads/master`. The build-and-test condition must be the exact negation.
- `fail-fast: false` on the matrix.
- Both workflow `make` invocations pass `PODMAN_BUILD_FLAGS="--pull"`.
- External tools stay overridable: `PODMAN ?= /usr/bin/podman`, `AWK ?= /usr/bin/awk`.
- `clean` must never run a blanket `podman image prune`.
- **No committed change to `Containerfile.*` or `test/smoke.yml`.** This work is Makefile, workflow, and docs only. In particular, do not add version, channel, or prerelease assertions to the smoke test — the spec records that as a deliberately accepted risk, not an oversight.
- **One sanctioned temporary edit:** Task 2 Step 8 appends a deliberately failing task to `test/smoke.yml` to prove at runtime that a failing smoke test aborts before the push loop. It must be restored byte-for-byte in the same step and verified with `git diff`. This is the only permitted edit to that file, and it must never reach a commit.

**Working directory:** `~/projects/container-ansible-terraform/feature/dockerhub-publish` (already exists, branch `feature/dockerhub-publish`). All commands below run there.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Makefile` | Modify | Registry var, tag scheme, push targets. Owns everything about tags. |
| `.github/workflows/build.yml` | Create | Thin driver: matrix over variants, calls `make`. Plus the Hub description job. |
| `DOCKERHUB-OVERVIEW.md` | Create | The Docker Hub page. Deliberately carries no version numbers. |
| `README.md` | Modify | Badge, Published Images, eleven-tag table, mutability caveat, `make push`, CI section. |
| `CLAUDE.md` | Modify | Publishing section; `make push`; the hand-check becomes pre-merge. |
| `.dockerignore` | Modify | Keep the new root files out of the build context. |

---

### Task 1: The full tag set

Rename `version-tag-%` to `tag-%`, move its guards into a shared `TAG_SET_SH`, and have it apply all eleven tags locally instead of two. Nothing pushes yet.

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Produces: `$(REGISTRY)` defaulting to `docker.io/pdutton`; `$(LATEST_VARIANT)` = `ubuntu-stable`; `$(TAG_SET_SH)`, a shell snippet which, given `$version` (the composite `<ansible>-<terraform>` string) and `$*` (the variant stem), sets `$tags` to the space-separated tag list; and target `tag-%` which stamps `org.opencontainers.image.version` with that composite and applies every tag in `$tags`.
- Task 2 consumes all four.

- [ ] **Step 1: Record the current tag set as a baseline**

```bash
make clean
make build
podman images --format '{{.Repository}}:{{.Tag}}' | grep ansible-terraform | sort | tee /tmp/at-tags-before.txt
```

Expected: eight tags — the four `<os>-<channel>` names and the four `<os>-<ansible>-<terraform>` names. Keep this file; Step 10 compares against it.

- [ ] **Step 2: Add the registry and latest-variant variables**

In `Makefile`, immediately after the `LOCAL_IMAGE` block, add:

```make
# Registry the push targets publish to. Override to retarget:
# `make push REGISTRY=ghcr.io/pdutton`
#
# The account here must match the DOCKERHUB_USERNAME repository secret CI logs
# in with. If they disagree, nothing fails early: `podman login` succeeds
# against the wrong account and the push 401s on its first tag.
#
# That secret is masked in CI logs, so push-%'s progress line renders as
# `Pushing docker.io/***/ansible-terraform:latest` there rather than showing
# the account -- expected, not a broken expansion.
REGISTRY ?= docker.io/pdutton

# The one variant that also carries the `latest` tag. Ubuntu is the variant
# with no capability gaps (WinRM/Kerberos work only there) and stable is the
# channel whose Terraform is a final release, so an unqualified pull lands on
# the image least likely to fail in a way the puller cannot diagnose -- and a
# Terraform prerelease is never reachable as `latest`.
LATEST_VARIANT := ubuntu-stable
```

- [ ] **Step 3: Add the shared tag-set snippet**

Add this immediately after `GIT_REV`, before `.DEFAULT_GOAL`:

```make
# Shell snippet, expanded inside a recipe. Given $version already set by the
# recipe and $* set by the pattern rule, it sets $tags to the full tag list for
# that variant. tag-% and push-% both expand it, so the tag scheme is defined
# in exactly one place.
#
# Three deliberate details:
#  * Written as one logical line. Backslash continuations in a variable
#    assignment collapse to spaces, so expanding this inside a recipe cannot
#    introduce a newline into the shell command.
#  * `if ... fi` rather than `[ ... ] && ...`. Under `set -e` a false test in
#    the latter form is a non-zero exit status for the whole line, which aborts
#    the recipe instead of skipping the tag.
#  * The `#` in $${version\#*-} MUST stay escaped. An unescaped `#` inside a
#    variable assignment starts a Make comment and would silently truncate
#    everything after it.
#
# $version is the COMPOSITE <ansible>-<terraform>, and the version tag uses it
# whole. It is split here only to validate, never to build a tag.
#
# Four guards, in order, all before any tag is applied:
#  1. The variant stem is exactly two '-'-separated words. os/channel come from
#     word 1/2 of $* and silently discard anything past word 2, so a future
#     variant such as ubuntu-stable-slim would compute os=ubuntu,
#     channel=stable and claim ubuntu-stable's tags -- overwriting them in the
#     public registry. Checked by reassembling and comparing to $*, not by a
#     case/glob: a shell `*` matches '-' too, so no bracket-class pattern can
#     exclude extra segments.
#  2. $version contains a '-' at all. $${version\#*-} returns the string
#     UNCHANGED when it contains none, so a one-axis version like 13.0.0 would
#     set av=tv=13.0.0, pass guard 3 twice, and publish alpine-13.0.0 -- a tag
#     shaped like a version tag that names only one of the two axes.
#  3. Both halves are X.Y.Z. Checked separately: because a glob `*` matches
#     '-', that same pattern applied to the composite matches 13.0.0 alone.
#     Splitting on the FIRST '-' is safe in both directions -- an Ansible
#     bundle version is always X.Y.Z and never contains a '-', so a Terraform
#     -beta/-rc suffix can only ever land in tv.
#  4. The messages name the image and say "derive the tag set" rather than
#     "tag", because this now fires from push-% too, where nothing is tagged
#     and $version came from a label rather than from two containers.
TAG_SET_SH = os="$(word 1,$(subst -, ,$*))"; \
             channel="$(word 2,$(subst -, ,$*))"; \
             if [ -z "$$os" ] || [ -z "$$channel" ] || [ "$$os-$$channel" != "$*" ]; then \
               echo "ERROR: $(LOCAL_IMAGE):$*: variant stem is not exactly two non-empty '-'-separated words (<os>-<channel>); refusing to derive the tag set, since word 1/word 2 would silently drop the rest and could overwrite another variant's tags" >&2; \
               exit 1; \
             fi; \
             case "$$version" in \
               *-*) ;; \
               *) echo "ERROR: $(LOCAL_IMAGE):$*: version '$$version' contains no '-'; refusing to derive the tag set from a version naming only one of the two axes" >&2; exit 1 ;; \
             esac; \
             av="$${version%%-*}"; \
             tv="$${version\#*-}"; \
             case "$$av" in \
               [0-9]*.[0-9]*.[0-9]*) ;; \
               *) echo "ERROR: $(LOCAL_IMAGE):$*: Ansible bundle version '$$av' is not X.Y.Z; refusing to derive the tag set" >&2; exit 1 ;; \
             esac; \
             case "$$tv" in \
               [0-9]*.[0-9]*.[0-9]*) ;; \
               *) echo "ERROR: $(LOCAL_IMAGE):$*: Terraform version '$$tv' is not X.Y.Z; refusing to derive the tag set" >&2; exit 1 ;; \
             esac; \
             tags="$* $$os-$$version"; \
             if [ "$$channel" = stable ]; then tags="$$tags $$os"; fi; \
             if [ "$*" = "$(LATEST_VARIANT)" ]; then tags="$$tags latest"; fi
```

- [ ] **Step 4: Prove the tag math before building anything**

Run the snippet's logic standalone, against every version form these variants can produce plus the malformed ones the guards exist for:

```bash
for v in 13.0.0-1.15.8 14.2.0-1.16.0-beta2 14.2.0-1.16.0-beta.2 13.0.0 13.0.0-1.15 13.0-1.15.8 -1.15.8 ""; do
  case "$v" in
    *-*) ;;
    *) printf '%-22s REJECTED guard 2 (no "-")\n' "'$v'"; continue ;;
  esac
  av="${v%%-*}"; tv="${v#*-}"
  case "$av" in [0-9]*.[0-9]*.[0-9]*) ;;
    *) printf '%-22s REJECTED guard 3 (av=%s)\n' "'$v'" "'$av'"; continue ;; esac
  case "$tv" in [0-9]*.[0-9]*.[0-9]*) ;;
    *) printf '%-22s REJECTED guard 3 (tv=%s)\n' "'$v'" "'$tv'"; continue ;; esac
  printf '%-22s ACCEPTED  tag=alpine-%s\n' "'$v'" "$v"
done
```

Expected exactly:

```
'13.0.0-1.15.8'        ACCEPTED  tag=alpine-13.0.0-1.15.8
'14.2.0-1.16.0-beta2'  ACCEPTED  tag=alpine-14.2.0-1.16.0-beta2
'14.2.0-1.16.0-beta.2' ACCEPTED  tag=alpine-14.2.0-1.16.0-beta.2
'13.0.0'               REJECTED guard 2 (no "-")
'13.0.0-1.15'          REJECTED guard 3 (tv='1.15')
'13.0-1.15.8'          REJECTED guard 3 (av='13.0')
'-1.15.8'              REJECTED guard 3 (av='')
''                     REJECTED guard 2 (no "-")
```

The five REJECTED lines are the point. `'13.0.0'` in particular is the guard neither sibling repo needs: without guard 2 it reaches guard 3 with `av` and `tv` both set to `13.0.0`, passes, and produces a plausible-looking one-axis tag.

- [ ] **Step 5: Prove the variant guard, which now fires from two callers**

Guard 1 moved out of `version-tag-%` and into `TAG_SET_SH`, so it must still reject a malformed stem — and must do so from `push-%` as well, where nothing is being tagged:

```bash
for stem in alpine-stable ubuntu-stable-slim alpine "" a-b-c; do
  os="${stem%%-*}"
  channel="$(printf '%s' "$stem" | cut -s -d- -f2)"
  if [ -z "$os" ] || [ -z "$channel" ] || [ "$os-$channel" != "$stem" ]; then
    printf '%-22s REJECTED guard 1\n' "'$stem'"
  else
    printf '%-22s ACCEPTED os=%s channel=%s\n' "'$stem'" "$os" "$channel"
  fi
done
```

Expected exactly:

```
'alpine-stable'        ACCEPTED os=alpine channel=stable
'ubuntu-stable-slim'   REJECTED guard 1
'alpine'               REJECTED guard 1
''                     REJECTED guard 1
'a-b-c'                REJECTED guard 1
```

`ubuntu-stable-slim` is the case that matters: without the guard it computes `os=ubuntu`, `channel=stable`, and claims `ubuntu-stable`'s tags — `ubuntu`, `latest` included — overwriting them in the public registry.

Then confirm the guard's message suits both callers:

```bash
grep -n 'refusing to derive the tag set' Makefile
```

Expected: exactly four lines, all `echo "ERROR: ...` and all naming `$(LOCAL_IMAGE):$*`. From `push-%` nothing is being tagged, so "refusing to tag" would be wrong there.

Match on `refusing to derive the tag set`, not on `derive the tag set` alone: the explanatory comment above `TAG_SET_SH` contains the shorter phrase too, so the looser pattern returns five lines and a `head -4` would silently drop one of the real messages.

- [ ] **Step 6: Rename `version-tag-%` to `tag-%` and apply the full set**

Replace the whole `version-tag-%` target — comment block included, since most of it now lives in `TAG_SET_SH` — with:

```make
# Read BOTH versions out of the freshly built image, join them into one
# composite version, stamp it on as a label, and apply the full tag set, so no
# tag can drift from what is installed.
#
#  * `ansible-community --version` prints the BUNDLE version ("Ansible
#    community version 13.0.0"). NOT `ansible --version`, which reports core
#    (2.20.x) -- a different number that is not what these tags mean.
#  * `terraform version` prints "Terraform v1.15.8" on its first line; the
#    leading v is stripped.
#
# Both versions appear in the tag because either can move independently: a
# rebuild picking up a newer Ansible with the same Terraform would otherwise
# silently reuse a tag.
#
# The composite is carried WHOLE from here to push-% via the label. The shape
# checks that used to live in this recipe are now in TAG_SET_SH, so both
# callers get them.
tag-%:
	@set -eu; \
	av=$$($(PODMAN) run --rm $(LOCAL_IMAGE):$* ansible-community --version | $(AWK) 'NR==1{print $$NF}'); \
	tv=$$($(PODMAN) run --rm $(LOCAL_IMAGE):$* terraform version | $(AWK) 'NR==1{print $$NF}'); \
	tv=$${tv#v}; \
	version="$$av-$$tv"; \
	$(TAG_SET_SH); \
	printf 'FROM %s:%s\nLABEL org.opencontainers.image.version="%s"\n' "$(LOCAL_IMAGE)" "$*" "$$version" \
	  | $(PODMAN) build -f - -t "$(LOCAL_IMAGE):$*" .; \
	for t in $$tags; do $(PODMAN) tag "$(LOCAL_IMAGE):$*" "$(LOCAL_IMAGE):$$t"; done; \
	echo "Tagged $(LOCAL_IMAGE): $$tags"
```

Two things this recipe deliberately does **not** do:

- It no longer passes `-t "$(LOCAL_IMAGE):$$os-$$av-$$tv"` to the label build. The build produces one image under `$*`, and `podman tag` fans it out — which is what makes a variable-length tag list possible.
- It does **not** pass `$(PODMAN_BUILD_FLAGS)` to that label build. Adding `--pull` there would make podman try to pull `localhost/ansible-terraform:<variant>` from a registry. `PODMAN_BUILD_FLAGS` belongs to `build-%` only.

- [ ] **Step 7: Update the reference to the old target name**

In `build-%`, change the last line from `@$(MAKE) --no-print-directory version-tag-$*` to:

```make
	@$(MAKE) --no-print-directory tag-$*
```

Confirm nothing else names the old target:

```bash
grep -n 'version-tag' Makefile || echo "no references to the old name — correct"
```

Expected: `no references to the old name — correct`.

- [ ] **Step 8: Build and verify all eleven tags**

```bash
make clean
make build
podman images --format '{{.Repository}}:{{.Tag}}' | grep ansible-terraform | sort
```

Expected exactly eleven, all `localhost/ansible-terraform:` — `alpine`, `alpine-13.0.0-1.15.8`, `alpine-14.2.0-1.16.0-beta2`, `alpine-development`, `alpine-stable`, `latest`, `ubuntu`, `ubuntu-13.1.0-1.15.8`, `ubuntu-14.2.0-1.16.0-beta2`, `ubuntu-development`, `ubuntu-stable`. Version components will differ if the upstreams have moved; the count and the shapes must not.

- [ ] **Step 9: Verify the tags point where they should**

```bash
echo "--- ubuntu-stable group (expect 4 identical) ---"
podman inspect --format '{{.Id}}' \
  localhost/ansible-terraform:ubuntu-stable \
  localhost/ansible-terraform:ubuntu \
  localhost/ansible-terraform:latest \
  localhost/ansible-terraform:ubuntu-13.1.0-1.15.8
echo "--- alpine-stable group (expect 3 identical) ---"
podman inspect --format '{{.Id}}' \
  localhost/ansible-terraform:alpine-stable \
  localhost/ansible-terraform:alpine \
  localhost/ansible-terraform:alpine-13.0.0-1.15.8
echo "--- development variants (expect 2 identical, then 2 identical) ---"
podman inspect --format '{{.Id}}' \
  localhost/ansible-terraform:alpine-development \
  localhost/ansible-terraform:alpine-14.2.0-1.16.0-beta2 \
  localhost/ansible-terraform:ubuntu-development \
  localhost/ansible-terraform:ubuntu-14.2.0-1.16.0-beta2
```

Expected: identical IDs within each group, and all four groups different from one another. In particular `latest` must share an ID with `ubuntu-stable` and **not** with either development variant.

- [ ] **Step 10: Verify no intermediate or single-axis tag was created**

```bash
podman images --format '{{.Repository}}:{{.Tag}}' \
  | grep -E '^localhost/ansible-terraform:(alpine|ubuntu)-(1[0-9]|1\.[0-9]+)(-1\.[0-9]+)?$' \
  && echo "FAIL: an intermediate or single-axis tag exists" \
  || echo "no intermediate or single-axis tags — correct"
```

Expected: `no intermediate or single-axis tags — correct`. The pattern catches all three forbidden shapes: single-axis `alpine-13`, single-axis `alpine-1.15`, and composite-line `alpine-13-1.15`. The legitimate version tags survive it because they carry a full `X.Y.Z` on both sides.

Also confirm the eight baseline tags all survived — the new scheme is a superset, not a replacement:

```bash
comm -23 /tmp/at-tags-before.txt <(podman images --format '{{.Repository}}:{{.Tag}}' | grep ansible-terraform | sort)
```

Expected: no output. Any line printed is a tag that used to exist and no longer does, which is a regression.

- [ ] **Step 11: Confirm the smoke tests still pass**

```bash
make test
```

Expected: all four variants PASS. `test-%` is unchanged, but `build-%` now calls a renamed target, so this proves the chain is intact.

- [ ] **Step 12: Commit**

```bash
git add Makefile
git commit -m "Apply the full tag set: channel, os, version, and latest

Renames version-tag-% to tag-%, which now computes the whole tag set rather
than only the version tag, via a TAG_SET_SH snippet shared with the push
target to come, so the scheme is defined once.

Eleven tags, not the siblings' fifteen and seven. There is deliberately no
intermediate tag: a single-axis tag would assert nothing about half the image,
and a composite line tag would move on exactly the same builds as the channel
tag beside it.

The composite <ansible>-<terraform> version is carried whole and split only to
validate. That split needs a guard neither sibling has: \${version#*-} returns
the string unchanged when it contains no '-', so a one-axis version would set
both halves equal, pass both shape checks, and publish a version tag naming
only one axis."
```

---

### Task 2: Push targets

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Consumes: `$(TAG_SET_SH)`, `$(LOCAL_IMAGE)`, `$(REGISTRY)`, and the `org.opencontainers.image.version` label applied by `tag-%`.
- Produces: `push-<variant>` and `push` targets. Task 3's workflow calls `make push-<variant>`.

- [ ] **Step 1: Add the push recipe**

Insert after `test-%`, before `clean`:

```make
# Mirror every tag in the set to $(REGISTRY). Depends on test-%, so a
# smoke-test failure blocks the publish and a broken image cannot reach the
# registry through this path.
#
# That guarantee holds only within ONE make invocation: build-%/test-%/push-%
# match no real files, so a second, separate `make` in the same job re-runs the
# whole chain rather than seeing it as satisfied. This is why the workflow
# calls make exactly once per job.
#
# The version is read back off the label tag-% applied rather than by running
# the containers again -- an inspect, not two container starts.
#
# The push source is explicitly localhost-qualified ($(LOCAL_IMAGE)), not a
# bare short name -- a bare name can resolve to a non-localhost repo when
# that's the only match, which would make this, the highest-stakes line in the
# repo, depend on an implicit tie-break. podman push SOURCE DESTINATION never
# creates a registry-qualified local tag, so `clean` keeps matching the
# complete set.
#
# Not atomic: a failure partway through the loop leaves the earlier tags in
# this run already published and the remaining ones stale. The failure is loud
# (non-zero exit), which is the requirement, but it is not a rollback.
push-%: test-%
	@set -eu; \
	version=$$($(PODMAN) image inspect \
	  --format '{{index .Labels "org.opencontainers.image.version"}}' $(LOCAL_IMAGE):$*); \
	$(TAG_SET_SH); \
	for t in $$tags; do \
	  echo "Pushing $(REGISTRY)/$(IMAGE):$$t"; \
	  $(PODMAN) push "$(LOCAL_IMAGE):$$t" "$(REGISTRY)/$(IMAGE):$$t"; \
	done

push: $(addprefix push-,$(VARIANTS))
```

- [ ] **Step 2: Add `push` to `.PHONY` and to `help`**

Change the `.PHONY` line to:

```make
.PHONY: help build test push clean
```

In `help`, add a `push` line after `test` and a `push-$(v)` to the foreach:

```make
	@echo "  build                 Build all variants"
	@echo "  test                  Smoke-test all variants"
	@echo "  push                  Push all variants to $(REGISTRY)/$(IMAGE)"
	@echo "  clean                 Remove all tagged images built by this repo"
	@$(foreach v,$(VARIANTS),echo "  build-$(v)"; echo "  test-$(v)"; echo "  push-$(v)";)
```

Leave the existing `--pull` advisory at the bottom of `help` exactly as it is.

- [ ] **Step 3: Verify help lists the new targets**

```bash
make help
```

Expected: a `push` line naming `docker.io/pdutton/ansible-terraform`, and a `push-<variant>` line for each of the four.

- [ ] **Step 4: Confirm push depends on test**

```bash
make -n push-alpine-stable | head -5
```

Expected: the output begins with the `podman build -f Containerfile.alpine-stable` command — proving `push-alpine-stable` pulls in `test-alpine-stable` → `build-alpine-stable`, so a broken image cannot be published through this path.

- [ ] **Step 5: Push for real, to a throwaway local registry**

This is the real verification. It needs no credentials and touches no public registry.

```bash
podman run -d --rm -p 127.0.0.1:5000:5000 --name at-test-registry docker.io/library/registry:2
sleep 3

# Podman refuses plain HTTP by default; allow it for this one registry via an
# env-scoped config rather than changing the Makefile.
cat > /tmp/at-registries.conf <<'EOF'
[[registry]]
location = "localhost:5000"
insecure = true
EOF

CONTAINERS_REGISTRIES_CONF=/tmp/at-registries.conf make push REGISTRY=localhost:5000
```

Expected: eleven `Pushing localhost:5000/ansible-terraform:<tag>` lines across the four variants, and no error.

- [ ] **Step 6: Confirm the registry received exactly the right tags**

```bash
curl -s http://localhost:5000/v2/ansible-terraform/tags/list | tr ',' '\n'
```

Expected exactly eleven tags: the four `<os>-<channel>`, the four `<os>-<ansible>-<terraform>`, `alpine`, `ubuntu`, `latest` — and **no** `alpine-13`, `ubuntu-14`, `alpine-1.15`, or `alpine-13-1.15`.

- [ ] **Step 7: Confirm push created no registry-qualified local tags**

```bash
podman images --format '{{.Repository}}:{{.Tag}}' | grep -c '^localhost:5000/' || echo "0 — none, as expected"
podman images --format '{{.Repository}}:{{.Tag}}' | grep -c '^localhost/ansible-terraform:'
```

Expected: `0 — none, as expected`, then `11`. If the push had created local registry-qualified tags, `clean` would no longer match the complete set.

- [ ] **Step 8: Confirm a failing smoke test blocks the push**

Temporarily break the smoke test, prove the push does not happen, then restore it:

```bash
cp test/smoke.yml /tmp/at-smoke.yml.bak
printf '\n- hosts: localhost\n  gather_facts: false\n  tasks:\n    - fail: msg="deliberate"\n' >> test/smoke.yml
CONTAINERS_REGISTRIES_CONF=/tmp/at-registries.conf make push-alpine-stable REGISTRY=localhost:5000; echo "exit=$?"
cp /tmp/at-smoke.yml.bak test/smoke.yml
git diff --stat test/smoke.yml
```

Expected: a non-zero `exit=`, no `Pushing` line in the output at all, and an empty `git diff --stat` after the restore. **`test/smoke.yml` must be byte-identical to `master` when this step finishes** — if `git diff` shows anything, restore it from git before continuing.

- [ ] **Step 9: Tear down the test registry**

```bash
podman stop at-test-registry
rm -f /tmp/at-registries.conf
podman ps
```

Confirm the registry container is gone.

- [ ] **Step 10: Commit**

```bash
git add Makefile
git commit -m "Add push targets mirroring the tag set to the registry

push-% depends on test-%, so a smoke-test failure blocks the publish and a
broken image cannot reach the registry through this path. The version is read
off the label tag-% applied rather than by starting the containers again.

Not atomic: a failure partway through the loop leaves earlier tags published
and the rest stale. Loud, but not a rollback."
```

---

### Task 3: The workflow and the Docker Hub page

These ship together: the `dockerhub-description` job reads `DOCKERHUB-OVERVIEW.md`, so the workflow would reference a missing file if they were split.

**Files:**
- Create: `.github/workflows/build.yml`
- Create: `DOCKERHUB-OVERVIEW.md`

**Interfaces:**
- Consumes: `make test-<variant>` and `make push-<variant>` from Tasks 1–2, and `PODMAN_BUILD_FLAGS` which already exists.
- Produces: repository secrets contract — `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` must exist before the first merge to `master`.

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/build.yml` with exactly this content:

```yaml
name: build

on:
  pull_request:
  push:
    branches: [master]
  workflow_dispatch:

# Nothing here writes to the repository.
permissions:
  contents: read

# Cancel superseded pull-request runs, but let a master push finish -- a
# cancellation mid-push would leave a variant's tag set half-updated in the
# registry.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  build:
    name: ${{ matrix.variant }}
    runs-on: ubuntu-latest
    strategy:
      # One variant's failure must not stop the other three from publishing.
      # Unlike container-terraform, no variant here fails by design, so this is
      # prudence rather than a load-bearing guard.
      fail-fast: false
      matrix:
        variant:
          - alpine-stable
          - alpine-development
          - ubuntu-stable
          - ubuntu-development

    steps:
      # v7 runs on Node.js 24. v4 targets Node.js 20, which is deprecated, and
      # the runner forces it onto 24 anyway while emitting a warning on every
      # job.
      - uses: actions/checkout@v7

      # Default checkout depth is fine: the Makefile's `git rev-parse HEAD`
      # works at depth 1.

      - name: Ensure podman
        run: |
          if ! command -v podman >/dev/null; then
            sudo apt-get update
            sudo apt-get install -y podman
          fi
          # The Makefile defaults to absolute tool paths; fail loudly here
          # rather than with a confusing "no such file" mid-build.
          test -x /usr/bin/podman
          test -x /usr/bin/awk
          podman --version

      # Both make invocations below pass --pull. Neither FROM line's TEXT
      # changes when an upstream republishes, so without it podman reuses
      # cached layers and reproduces a previous image while both inputs have
      # moved. On an ephemeral runner with no image store that cache does not
      # exist and both bases are fetched fresh anyway, so --pull is
      # belt-and-braces here rather than a fix for a live bug. It is passed
      # regardless, so freshness is a property of this workflow rather than of
      # the runner's disposability -- and so the command below is exactly the
      # one a developer runs to reproduce a CI publish locally, where the cache
      # very much does bite.
      #
      # Publishing happens only from master. A dispatch against another branch
      # still builds and smoke-tests, so a branch can be put through CI, but it
      # must never overwrite the shared mutable tags (latest, alpine, ubuntu)
      # with unreviewed code. This condition is the exact negation of the
      # publish condition below -- if it were merely the pull_request check, a
      # dispatch from a feature branch would match no step at all and the job
      # would silently pass having done nothing.
      - name: Build and smoke-test
        if: github.event_name == 'pull_request' || github.ref != 'refs/heads/master'
        run: make test-${{ matrix.variant }} PODMAN_BUILD_FLAGS="--pull"

      - name: Log in to Docker Hub
        if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
        env:
          DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
          DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
        run: printf '%s' "$DOCKERHUB_TOKEN" | podman login docker.io -u "$DOCKERHUB_USERNAME" --password-stdin

      # One invocation, not two: push-<variant> depends on test-<variant> which
      # depends on build-<variant>, so this builds, smoke-tests, and publishes.
      # Running `make test-` in a separate step first would repeat the whole
      # chain -- these pattern targets match no real file, so Make re-runs them
      # on every invocation.
      - name: Build, smoke-test, and push
        if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
        run: make push-${{ matrix.variant }} PODMAN_BUILD_FLAGS="--pull"

  # Docker Hub does not read anything from this repo on its own, so the overview
  # page would otherwise drift from DOCKERHUB-OVERVIEW.md the moment either is
  # edited alone. Same master-only guard as the publish steps above: the page is
  # shared by every consumer and a branch build must not rewrite it.
  #
  # Separate job rather than a fifth step, because the build job is a matrix of
  # four variants and this must run exactly once. `needs: build` waits for all
  # four legs, so a broken build leaves the old page in place rather than
  # advertising images that were never published.
  description:
    name: dockerhub-description
    runs-on: ubuntu-latest
    needs: build
    if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'

    steps:
      - uses: actions/checkout@v7

      # The short description is set here too, so the whole Hub page is
      # declarative -- leaving it unset would silently preserve whatever was
      # last typed into the web UI.
      # Pinned by SHA, not by tag: this is the only third-party action here and
      # it is handed a Docker Hub token with write/delete scope. A tag is a
      # mutable pointer in someone else's repository -- repointing v5 would run
      # new code against that secret with no change on this side.
      # actions/checkout stays on a major tag; it is inside GitHub's own trust
      # boundary.
      - uses: peter-evans/dockerhub-description@1b9a80c056b620d92cedb9d9b5a223409c68ddfa # v5.0.0
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
          repository: pdutton/ansible-terraform
          readme-filepath: ./DOCKERHUB-OVERVIEW.md
          short-description: "Ansible and Terraform together, ready to run without installing either"
```

- [ ] **Step 2: Verify the YAML parses**

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/build.yml')); print(sorted(d['jobs'])); print(d['jobs']['build']['strategy']['matrix']['variant'])"
```

Expected: `['build', 'description']` and the four variant names.

Note: `yaml.safe_load` turns the bare `on:` key into Python `True` — that is a known YAML 1.1 quirk, not a problem with the file. **Do not "fix" it by quoting `on:`.**

- [ ] **Step 3: Verify the two conditions are exact negations**

```bash
python3 - <<'EOF'
def test(ev, ref):
    return (ev == 'pull_request' or ref != 'refs/heads/master',
            ev != 'pull_request' and ref == 'refs/heads/master')
for ev, ref in [('pull_request','refs/heads/feature/x'),
                ('push','refs/heads/master'),
                ('workflow_dispatch','refs/heads/master'),
                ('workflow_dispatch','refs/heads/feature/x')]:
    t, p = test(ev, ref)
    assert t != p, f"BROKEN: {ev} {ref} -> test={t} push={p}"
    print(f"{ev:20} {ref:26} {'test' if t else 'push'}")
EOF
```

Expected — exactly one action per row, never both, never neither:

```
pull_request         refs/heads/feature/x       test
push                 refs/heads/master          push
workflow_dispatch    refs/heads/master          push
workflow_dispatch    refs/heads/feature/x       test
```

- [ ] **Step 4: Run actionlint if available**

```bash
command -v actionlint >/dev/null && actionlint .github/workflows/build.yml || echo "actionlint not installed — skipping"
```

Expected: no findings, or the skip message.

- [ ] **Step 5: Create the Docker Hub overview page**

Create `DOCKERHUB-OVERVIEW.md` with exactly this content:

````markdown
# pdutton/ansible-terraform

Run Ansible and Terraform together without installing either — a small container image carrying
both, on Alpine or Ubuntu.

## Usage

### As a Command

To use it as a drop in replacement for either tool, alias it and use it like a local install
(mounts your keys read-only and the current directory):

```bash
alias terraform='docker run -ti --rm -v "$PWD":/apps -w /apps pdutton/ansible-terraform terraform'
alias ansible-playbook='docker run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps pdutton/ansible-terraform ansible-playbook'

terraform init
ansible-playbook -i inventory site.yml
```

### Base Image

Use it as a base image:

```dockerfile
FROM pdutton/ansible-terraform:ubuntu-stable
COPY playbooks/ /apps/
```

## Useful Tags

The image builds on two operating systems and two channels at a time, yielding four images. The
`stable` variants carry a final Terraform release; the `development` variants carry a `-beta` or
`-rc` alongside a newer Ansible. The alpine variants are lightweight but lack WinRM and Kerberos
support — use the ubuntu variants if you need those, or if you need glibc to extend the image.

| Tag | Aliases |
|-----|---------|
| `alpine-stable`      | `alpine` |
| `alpine-development` |          |
| `ubuntu-stable`      | `latest`, `ubuntu` |
| `ubuntu-development` |                    |

## Source

Built from
[github.com/pdutton/container-ansible-terraform](https://github.com/pdutton/container-ansible-terraform)
— full documentation, Containerfiles, and CI live there.

Nothing is installed here. The Ansible base comes from
[pdutton/ansible](https://hub.docker.com/r/pdutton/ansible) and the Terraform binary from
[pdutton/terraform](https://hub.docker.com/r/pdutton/terraform); this image composes the two.

## Intended Audience

Feel free to use this container image for personal use or learning Ansible and Terraform.
If you create useful container images based off of this image, please share the code you used to
produce it so everyone can benefit.

The code in this repository is licensed under GPL-3.0-or-later, but
**Terraform itself is not open source.** It is licensed under the Business Source License 1.1.
You must comply with _both_ licenses when using and extending this container image.
````

**Do not add version numbers, Ansible bundle versions, or Terraform lines to this file.** Nothing cross-checks it against the README or against a build, so it is the one document here that no test can catch drifting. The tag table above is alias-shaped for exactly that reason.

- [ ] **Step 6: Confirm the overview carries no drift-capable content**

```bash
grep -nE '[0-9]+\.[0-9]+\.[0-9]+|1\.1[0-9]|Ansible 1[0-9]|3\.2[0-9]|26\.04' DOCKERHUB-OVERVIEW.md \
  && echo "FAIL: a version number leaked into the Hub page" \
  || echo "no version numbers — correct"
```

Expected: `no version numbers — correct`. (`BUSL 1.1` and `GPL-3.0-or-later` are license names, not versions, and do not match these patterns.)

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/build.yml DOCKERHUB-OVERVIEW.md
git commit -m "Add CI building, testing, and publishing the four variants

Builds and smoke-tests on pull requests; builds, smoke-tests and publishes on a
push to master or a workflow_dispatch run against master. The two step
conditions are exact negations, so every run does exactly one of the two.

Both make invocations pass --pull. On an ephemeral runner it is
belt-and-braces, since there is no image store to go stale; it is passed so
freshness is a property of the workflow rather than of the runner, and so the
CI command is the one that reproduces a publish locally.

The Hub overview page is synced from DOCKERHUB-OVERVIEW.md by a SHA-pinned
third-party action -- it is handed a token with write/delete scope, and a tag
is a mutable pointer in someone else's repository."
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `.dockerignore`

**Interfaces:**
- Consumes: every target and tag name from Tasks 1–3. No code depends on this task.

- [ ] **Step 1: Add the CI badge**

In `README.md`, immediately after the `# container-ansible-terraform` heading, insert a blank line and:

```markdown
[![build](https://github.com/pdutton/container-ansible-terraform/actions/workflows/build.yml/badge.svg)](https://github.com/pdutton/container-ansible-terraform/actions/workflows/build.yml)
```

- [ ] **Step 2: Point the usage examples at the published image**

In the "Ansible and Terraform Without Installing" section, change both alias bodies from `localhost/ansible-terraform:alpine-stable` to `docker.io/pdutton/ansible-terraform:alpine-stable`. Leave the surrounding prose about `"$PWD"` and SELinux untouched.

- [ ] **Step 3: Add the Published Images section**

In "Image Variants", immediately after the line beginning `Locally built images are referenced as`, add:

```markdown
### Published Images

Images are published to
[`pdutton/ansible-terraform`](https://hub.docker.com/r/pdutton/ansible-terraform) on Docker Hub:

```bash
podman pull docker.io/pdutton/ansible-terraform:alpine-stable
```

Or, with Docker:

```bash
docker pull pdutton/ansible-terraform:latest
```

A local build carries the identical tag set.
```

- [ ] **Step 4: Rewrite the Tags section**

Replace the whole `## Tags` section — from the `## Tags` heading through the line `**These images are not published to any registry.** Both upstreams publish to Docker Hub; this repo does not yet.` — with:

````markdown
## Tags

Eleven tags exist after a full build. Version components below are examples current as of
2026-08-09 and drift.

| Tag | Resolves to |
|---|---|
| `latest` | `ubuntu-stable` — the variant with no capability gaps, on the channel whose Terraform is a final release |
| `ubuntu`, `alpine` | that OS's `stable` variant |
| `<os>-stable`, `<os>-development` | newest build of that channel on that OS. Stable across rebuilds; use this in scripts and aliases |
| `<os>-<ansible>-<terraform>` — e.g. `alpine-13.0.0-1.15.8` | newest build of that exact pair of versions |

Both versions appear in the version tag because either can move independently — a rebuild picking
up a newer Ansible with the same Terraform would otherwise silently reuse a tag. Both are derived
at build time by reading them out of the freshly built image, so they always reflect what is
actually installed. You can read either value yourself:

```bash
podman run --rm docker.io/pdutton/ansible-terraform:alpine-stable ansible-community --version
podman run --rm docker.io/pdutton/ansible-terraform:alpine-stable terraform version
```

The eleven tags after a full build:

```
alpine-stable        alpine-13.0.0-1.15.8          alpine
alpine-development   alpine-14.2.0-1.16.0-beta2
ubuntu-stable        ubuntu-13.1.0-1.15.8          ubuntu   latest
ubuntu-development   ubuntu-14.2.0-1.16.0-beta2
```

### There is deliberately no intermediate tag

container-ansible publishes `<os>-<major>` and container-terraform publishes `<line>`, between
their channel tag and their version tag. This repo publishes no equivalent — no `alpine-13-1.15`,
and no single-axis `alpine-13` or `alpine-1.15`.

Two versions move independently here, and neither candidate survives that. A **single-axis** tag
would not name an image: `alpine-13` would have to mean "Alpine, Ansible 13, and whatever Terraform
was wired to the stable channel that day", silently asserting nothing about half the image, on a
short tag people would reach for first. A **composite line** tag such as `alpine-13-1.15` is
unambiguous but moves on exactly the same builds as `alpine-stable`, which is already the tag for
"newest build of that channel".

So every tag here either names a channel or names both versions exactly.

### Every tag is mutable, including the version tags

`alpine-13.0.0-1.15.8` looks like a pin. It is not. A rebuild that again resolves to that pair
re-pushes the tag at a *new* image — and here that is not merely a base-OS package refresh but a
wholly new composition, since both `FROM` lines are other repos' published tags and either can have
moved underneath an unchanged version number.

This is deliberate — it is how an upstream fix reaches someone who pinned a version — but it means
this repo publishes no content-immutable tag at all. **If you need reproducibility, pin by
digest**, which you can capture without a prior local pull:

```bash
skopeo inspect --format '{{.Digest}}' docker://docker.io/pdutton/ansible-terraform:alpine-stable
```
````

- [ ] **Step 5: Add `make push` to Building Locally**

In "Building Locally", replace the command block with:

```bash
make build                 # build all four variants
make test                  # smoke-test all four variants
make push                  # build, test, and publish all four to Docker Hub
make build-alpine-stable   # build just one variant
make clean                 # remove all tagged images this repo builds
```

and add this paragraph immediately after the `make help` paragraph that follows it:

```markdown
`make build` applies the complete tag set locally, so a local build and a published one leave
identical tag state — which is what makes a CI publish reproducible on your own machine.
`push-<variant>` depends on `test-<variant>`, so a failing smoke test blocks the publish.
Publishing requires `podman login docker.io` first; override the destination with
`make push REGISTRY=ghcr.io/pdutton`. Publishing normally happens in CI on a merge to `master`,
not from a developer's machine.
```

- [ ] **Step 6: Add the Continuous Integration section**

Insert a new section immediately before `## License`:

```markdown
## Continuous Integration

`.github/workflows/build.yml` builds and smoke-tests all four variants in parallel on every pull
request, and additionally publishes them on a push to `master` or a `workflow_dispatch` run against
`master`. Pull requests never receive registry credentials and never push.

Publishing only ever happens from `master`. A manual `workflow_dispatch` run against another branch
still builds and smoke-tests that branch, but publishes nothing — the tags here are mutable
pointers shared by every consumer, and a branch build must not be able to overwrite them by
accident. (This is an accident guard, not a security boundary: `workflow_dispatch` runs the
workflow file from the selected ref, so a branch that also edits the `if:` conditions could still
publish.)

Publishing needs two repository secrets, `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`, which the
workflow feeds to `podman login docker.io`. A local `make push` needs the equivalent done by hand.

CI builds pass `--pull`, so a CI publish always re-resolves both upstream images rather than
reusing a cached layer. There is no scheduled rebuild, though: these images are composed entirely
of upstream tags, so both inputs can move without anything in this repo changing, and a published
image can sit arbitrarily far behind both. Refreshing them is a deliberate act — merge to `master`,
or run the workflow from the Actions tab.

### The Docker Hub overview page

The page at [`pdutton/ansible-terraform`](https://hub.docker.com/r/pdutton/ansible-terraform) is
generated from `DOCKERHUB-OVERVIEW.md` by the `dockerhub-description` job in the same workflow.
**Do not edit that page in the Docker Hub web UI** — the next push to `master` overwrites it, along
with the short description, which the job also sets.
```

- [ ] **Step 7: Remove the implemented items from Planned**

In `## Planned`, delete the first two bullets — the one beginning `Publishing these images to Docker Hub` and the one beginning `A tag scheme aligned with the upstreams'`. Keep the multi-arch and digest-pinning bullets exactly as they are.

Verify:

```bash
sed -n '/^## Planned/,$p' README.md
```

Expected: exactly two bullets remain, multi-arch and digest-pinning.

- [ ] **Step 8: Update CLAUDE.md's build block and add a Publishing section**

In the `## Build and test` block, add a `push` line:

```bash
make push                  # build, test, and publish all four to Docker Hub
```

Then insert a new `## Publishing` section immediately after the `### Rebuilds do not pick up republished upstreams` subsection:

```markdown
## Publishing

Images go to `docker.io/pdutton/ansible-terraform`. `REGISTRY` overrides the
destination; `LOCAL_IMAGE` (`localhost/$(IMAGE)`) is what every local reference
uses, and no bare `$(IMAGE)` may be introduced as an image reference — a bare
short name can resolve to a non-localhost repo, and the push source must not
depend on that.

The tag scheme lives in `TAG_SET_SH` in the Makefile and is expanded by both
`tag-%` and `push-%`, so it is defined once. Two per variant — channel and
`<os>-<ansible>-<terraform>` — plus `<os>` on the stable variants and `latest`
on `$(LATEST_VARIANT)`: **eleven across the four**.

**There is no intermediate tag** — no `alpine-13-1.15`, no single-axis
`alpine-13` or `alpine-1.15`. Two versions move independently here, so a
single-axis tag would assert nothing about half the image, and a composite line
tag would move on exactly the same builds as the channel tag beside it.

The composite `<ansible>-<terraform>` version is carried whole from `tag-%` to
`push-%` via the `org.opencontainers.image.version` label, and split only to
validate. That split needs a guard neither upstream has: `$${version\#*-}`
returns the string unchanged when it contains no `-`, so a one-axis version
would set both halves equal, pass both shape checks, and publish a version tag
naming one axis. The `#` in that expansion must stay escaped — unescaped, it
starts a Make comment and truncates the rest of `TAG_SET_SH` silently.

CI (`.github/workflows/build.yml`) builds and smoke-tests on pull requests and
publishes only from `master`. Both `make` invocations pass
`PODMAN_BUILD_FLAGS="--pull"`; on an ephemeral runner that is belt-and-braces,
but it makes the CI command the one that reproduces a publish locally.

The Docker Hub overview page is generated from `DOCKERHUB-OVERVIEW.md` by the
`dockerhub-description` job, which `needs: build` and so runs only when all four
variants published. Nothing on Docker Hub is authoritative — edits made in its
web UI are overwritten on the next push to `master`, short description included.
`DOCKERHUB-OVERVIEW.md` duplicates parts of `README.md` for an audience that
arrived without the repo; nothing cross-checks the two, so a change to the tag
scheme or the aliases must be applied to both by hand. It deliberately names no
version and no Ansible or Terraform line. Keep it that way — it is the one
document here that no test or build step can catch drifting.

See `docs/superpowers/specs/2026-08-09-dockerhub-publish-design.md` for the
authority on the tag scheme, the no-intermediate-tag rule, the non-atomic push,
and the registry coordinates. Read it before changing tags, the push, or CI.
```

- [ ] **Step 9: Update the renamed target in CLAUDE.md**

`## How versions are selected` names the old target and describes the old two-tag output. Replace its final paragraph — the one beginning `Tags are read out of the built image and never typed:` — with:

```markdown
Tags are read out of the built image and never typed: `tag-%` runs
`ansible-community --version` (the *bundle* version, not `ansible --version`,
which reports core) and `terraform version`, joins them into one composite
`<ansible>-<terraform>` version, and derives the whole tag set from it. See
Publishing above.
```

Then confirm the old name survives nowhere:

```bash
grep -rn 'version-tag' Makefile README.md CLAUDE.md || echo "no stale references to version-tag-% — correct"
```

Expected: `no stale references to version-tag-% — correct`.

- [ ] **Step 10: Make the hand-check a pre-merge step in CLAUDE.md**

The section `## Do not add version or channel assertions to the smoke test` keeps its position and its conclusion. Replace only its "accepted consequence" paragraph — the one beginning `The accepted consequence: nothing automated catches a miswired` — with:

```markdown
The accepted consequence, and it is larger now that this repo publishes:
nothing automated catches a miswired `COPY --from` pulling the wrong Terraform
channel. A `*-stable` Containerfile wrongly pointing at
`pdutton/terraform:development` publishes a prerelease as `ubuntu-stable`,
`ubuntu` and `latest`, and every gate on the path passes — the smoke test, the
shape guards, the tag math — because the version tag it produces is wrong but
perfectly self-consistent.

The mitigation is procedural. **Check by hand before merging**, not merely after
touching a Containerfile's `FROM` lines, because merging to `master` is what
publishes:
```

(The existing `for v in ...` verification loop and the two-sentence expectation that follows it stay exactly as they are.)

- [ ] **Step 11: Keep the new root files out of the build context**

Add to `.dockerignore`:

```
.github/
DOCKERHUB-OVERVIEW.md
docs/
```

`docs/` is already listed — do not duplicate it; add only the two new lines. Verify the file has no repeated entries:

```bash
sort .dockerignore | uniq -d
```

Expected: no output.

- [ ] **Step 12: Verify every README command actually works**

Run each command the README now tells a reader to run, except the ones needing Docker Hub credentials:

```bash
make help
podman run --rm localhost/ansible-terraform:alpine-stable ansible-community --version
podman run --rm localhost/ansible-terraform:alpine-stable terraform version
command -v skopeo >/dev/null && echo "skopeo present" || echo "skopeo absent — the README's digest example is untested here, which is fine"
```

Expected: `make help` lists the push targets; the two version commands print an Ansible bundle version and a `Terraform v...` line.

- [ ] **Step 13: Confirm the docs agree with reality**

The tag list in the README must match what a build actually produces:

```bash
podman images --format '{{.Repository}}:{{.Tag}}' \
  | sed -n 's|^localhost/ansible-terraform:||p' \
  | sort -u > /tmp/at-actual.txt
for t in alpine-stable alpine-development ubuntu-stable ubuntu-development alpine ubuntu latest; do
  grep -qx "$t" /tmp/at-actual.txt || echo "MISSING from build: $t"
done
wc -l < /tmp/at-actual.txt
```

Expected: no `MISSING` lines, then `11`.

The repository prefix in the `sed` is load-bearing, not tidiness. A bare `{{.Tag}}` listing spans every image on the machine, and a developer who has also built the sibling repos will have `localhost/terraform:latest` and `localhost/ansible:alpine` sitting there — so the check would pass while `ansible-terraform` produced none of those tags.

- [ ] **Step 14: Commit**

```bash
git add README.md CLAUDE.md .dockerignore
git commit -m "Document the published images, the eleven-tag scheme, and CI

Rewrites the Tags section around the published scheme, including why there is
no intermediate tag and the warning that every tag here is mutable -- version
tags included, and more so than upstream, since both FROM lines can move
underneath an unchanged version number.

CLAUDE.md gains a Publishing section, and its by-hand variant check becomes a
PRE-merge step: merging to master is now what publishes, so a miswired
COPY --from reaches latest."
```

---

### Task 5: Full verification and hand-back

**Files:** none modified.

- [ ] **Step 1: Clean-room rebuild**

```bash
make clean
podman images --format '{{.Repository}}:{{.Tag}}' | grep ansible-terraform || echo "clean — nothing left"
make test
```

Expected: `clean — nothing left`, then all four variants build and PASS.

- [ ] **Step 2: Confirm the eleven tags and their targets**

```bash
podman images --format '{{.Repository}}:{{.Tag}}' | grep -c '^localhost/ansible-terraform:'
podman inspect --format '{{.Id}}' \
  localhost/ansible-terraform:latest \
  localhost/ansible-terraform:ubuntu \
  localhost/ansible-terraform:ubuntu-stable
```

Expected: `11`, then three identical IDs.

- [ ] **Step 3: End-to-end push against a throwaway registry**

```bash
podman run -d --rm -p 127.0.0.1:5000:5000 --name at-test-registry docker.io/library/registry:2
sleep 3
cat > /tmp/at-registries.conf <<'EOF'
[[registry]]
location = "localhost:5000"
insecure = true
EOF
CONTAINERS_REGISTRIES_CONF=/tmp/at-registries.conf make push REGISTRY=localhost:5000
curl -s http://localhost:5000/v2/ansible-terraform/tags/list | tr ',' '\n' | sort
podman stop at-test-registry
rm -f /tmp/at-registries.conf
```

Expected: exactly eleven tags listed, matching the local set.

- [ ] **Step 4: Confirm `clean` still removes everything**

```bash
make clean
podman images --format '{{.Repository}}:{{.Tag}}' | grep '^localhost/ansible-terraform:' || echo "clean — all eleven removed"
```

Expected: `clean — all eleven removed`. This is the check that the push did not create registry-qualified local tags outside `clean`'s regex.

- [ ] **Step 5: Confirm the branch state**

```bash
git status --short
git log --oneline master..HEAD
git diff --stat master..HEAD
```

Expected: a clean working tree; six commits (the spec, this plan, and the four implementation commits); and a diff touching only `Makefile`, `.github/workflows/build.yml`, `DOCKERHUB-OVERVIEW.md`, `README.md`, `CLAUDE.md`, `.dockerignore`, and `docs/superpowers/`. **`Containerfile.*` and `test/smoke.yml` must not appear.**

- [ ] **Step 6: Hand back**

**Do not push the branch and do not open a pull request** — that is the human owner's call.

Report:

1. That the CI items can only be confirmed against live CI, which requires the workflow to be on `master` first. Treat them as post-merge verification; say so rather than claiming CI is verified.
2. That three prerequisites must exist **before** the first merge to `master`:
   - the public `pdutton/ansible-terraform` repository on Docker Hub,
   - a Docker Hub PAT with **write and delete** scope (delete is needed by `peter-evans/dockerhub-description`),
   - `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` as repository secrets, with the username matching the account in `REGISTRY`.
3. The post-merge checks from the spec: pull the tags back from Docker Hub — not from local cache — and confirm `latest`, `ubuntu`, `ubuntu-stable` and the ubuntu-stable version tag share one image ID; that `alpine`, `alpine-stable` and its version tag share another; that neither development variant is reachable as `latest`; that the smoke test passes against a pulled image; and that the Hub page matches `DOCKERHUB-OVERVIEW.md`, short description included.

---

## Notes for the implementer

- **Never introduce a bare `$(IMAGE)` as an image reference.** The only legitimate bare use is `clean`'s grep pattern, which matches podman output. Substituting `$(LOCAL_IMAGE)` there would produce `^(localhost/)?localhost/ansible-terraform:` and match nothing.
- **Never add an intermediate or single-axis tag**, however tempting the symmetry with the siblings' `<os>-<major>` and `<line>`.
- **Keep the `#` escaped** in `$${version\#*-}` inside `TAG_SET_SH`. Unescaped, it starts a Make comment and silently truncates the rest of the assignment — the failure looks like an empty `$tv`, not like a syntax error.
- **Do not remove guard 2** (the "contains a `-`" check) as redundant. It looks redundant next to the two shape checks and is not: `${version#*-}` returns the string unchanged when there is no `-`.
- **Do not pass `$(PODMAN_BUILD_FLAGS)` to the label build inside `tag-%`.** `--pull` there would send podman looking for `localhost/ansible-terraform:<variant>` in a registry.
- **Do not change `Containerfile.*` or `test/smoke.yml`.** If Task 2 Step 8 leaves `test/smoke.yml` modified, restore it from git before continuing. The smoke test's silence on versions is a recorded, deliberate decision — see the spec's "Accepted Risks" and CLAUDE.md.
- If a real Docker Hub push is attempted and fails for want of credentials, that is expected locally — use the throwaway registry, and let CI do the real thing.
- The spec is the authority. Where this plan and the spec disagree, stop and raise it rather than picking one.
