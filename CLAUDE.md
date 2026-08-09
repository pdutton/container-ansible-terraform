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

## How versions are selected

Not in this repo. The Ansible channel comes from the
`docker.io/pdutton/ansible:<variant>` tag and the Terraform channel from
`docker.io/pdutton/terraform:<channel>`; the `FROM` lines are the selectors and
both are resolved upstream. To move a channel, change it there.

Tags are read out of the built image and never typed: `version-tag-%` runs
`ansible-community --version` (the *bundle* version, not `ansible --version`,
which reports core) and `terraform version`, producing
`<os>-<ansible>-<terraform>`.

## Do not add version or channel assertions to the smoke test

`test/smoke.yml` deliberately asserts only that Ansible can drive Terraform to a
correct result. It does **not** assert the Terraform version line, or that
`development` carries a `-beta`/`-rc` while `stable` does not.

Those guards belong in container-terraform, which declares the lines and asserts
them against its own images before publishing. Duplicating them here would put
the guard somewhere other than where the declaration lives: this repo would then
need a matching bump every time an upstream channel moved, and would fail its
build over a correct upstream change.

The accepted consequence: nothing automated catches a miswired `COPY --from`
pulling the wrong Terraform channel. Check by hand after touching a
Containerfile's `FROM` lines:

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
