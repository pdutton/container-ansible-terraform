# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

Four Containerfiles, a Makefile, and a smoke test. Each variant composes an
Ansible image from
[container-ansible](https://github.com/pdutton/container-ansible) with the
Terraform binary from
[container-terraform](https://github.com/pdutton/container-terraform), via a
named copy-source stage and a single `COPY --from`.

**This repo installs nothing.** No archives are downloaded, no signatures
verified, no versions resolved. All of that lives in the two upstream repos.

Variants: `alpine-stable`, `alpine-development`, `ubuntu-stable`,
`ubuntu-development`.

## Build and test

```bash
make build                 # build all four variants
make test                  # build, then smoke-test all four
make push                  # build, test, and publish all four to Docker Hub
make build-alpine-stable   # one variant
make test-alpine-stable    # one variant (builds first)
make clean                 # remove this repo's tags
make help                  # list every target
```

There is no single-test granularity below the variant: `test-<variant>` runs the
whole `test/smoke.yml` playbook, which is the only test.

### Rebuilds do not pick up republished upstreams

Neither `FROM` line's *text* changes when an upstream publishes a new image, so
Podman reuses cached layers and a plain `make build` reproduces the previous
image while both inputs have moved. Use:

```bash
make build PODMAN_BUILD_FLAGS="--pull"
```

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

## How versions are selected

Not in this repo. The Ansible channel comes from the
`docker.io/pdutton/ansible:<variant>` tag and the Terraform channel from
`docker.io/pdutton/terraform:<channel>`; the `FROM` lines are the selectors and
both are resolved upstream. To move a channel, change it there.

Tags are read out of the built image and never typed: `tag-%` runs
`ansible-community --version` (the *bundle* version, not `ansible --version`,
which reports core) and `terraform version`, joins them into one composite
`<ansible>-<terraform>` version, and derives the whole tag set from it. See
Publishing below.

## Do not add version or channel assertions to the smoke test

`test/smoke.yml` deliberately asserts only that Ansible can drive Terraform to a
correct result. It does **not** assert the Terraform version line, or that
`development` carries a `-beta`/`-rc` while `stable` does not.

Those guards belong in container-terraform, which declares the lines and asserts
them against its own images before publishing. Duplicating them here would put
the guard somewhere other than where the declaration lives: this repo would then
need a matching bump every time an upstream channel moved, and would fail its
build over a correct upstream change.

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

```bash
for v in alpine-stable alpine-development ubuntu-stable ubuntu-development; do
  printf '%-22s ' "$v"
  podman run --rm localhost/ansible-terraform:$v sh -c \
    'ansible-community --version | tr "\n" " "; terraform version | head -1'
done
```

Both `*-stable` rows must show a plain Terraform version with Ansible 13.x; both
`*-development` rows a `-beta`/`-rc` version with Ansible 14.x.

## Conventions

Shared with both upstream repos — follow them:

- Four explicit Containerfiles, **no build args**. The `FROM` lines are the
  selectors and are edited deliberately.
- No `ENTRYPOINT`; the image is a plain command host.
- Every local image reference goes through `LOCAL_IMAGE = localhost/$(IMAGE)`,
  never a bare `$(IMAGE)`, which can resolve by an implicit registry tie-break.
- Static labels live in the Containerfile; dynamic ones (`created`, `revision`)
  come from the Makefile via `--label`.
- `make clean` removes only this repo's tags and never runs a blanket
  `podman image prune`.
- Images carry `org.opencontainers.image.licenses="GPL-3.0-or-later AND
  BUSL-1.1"` — Terraform 1.6+ is BUSL, so upstream's bare GPL label would be
  wrong here. See the README's License section.
