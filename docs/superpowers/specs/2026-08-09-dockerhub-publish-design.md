# Publishing Phase: Docker Hub and CI

**Date:** 2026-08-09
**Status:** Approved

**Pattern followed:** `container-ansible` and `container-terraform`, which both
gained this phase first. Where the three repos can agree they agree; every
divergence below is named and justified.

## Goal

Publish the four composed image variants to Docker Hub under a tag scheme whose
dynamic tags always resolve to the newest relevant build, and have GitHub Actions
run that build-test-publish cycle.

The Makefile learns the full tag set and how to push it; a workflow drives that
Makefile. **The tag scheme lives in the Makefile so it can be run and debugged
locally**, not in workflow YAML.

One change, four pieces:

- **Makefile** — full tag set applied locally, `push` / `push-%` targets.
- **`.github/workflows/build.yml`** — build and smoke-test on pull requests;
  build, smoke-test and publish from `master`.
- **`DOCKERHUB-OVERVIEW.md`** — new, synced to the Hub page from CI.
- **Documentation** — README and CLAUDE.md.

### Non-goals

Deliberately excluded, and to stay excluded until a later phase:

- **Multi-arch.** `linux/amd64` only. A multi-arch push publishes a manifest list
  rather than an image, and reading either version back out of an `arm64` image
  needs qemu. The README's "Planned" bullet stays.
- **Scheduled rebuilds.** No cron trigger. See "Accepted risks".
- **Digest-pinning the upstream base images.** Unchanged by this phase; the
  README's "Planned" bullet stays.
- **Release-tag triggers and signing** (cosign/sigstore).

## Registry Coordinates

| | |
|---|---|
| Repository | `docker.io/pdutton/ansible-terraform`, public |
| Local image name | `ansible-terraform` (unchanged) |
| Makefile override | `REGISTRY ?= docker.io/pdutton` |

The local image name stays `ansible-terraform`, so a local build remains
`localhost/ansible-terraform:<tag>` and `REGISTRY` alone retargets a push —
`make push REGISTRY=ghcr.io/pdutton` works without touching anything else.

The account in `REGISTRY` must match the `DOCKERHUB_USERNAME` secret CI logs in
with. If they disagree nothing fails early: `podman login` succeeds against the
wrong account and the push 401s on its first tag.

That secret is masked in CI logs, so `push-%`'s progress line renders there as
`Pushing docker.io/***/ansible-terraform:latest` rather than showing the account.
That is expected, not a broken expansion.

## Tag Scheme

Eleven tags. Given variant `<os>-<channel>` whose composite version — the
Ansible bundle version and the Terraform version, both read out of the freshly
built image — is `<ansible>-<terraform>`:

| Tag | Applied when | Meaning |
|---|---|---|
| `<os>-<channel>` | always | newest build of that channel on that OS |
| `<os>-<ansible>-<terraform>` | always | newest build of that exact pair of versions |
| `<os>` | `channel == stable` | that OS's stable image |
| `latest` | `variant == ubuntu-stable` | the default image |

### The 11 tags after a full build

```
alpine-stable        alpine-13.0.0-1.15.8          alpine
alpine-development   alpine-14.2.0-1.16.0-beta2
ubuntu-stable        ubuntu-13.1.0-1.15.8          ubuntu   latest
ubuntu-development   ubuntu-14.2.0-1.16.0-beta2
```

Version components above are the values current on 2026-08-09 and will drift.

`latest` points at `ubuntu-stable`, for both of the reasons its siblings give.
Ubuntu is the variant with no capability gaps — WinRM, Kerberos and SELinux
support exist only there — and `stable` is the channel whose Terraform is a final
release. Someone who runs `docker run pdutton/ansible-terraform` without reading
the tag table therefore gets the image least likely to fail in a way they cannot
diagnose, and **a Terraform prerelease is never reachable as `latest`**.

### There is deliberately no intermediate tag

`container-ansible` publishes `<os>-<major>` between its channel tag and its
version tag, and `container-terraform` publishes `<line>`. This repo publishes no
equivalent — no `alpine-13-1.15`, and no single-axis `alpine-13` or
`alpine-1.15`.

Two axes move independently here, and neither candidate survives that:

- A **single-axis** tag does not name an image. `alpine-13` would have to mean
  "Alpine, Ansible 13, and whatever Terraform happened to be wired to the stable
  channel that day" — it silently asserts nothing about half of the image's
  content, on a short tag people would reach for first.
- A **composite line** tag (`alpine-13-1.15`) is unambiguous but reads as noise,
  and buys little: it moves on exactly the same builds as `alpine-stable`, which
  is already the tag for "newest build of that channel."

Every published tag here therefore either names a channel or names both versions
exactly. There is no middle ground, and that is the intent.

### Every tag is mutable, including the version tags

`alpine-13.0.0-1.15.8` is a moving pointer, not a content pin. A rebuild that
again resolves to that pair re-pushes the tag at a *new* image — and in this repo
that is not even a base-OS-package refresh but a wholly new composition, since
both `FROM` lines are other repos' published tags and either can have moved
underneath an unchanged version number.

This is intended: it is the mechanism by which an upstream fix reaches someone
who pinned a version. But it means this repo publishes no content-immutable tag
at all, and `alpine-13.0.0-1.15.8` looks like an immutable pin to anyone who has
not been told otherwise. **The README must state this explicitly** rather than
let the tag's shape imply a guarantee it does not make. A consumer who needs true
immutability must pin by digest.

## Makefile

### Structural change

`version-tag-%` is renamed `tag-%` and computes the *whole* tag set rather than
only the version tag, applying all of it locally. The rename is part of the
change, not optional: `version-tag-%` would be a misleading name for a target
that now also produces `latest`. `build-%` continues to invoke it under the new
name, so a plain `make build` produces `alpine`, `latest` and the rest alongside
the two tags it produced before. Local and published tag state are therefore
identical, which is what makes a CI publish reproducible on a developer's
machine.

Applying the tags happens in two steps rather than one multi-`-t` build: build
the derived version-labelled image once under `$(LOCAL_IMAGE):$*`, then
`podman tag` it to each remaining name. This keeps the existing
`printf | podman build -f -` pipeline unchanged and avoids constructing a
variable-length `-t` argument list inside the build command.

`LOCAL_IMAGE` already covers every local image reference in this repo, so unlike
in either sibling there is no qualification refactor to do first.

### The composite version is carried whole

`tag-%` reads both versions and joins them — `av-tv`, e.g. `13.0.0-1.15.8` — into
a single `$version`, which it stamps on as `org.opencontainers.image.version`
exactly as today. The version tag is then simply `<os>-<version>`.

This is the one place a two-axis repo could have grown complexity and does not.
`TAG_SET_SH` never splits the axes apart to build a tag, and `push-%` reads back
one label rather than two. The composite is also the honest value for
`org.opencontainers.image.version`: this image's version *is* the pair.

### Tag math is defined once

`TAG_SET_SH`, a shell snippet expanded by both `tag-%` and `push-%`, so the tag
scheme is defined in exactly one place. Given `$version` already set by the
recipe and `$*` set by the pattern rule, it sets `$tags`.

```make
LATEST_VARIANT := ubuntu-stable

TAG_SET_SH = os="$(word 1,$(subst -, ,$*))"; \
             channel="$(word 2,$(subst -, ,$*))"; \
             ...variant guard, composite guard, and per-half shape guards... \
             tags="$* $$os-$$version"; \
             if [ "$$channel" = stable ]; then tags="$$tags $$os"; fi; \
             if [ "$*" = "$(LATEST_VARIANT)" ]; then tags="$$tags latest"; fi
```

The four guards it opens with are specified under "Guards" below. They are
elided here rather than sketched because a `#` comment cannot appear inside this
assignment at all — see the third bullet immediately following.

Details that are load-bearing, all three inherited from the siblings where the
mistake was already made once:

- **Written as one logical line.** Backslash continuations in a variable
  assignment collapse to spaces, so expanding this inside a recipe cannot
  introduce a newline into the shell command.
- **`if ... fi` rather than `[ ... ] && ...`.** Under `set -eu` a false test in
  the latter form is a non-zero exit status for the whole line, which aborts the
  recipe instead of skipping the tag.
- **A literal `#` inside a Make variable assignment starts a comment** and must
  be written `\#`. `$${version\#*.}` is correct; `$${version#*.}` truncates the
  assignment silently.

### Guards

Four, in this order, all before any tag is applied. Each failure is a hard error
naming the image, never a silently-empty or malformed tag.

**1. The variant stem is exactly two `-`-separated words.** The existing guard
from `version-tag-%`, moved into `TAG_SET_SH`: `os` and `channel` come from word
1 and word 2 of `$*` and silently discard anything past word 2, so a future
variant such as `ubuntu-stable-slim` would compute `os=ubuntu`, `channel=stable`
and claim `ubuntu-stable`'s tags — overwriting them in the public registry.
Checked by reassembling `os-channel` and comparing to `$*`, not by a `case` glob:
a shell `*` matches `-` too, so no bracket-class pattern can exclude extra
segments.

**2. `$version` contains a `-` at all.** This one is new and is not optional.
`${version#*-}` returns the string **unchanged** when it contains no `-`, so a
`$version` of `13.0.0` would set `av=13.0.0` and `tv=13.0.0`, pass both half
checks below, and silently publish `alpine-13.0.0` — a tag that looks like a
version tag and names only one of the two axes. Checked as
`case "$version" in *-*) ;; *) ERROR ;; esac`.

**3. Both halves are `X.Y.Z`.** The version tag uses `$version` whole, but the
shape check needs to see the halves, so `TAG_SET_SH` splits on the **first** `-`:

```sh
av="${version%%-*}"    # 13.0.0        14.2.0
tv="${version#*-}"     # 1.15.8        1.16.0-beta2
```

Safe in both directions: an Ansible bundle version is always `X.Y.Z` and never
contains a `-`, so a Terraform `-beta2` / `-rc1` suffix can only ever land in
`tv`. Each half is then checked against `[0-9]*.[0-9]*.[0-9]*`. Checking them
separately is not decoration — because a glob `*` matches `-`, that same pattern
applied to the composite matches `13.0.0` on its own.

Note that a literal `#` in `${version#*-}` must be written `$${version\#*-}` in
the Makefile: inside a Make variable assignment an unescaped `#` starts a
comment and truncates the rest of `TAG_SET_SH` silently. This is the trap
`container-terraform` hit and recorded.

**4. The variant guard's message must suit both callers.** It now fires from
`tag-%` and from `push-%`, which source `$version` differently — one from two
fresh containers, the other from the label. The message therefore names the image
rather than assuming either, and says "derive the tag set" rather than "tag":
from `push-%` nothing is being tagged.

### New targets

```make
REGISTRY ?= docker.io/pdutton

push-%: test-%
	# read $version back off the label, expand TAG_SET_SH, and push each tag
	# from $(LOCAL_IMAGE):<tag> to $(REGISTRY)/$(IMAGE):<tag>

push: $(addprefix push-,$(VARIANTS))
```

`.PHONY` and `help` must both be updated to cover the new targets. `help`'s
existing `--pull` advisory stays.

Four properties this shape guarantees:

- **`push-%` depends on `test-%`.** A smoke-test failure blocks the publish; a
  broken image cannot reach the registry through this path. This holds only
  within one `make` invocation — `build-%`/`test-%`/`push-%` match no real files,
  so a second, separate `make` in the same CI job re-runs the whole chain rather
  than seeing it as satisfied. That is why the workflow calls `make` exactly once
  per job.
- **The version is read by inspect, not by starting a container.**
  `podman image inspect --format '{{index .Labels "org.opencontainers.image.version"}}'`
  reads back what `tag-%` stamped on.
- **No registry-qualified local tags.** `podman push SOURCE DESTINATION` sends
  `localhost/ansible-terraform:latest` to
  `docker.io/pdutton/ansible-terraform:latest` without ever creating a local tag
  under the registry name. `clean`'s existing `^(localhost/)?$(IMAGE):` regex
  therefore continues to match every tag this repo creates and needs no change.
  (That regex is the one legitimate bare `$(IMAGE)` in the file — it is a pattern
  against `podman images` output, not an image reference. `$(LOCAL_IMAGE)` there
  would produce `^(localhost/)?localhost/ansible-terraform:` and match nothing.)
- **Pushing one image under several tags is cheap.** The layers upload once; each
  subsequent tag transfers only a manifest.

**Not atomic.** A failure partway through the loop leaves the earlier tags in
that run already published and the remaining ones stale. The failure is loud
(non-zero exit), which is the requirement, but it is not a rollback.

## GitHub Actions

Single file, `.github/workflows/build.yml`, matching both siblings.

```yaml
on:
  pull_request:
  push:
    branches: [master]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

`permissions: contents: read` — nothing in this workflow writes to the repo.
Concurrency cancels superseded PR runs but lets a master push finish, so a
cancellation cannot leave a variant's tag set half-updated in the registry.

### Matrix

One job per variant over the four variant names, `fail-fast: false`, on
`ubuntu-latest`. The four builds run in parallel, a failure identifies the
variant without reading logs, and one broken variant does not prevent the other
three from publishing.

Unlike `container-terraform`, this repo has no by-design permanent failure;
`fail-fast: false` here is prudence, not a load-bearing guard.

Steps:

1. `actions/checkout@v7`, default depth. The Makefile's `git rev-parse HEAD`
   works at depth 1. v7 runs on Node.js 24; v4 targets the deprecated Node.js 20
   and warns on every job.
2. **Ensure podman** — `command -v podman || sudo apt-get install -y podman`,
   then `test -x /usr/bin/podman` and `test -x /usr/bin/awk`, because the
   Makefile defaults to absolute tool paths and should fail here rather than with
   a confusing "no such file" mid-build.
3. **Build and smoke-test**, `if: github.event_name == 'pull_request' ||
   github.ref != 'refs/heads/master'` —
   `make test-${{ matrix.variant }} PODMAN_BUILD_FLAGS="--pull"`.
4. **Log in to Docker Hub** and **Build, smoke-test, and push**,
   `if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'`
   — `podman login docker.io` with the secrets, then a single
   `make push-${{ matrix.variant }} PODMAN_BUILD_FLAGS="--pull"`.

The two conditions are exact complements, so every run does exactly one of "test"
or "build+test+push" — never both, never neither:

| Event | Ref | Build+test | Push |
|---|---|---|---|
| `pull_request` | any | yes | no |
| `push` | `master` | no | yes |
| `workflow_dispatch` | `master` | no | yes |
| `workflow_dispatch` | other branch | yes | no |

Publishing is restricted to `master`, not merely excluded from pull requests: a
dispatch against a branch must still be able to put that branch through CI, but
must never overwrite the shared mutable tags (`latest`, `ubuntu`, `alpine`) with
unreviewed code. Making the test condition the exact negation is what stops a
feature-branch dispatch from matching no step at all and passing having done
nothing.

### CI passes `--pull`; the divergence, stated honestly

Neither sibling passes build flags in CI. This repo does, on both paths.

The reason `--pull` exists in this repo at all is that its images are composed
entirely of other repos' published tags, and neither `FROM` line's *text* changes
when an upstream republishes — so podman reuses cached layers and a plain
`make build` reproduces yesterday's image while both inputs have moved.

In CI that cache does not exist: GitHub runners are ephemeral with no image
store, so both `FROM` lines are resolved fresh on every run regardless. **`--pull`
is therefore belt-and-braces in CI, not a fix for a live bug.** It is included
anyway for two reasons: freshness becomes a property of the workflow rather than
of the runner's disposability, and the command in the workflow is then the exact
command a developer runs to reproduce a CI publish locally — where the cache very
much does bite.

### The Docker Hub description job

A second job, `dockerhub-description`, `needs: build`, under the same master-only
guard. Docker Hub reads nothing from this repo on its own, so the overview page
would drift from `DOCKERHUB-OVERVIEW.md` the moment either is edited alone.

A separate job rather than a fifth step, because the build job is a matrix of
four and this must run exactly once. `needs: build` waits for all four legs, so a
broken build leaves the old page in place rather than advertising images that
were never published.

```yaml
- uses: peter-evans/dockerhub-description@1b9a80c056b620d92cedb9d9b5a223409c68ddfa # v5.0.0
  with:
    username: ${{ secrets.DOCKERHUB_USERNAME }}
    password: ${{ secrets.DOCKERHUB_TOKEN }}
    repository: pdutton/ansible-terraform
    readme-filepath: ./DOCKERHUB-OVERVIEW.md
    short-description: "Ansible and Terraform together, ready to run without installing either"
```

Pinned by SHA, not by tag: this is the only third-party action here and it is
handed a Docker Hub token with write/delete scope. A tag is a mutable pointer in
someone else's repository — repointing `v5` would run new code against that
secret with no change on this side. `actions/checkout` stays on a major tag; it
is inside GitHub's own trust boundary.

The short description is set here too, so the whole Hub page is declarative —
leaving it unset would silently preserve whatever was last typed into the web UI.

### Secrets

`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` as repository secrets, the latter a
Docker Hub PAT. It needs **write and delete** scope: `peter-evans/dockerhub-description`
replaces the description rather than appending to it.

Pull requests from forks never receive secrets and never reach the login step, so
there is no path on which a fork PR fails for want of a credential.

## `DOCKERHUB-OVERVIEW.md`

New file at the repo root, modelled on both siblings':

- Usage — the `terraform` and `ansible-playbook` aliases, on `docker run` and
  `pdutton/ansible-terraform` rather than `podman` and `localhost/`.
- Base-image usage.
- **Useful Tags** — a four-row alias-shaped table (`<os>-<channel>` with its
  aliases), naming **no version numbers and no Ansible or Terraform line**,
  plus the Alpine WinRM/Kerberos caveat.
- Source link to the GitHub repo.
- Intended Audience, carrying the licensing note.

### Licensing wording is taken from container-terraform

`container-terraform`'s "Intended Audience" section already says exactly the
right thing for an image that contains Terraform, and it is reused here rather
than reworded, adjusted only to name both tools:

> The code in this repository is licensed under GPL-3.0-or-later, but
> **Terraform itself is not open source.** It is licensed under the Business
> Source License 1.1. You must comply with _both_ licenses when using and
> extending this container image.

This is not decoration on the Hub page. It is where someone meets these images
without ever seeing the README, and "not entirely open source" is the fact they
most need up front — the same reasoning that already gives these images
`org.opencontainers.image.licenses="GPL-3.0-or-later AND BUSL-1.1"` instead of
container-ansible's bare GPL label.

### It duplicates the README, and nothing checks it

`DOCKERHUB-OVERVIEW.md` restates parts of `README.md` for an audience that
arrived without the repo. Nothing cross-checks the two, so a change to the tag
scheme or the aliases must be applied to both by hand. That is why the table
above carries no version numbers and names no channel's Ansible or Terraform
version: it is the one document here that no test or build step can catch
drifting, so it must contain as little drift-capable content as possible.

## Documentation Changes

### README

- A CI badge for the workflow.
- Usage examples move from `localhost/ansible-terraform:alpine-stable` to
  `docker.io/pdutton/ansible-terraform:alpine-stable`.
- A **Published Images** section, with `podman pull` and `docker pull` forms and
  the note that a local build carries the identical tag set.
- The **Tags** section rewritten around the 11-tag scheme: the resolution table,
  the deliberate absence of an intermediate tag, the mutability caveat, and the
  pin-by-digest note with a `skopeo inspect` one-liner.
- **Building Locally** gains `make push`, the `podman login docker.io`
  prerequisite, the `REGISTRY` override, and the note that a local build now
  applies the full tag set.
- A **Continuous Integration** section: what runs on a PR, the master-only
  publish and that it is an accident guard rather than a security boundary
  (`workflow_dispatch` runs the workflow file from the selected ref, so a branch
  that also edits the `if:` conditions could still publish), the absence of a
  scheduled rebuild, and that the Hub overview page must not be edited in the web
  UI because the next master push overwrites it and its short description.
- The "**These images are not published to any registry**" line is removed, along
  with the Planned bullets this phase closes (publishing/CI, and the tag-scheme
  alignment). The multi-arch and digest-pinning bullets stay.

### CLAUDE.md

- A new **Publishing** section: registry coordinates, `REGISTRY` and
  `LOCAL_IMAGE`, that `TAG_SET_SH` defines the scheme once and is expanded by
  both `tag-%` and `push-%`, the 11 tags, the deliberate absence of an
  intermediate tag, the master-only CI publish, and that the Hub page is
  generated from `DOCKERHUB-OVERVIEW.md` and that nothing on Docker Hub is
  authoritative.
- The **Build and test** block gains `make push`.
- The existing **"Do not add version or channel assertions to the smoke test"**
  section keeps its position and its conclusion, but its "accepted consequence"
  paragraph is updated: the hand-check is now a **pre-merge** step, because
  merging to `master` is what publishes. See "Accepted risks" below.
- This spec is indexed as the authority for the tag scheme, the no-intermediate-tag
  rule, the non-atomic push, and the registry coordinates.

## Prerequisites

Manual, performed once, outside the code, and **before the first merge to
`master`**:

1. Create the public `pdutton/ansible-terraform` repository on Docker Hub.
2. Create a Docker Hub Personal Access Token with write and delete scope.
3. Add `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` as repository secrets.
4. `podman login docker.io` on any machine performing a local `make push`.

## Verification

### Before merge, against a throwaway registry

Nothing in this phase may be verified for the first time against the public
repository.

1. Prove the tag math standalone, before building anything, over these
   `$version` inputs:

   | Input | Expected |
   |---|---|
   | `13.0.0-1.15.8` | accepted → `<os>-13.0.0-1.15.8` |
   | `14.2.0-1.16.0-beta2` | accepted → `<os>-14.2.0-1.16.0-beta2` |
   | `14.2.0-1.16.0-beta.2` | accepted → `<os>-14.2.0-1.16.0-beta.2` |
   | `13.0.0` | **rejected** — no `-` (guard 2) |
   | `13.0.0-1.15` | **rejected** — `tv` is not `X.Y.Z` (guard 3) |
   | `13.0-1.15.8` | **rejected** — `av` is not `X.Y.Z` (guard 3) |
   | `-1.15.8` | **rejected** — `av` empty (guard 3) |
   | `""` | **rejected** — no `-` (guard 2) |

2. Confirm the variant guard still rejects a stem such as `ubuntu-stable-slim`,
   now from both callers.
3. `make build` and confirm exactly the 11 tags exist locally, and no others.
4. Run a local registry —
   `podman run -d --rm -p 127.0.0.1:5000:5000 --name at-test-registry docker.io/library/registry:2`
   with a temporary `CONTAINERS_REGISTRIES_CONF` marking `localhost:5000`
   insecure — then `make push REGISTRY=localhost:5000` and confirm
   `curl -s http://localhost:5000/v2/ansible-terraform/tags/list` lists exactly
   those 11 tags.
5. Confirm the push created zero registry-qualified *local* tags, so `clean`
   still matches the complete set.
6. Confirm `make -n push-alpine-stable` shows build → test → push in that order,
   and that a deliberately failed smoke test blocks the push.

### After merge, against Docker Hub

Pull the published tags back from the registry — not from local cache — and
confirm each dynamic tag resolves to the image it should:

- `latest`, `ubuntu`, `ubuntu-stable` and `ubuntu-13.1.0-1.15.8` all resolve to
  one image ID.
- `alpine`, `alpine-stable` and `alpine-13.0.0-1.15.8` all resolve to one image
  ID.
- The two `development` variants each agree with their version tag, and neither
  is reachable as `latest`.
- The smoke test passes against an image pulled from Docker Hub rather than the
  locally built one.
- The Hub overview page matches `DOCKERHUB-OVERVIEW.md`, short description
  included.

These are a documented manual procedure, not a permanent Makefile target. The
post-merge half is only meaningful against a clean pull, which a convenient
`make verify` would tend to skip.

## Accepted Risks

**A miswired `COPY --from` can now publish, including as `latest`.** This repo's
`test/smoke.yml` asserts only that Ansible can drive Terraform to a correct
result — deliberately, because the version and channel declarations live upstream
and duplicating their guards here would make this repo fail its build over a
correct upstream change. That decision stands and is not reopened by this phase.

The consequence changes, though. Before this phase a stable Containerfile
wrongly pointing at `pdutton/terraform:development` produced a wrong local image.
After it, the same mistake publishes a Terraform prerelease as `ubuntu-stable`,
`ubuntu` and `latest`, and every automated gate on the path — the smoke test, the
shape guards, the tag math — passes, because the composite version tag it
produces is wrong but perfectly self-consistent.

A publish-time prerelease guard was considered and rejected: it would have
asserted only that a `*-stable` variant's Terraform carries no `-beta`/`-rc`,
which needs no maintenance when an upstream channel moves. It was rejected to
keep this repo's "assertions live where the declaration lives" rule intact and
unqualified.

The mitigation is therefore procedural, and the documentation must say so
plainly: CLAUDE.md's existing by-hand check of all four variants is now a
**pre-merge** step, because merging is what publishes.

**No scheduled rebuild.** Published images are refreshed only on a master push or
a `workflow_dispatch` run against `master`. This bites harder here than in either
sibling: these images are composed entirely of upstream tags, so both inputs can
move without anything in this repo changing, and a published image can sit
arbitrarily far behind both. `workflow_dispatch` makes refreshing them a one-click
deliberate act. Add a cron trigger later if that proves easy to forget.

**No immutable tags.** Covered above under the tag scheme. Consumers needing
reproducibility must pin by digest, and the README must say so.

**Each CI run pulls both upstream images per variant.** Four variants, no cache,
every run. Accepted: it is what makes CI publishes fresh.

## Rejected Alternatives

**A 15-tag scheme with a composite line tag** (`alpine-13-1.15`), and a **19-tag
scheme adding single-axis tags** (`alpine-13`, `alpine-1.15`). Rejected for the
reasons under "There is deliberately no intermediate tag": the composite line tag
moves on the same builds as the channel tag it sits beside, and a single-axis tag
silently asserts nothing about half the image.

**Two labels, one per axis**, with `push-%` reading both. Rejected: carrying the
composite whole means `TAG_SET_SH` never splits the axes to *build* a tag, only
to validate one, and `org.opencontainers.image.version` stays the single honest
statement of this image's version.

**A publish-time prerelease guard in `push-%`.** Covered under accepted risks.

**Tag logic in the workflow via `docker/metadata-action` + `buildx`.** More
idiomatic GitHub Actions, but it would put the tag scheme somewhere that cannot
be run or debugged locally, and would split image-building between `buildx` in CI
and `podman` on a developer's machine. The Makefile-owns-it choice keeps one
implementation and one runtime, and matches both siblings.

**A `scripts/push.sh` called by both the Makefile and the workflow.** Same
single-source-of-truth benefit, but a third artifact where the Makefile already
owns the variant matrix and the version detection.

**A single CI job building all four variants.** Simpler workflow file, but
serial, and a single failure obscures which variant broke and blocks the other
three from publishing.
