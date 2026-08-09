# container-ansible-terraform

[![build](https://github.com/pdutton/container-ansible-terraform/actions/workflows/build.yml/badge.svg)](https://github.com/pdutton/container-ansible-terraform/actions/workflows/build.yml)

Container images with both Ansible and Terraform.

These images compose two upstream repos: the Ansible images from
[container-ansible](https://github.com/pdutton/container-ansible) and the
Terraform binary from
[container-terraform](https://github.com/pdutton/container-terraform). Nothing is
installed here — no archives are downloaded, no signatures verified, no versions
resolved. All of that lives upstream. This repo composes.

## Ansible and Terraform Without Installing

```
alias terraform='podman run -ti --rm -v "$PWD":/apps -w /apps docker.io/pdutton/ansible-terraform:alpine-stable terraform'
terraform <follow command>
```

```
alias ansible-playbook='podman run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps docker.io/pdutton/ansible-terraform:alpine-stable ansible-playbook'
ansible-playbook -i inventory <follow command>
```

The alias body is single-quoted and uses `"$PWD"` rather than `$(pwd)` so the mount is resolved fresh on every
invocation. A double-quoted alias body substitutes `$(pwd)` once, at the moment the alias is *defined* — it then
permanently mounts that one directory no matter where you later `cd`, with no error to warn you.

On an SELinux-enforcing host (e.g. Fedora/RHEL), mounting your real `~/.ssh` needs
`--security-opt label=disable` added to the alias rather than a `:z`/`:Z` suffix on the mount — relabeling
`~/.ssh` with `:z` would alter the SELinux context of your actual SSH keys on the host, which is actively
harmful.

Swap `alpine-stable` for any of the other three tags below if you need a different base OS or channel.

## Image Variants

Four variants are built from this repo, each on its own Containerfile:

| Tag | Ansible base | Terraform source | Ansible bundle | Terraform |
|---|---|---|---|---|
| `alpine-stable` | `pdutton/ansible:alpine-stable` | `pdutton/terraform:stable` | 13.0.0 | 1.15.8 |
| `alpine-development` | `pdutton/ansible:alpine-development` | `pdutton/terraform:development` | 14.2.0 | 1.16.0-beta2 |
| `ubuntu-stable` | `pdutton/ansible:ubuntu-stable` | `pdutton/terraform:stable` | 13.1.0 | 1.15.8 |
| `ubuntu-development` | `pdutton/ansible:ubuntu-development` | `pdutton/terraform:development` | 14.2.0 | 1.16.0-beta2 |

Versions as of 2026-08-09, on Alpine 3.23 and Ubuntu 26.04. Both bases pull from Docker Hub, so neither upstream
repo needs to be built locally.

The Terraform source changes on the channel axis only: both `stable` variants share `terraform:stable` and both
`development` variants share `terraform:development`. Terraform ships as a statically linked binary, so the base
OS is irrelevant to it and container-terraform has no OS axis at all.

Locally built images are referenced as `localhost/ansible-terraform:<tag>`, e.g.
`localhost/ansible-terraform:ubuntu-stable`.

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

## Capability Differences

Inherited whole from the Ansible base. Alpine has no packages for `winrm`, `pyspnego`, `requests-ntlm`,
`kerberos`, `gssapi`, or `selinux`, so **the `alpine-stable` and `alpine-development` images do not support
Windows/WinRM or Kerberos-authenticated targets.** The `ubuntu-stable` and `ubuntu-development` images do support
both.

If your playbooks target Windows hosts or rely on Kerberos, use one of the Ubuntu variants. See
[container-ansible](https://github.com/pdutton/container-ansible) for the detail, including which Python
dependencies each variant carries and where they live.

Terraform itself is identical across all four — one static binary at `/usr/local/bin/terraform`, with no runtime
dependencies on the base at all.

## Building Locally

Requires [Podman](https://podman.io/) and GNU Make. Both base images pull from Docker Hub, so there is no need to
build container-ansible or container-terraform first.

```bash
make build                 # build all four variants
make test                  # smoke-test all four variants
make push                  # build, test, and publish all four to Docker Hub
make build-alpine-stable   # build just one variant
make clean                 # remove all tagged images this repo builds
```

Run `make help` (or just `make`) to list every target, including the per-variant `build-<variant>` and
`test-<variant>` names (`test-<variant>` builds first).

`make build` applies the complete tag set locally, so a local build and a published one leave
identical tag state — which is what makes a CI publish reproducible on your own machine.
`push-<variant>` depends on `test-<variant>`, so a failing smoke test blocks the publish.
Publishing requires `podman login docker.io` first; override the destination with
`make push REGISTRY=ghcr.io/pdutton`. Publishing normally happens in CI on a merge to `master`,
not from a developer's machine.

### Rebuilds do not pick up republished upstreams

Neither `FROM` line's *text* changes when an upstream publishes a new image, so Podman reuses its cached layers
and a plain `make build` will happily reproduce yesterday's image while both inputs have moved. To force a
refresh:

```bash
make build PODMAN_BUILD_FLAGS="--pull"
```

This matters more here than in either upstream, because these images are composed entirely of other repos'
content.

`make clean` only removes the tags this repo applies. Each version tag is built as a derived image on top of the
freshly built one, so `clean` cannot cascade-delete the untagged `<none>` base layers left behind — they
accumulate across rebuild cycles. Run `podman image prune` to clear those; it is not run automatically here
because it would also delete untagged images this repo never built.

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

## License

This project is licensed under the GPL-3.0-or-later. The `LICENSE` file in this repo contains the bare text of the
GNU General Public License v3, which does not itself state the "or later" election — that election is made here, in
this README.

### The images are not entirely open source

Every image built from this repo contains **Terraform, which is licensed under the Business Source License 1.1**
(BUSL-1.1), not an open-source license. Terraform 1.6.0 and later carry these terms, with IBM as licensor:

- **Redistribution is permitted.** Building, sharing and using these images is fine.
- **Production use is permitted**, *provided* your use does not include offering Terraform to third parties on a
  hosted or embedded basis in order to compete with IBM's paid versions of it.
- **Each version converts to MPL-2.0** four years after it was published.

This is why the images carry `org.opencontainers.image.licenses="GPL-3.0-or-later AND BUSL-1.1"` rather than
container-ansible's bare `GPL-3.0-or-later`. A scanner reading the GPL label alone would conclude the image is
freely usable, which is not true of the Terraform binary inside it.

If the BUSL terms are a problem for your use, note that OpenTofu is an MPL-2.0 fork of Terraform. It is not built
by this repo.

## Planned

The following are not implemented yet and should not be treated as available today:

- Multi-arch builds for both `amd64` and `arm64`.
- Digest-pinning the upstream base images rather than tracking their tags.
