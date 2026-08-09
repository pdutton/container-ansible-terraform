# Phase 1: Composing Ansible and Terraform Images

**Date:** 2026-08-08
**Status:** Approved
**Revised:** 2026-08-08 — both upstreams now publish; this repo composes rather
than installs. See "Revision history" at the end.

## Goal

Build four container image variants locally with Podman, each composing the
Ansible image published by
[container-ansible](https://github.com/pdutton/container-ansible) with the
Terraform binary from the image published by
[container-terraform](https://github.com/pdutton/container-terraform), and verify
each one by having Ansible drive Terraform inside it.

This repo installs nothing. It downloads no archives, verifies no signatures, and
resolves no versions — all of that lives in the two upstream repos. It composes.

Nothing in this phase publishes images, builds multi-arch manifests, or runs in
CI.

### Prerequisite: container-terraform must publish first

**`docker.io/pdutton/terraform` currently has no tags.** Verified 2026-08-08 via
the Docker Hub API: `pdutton/ansible` returns 15 tags, `pdutton/terraform`
returns 0. container-terraform's publishing work exists as a designed and planned
branch (`feature/dockerhub-publish`) that has not merged.

Implementation of this spec is therefore **blocked** until container-terraform
merges that branch and pushes at least `stable` and `development`. This was a
deliberate choice: referencing the published name now avoids a follow-up commit
flipping every Containerfile away from a `localhost/` reference, at the cost of
not being able to build until the upstream lands.

## Variant Matrix

| Variant | Ansible base | Terraform source |
|---|---|---|
| `alpine-stable` | `docker.io/pdutton/ansible:alpine-stable` | `docker.io/pdutton/terraform:stable` |
| `alpine-development` | `docker.io/pdutton/ansible:alpine-development` | `docker.io/pdutton/terraform:development` |
| `ubuntu-stable` | `docker.io/pdutton/ansible:ubuntu-stable` | `docker.io/pdutton/terraform:stable` |
| `ubuntu-development` | `docker.io/pdutton/ansible:ubuntu-development` | `docker.io/pdutton/terraform:development` |

Both bases pull from Docker Hub, so there is no requirement to have built either
upstream repo locally.

### Why the composition is asymmetric

Ansible is the base and Terraform is copied in. That is not arbitrary — it
follows from what each tool actually is, measured on the real images on
2026-08-08:

| | Relocatable? | Evidence |
|---|---|---|
| Terraform | **yes, completely** | one statically linked ELF, `ldd` → "not a dynamic executable", nothing outside `/usr/local/bin/terraform` |
| Ansible | **no** | `stable` variants have no `/opt/ansible` at all — Ansible is a distro package in system paths. `development` variants symlink `/opt/ansible/bin/python3` → `/usr/bin/python3` and record an exact interpreter version in `pyvenv.cfg`; `ubuntu-development` is built `--system-site-packages`, with winrm/gssapi/selinux resolving to `/usr/lib/python3/dist-packages` |

So copying Terraform onto an Ansible base is a one-file operation that cannot go
subtly wrong. The reverse — copying Ansible onto a Terraform base — would mean
re-declaring Python, ssh, sshpass and the Kerberos stack here, with a silent
failure mode: when container-ansible bumps Alpine and Python goes 3.12 → 3.13,
the copied venv's symlink still resolves while its `pyvenv.cfg` no longer
matches.

### Channel mapping

The `stable`/`development` word means the same thing on both sides, so the
channels line up: both `*-stable` variants take `terraform:stable`, both
`*-development` variants take `terraform:development`. The Ansible channel
additionally selects the OS variant, which Terraform has no equivalent of — a
static binary makes the base OS irrelevant to Terraform, so container-terraform
has only two channels and no OS axis.

## Repository Layout

```
Containerfile.alpine-stable
Containerfile.alpine-development
Containerfile.ubuntu-stable
Containerfile.ubuntu-development
Makefile
.dockerignore
.gitignore
test/smoke.yml
test/terraform/main.tf
README.md
LICENSE
```

Four explicit Containerfiles, matching both upstreams. Nothing is `COPY`d from
the build context, so `.dockerignore` keeps the context near-empty.

## Containerfiles

Each is a single `COPY` onto a working base. `Containerfile.alpine-stable` in
full:

```dockerfile
FROM docker.io/pdutton/terraform:stable AS terraform

FROM docker.io/pdutton/ansible:alpine-stable

LABEL org.opencontainers.image.title="ansible-terraform" \
      org.opencontainers.image.description="Terraform (stable) on Ansible 13 (stable), Alpine 3.23" \
      org.opencontainers.image.licenses="GPL-3.0-or-later AND BUSL-1.1" \
      org.opencontainers.image.source="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.url="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="docker.io/pdutton/ansible:alpine-stable"

COPY --from=terraform /usr/local/bin/terraform /usr/local/bin/terraform

WORKDIR /apps
CMD ["terraform", "-help"]
```

The other three differ from it only as follows:

| File | Differences |
|---|---|
| `Containerfile.ubuntu-stable` | Ansible `FROM`, `base.name`, description |
| `Containerfile.alpine-development` | Terraform `FROM` → `:development`; Ansible `FROM`, `base.name`, description |
| `Containerfile.ubuntu-development` | same as `alpine-development` |

Note that the two `*-stable` variants share `terraform:stable` and the two
`*-development` variants share `terraform:development` — the Terraform `FROM`
changes on the channel axis only, since Terraform has no OS axis.

Notes on the shape:

- **The named `terraform` stage is for readability**, not necessity —
  `COPY --from=docker.io/pdutton/terraform:stable ...` works directly. Naming it
  puts both upstream dependencies at the top of the file where they can be read
  at a glance.
- **`base.name` names the Ansible image only.** The Terraform image is a copy
  source, not a base; none of its filesystem layers are inherited.
- **No build args**, preserving the convention both upstreams follow. The `FROM`
  lines are the selectors and are edited deliberately.
- **No `ENTRYPOINT`**, as upstream. `CMD ["terraform", "-help"]` — Terraform is
  what this layer contributes, so it takes the default.
- `/usr/local/bin` is on `PATH` in all four variants. On the `development`
  variants `/opt/ansible/bin` is *prepended* to `PATH`, not substituted for it.

### What this repo deliberately does not do

Earlier revisions of this spec had each Containerfile download Terraform from
`releases.hashicorp.com` in a throwaway stage: resolving a version within a
declared line, importing HashiCorp's GPG key, asserting a pinned fingerprint
against the `VALIDSIG` status line, and verifying SHA256SUMS.

All of that now lives in container-terraform and must not be duplicated here.
Two copies of a supply-chain check are worse than one: they drift, and the weaker
copy sets the real security level. If the download mechanism needs to change, it
changes there.

The licensing consequence stays here, though, because it travels with the binary
— see Licensing below.

## Makefile

Mirrors the shape both upstreams share: `build-<variant>`, `test-<variant>`,
`build`, `test`, `version-tag-<variant>`, `clean`, and `help` as the default
goal. External tools are overridable vars (`PODMAN ?=`, `AWK ?=`).

```make
IMAGE       ?= ansible-terraform
LOCAL_IMAGE  = localhost/$(IMAGE)
VARIANTS    := alpine-stable alpine-development ubuntu-stable ubuntu-development
```

`LOCAL_IMAGE` is adopted from container-ansible, which introduced it so that no
image reference in the file is unqualified — an unqualified name can resolve by
an implicit registry tie-break, which is not something the highest-stakes lines
in a build should depend on.

### No preflight check

Earlier revisions specified a preflight verifying the base images existed
locally, since `localhost/ansible` cannot be pulled. Both bases now come from
Docker Hub, so Podman fetches what is missing and reports a normal registry error
if a tag genuinely does not exist. The check is dropped rather than reimplemented.

### Rebuilds and staleness

`podman build` will reuse cached layers and *not* notice that
`pdutton/ansible:alpine-stable` or `pdutton/terraform:stable` has been
republished, because neither `FROM` line's text changed. To pick up republished
upstreams:

```
make build PODMAN_BUILD_FLAGS="--pull"
```

`PODMAN_BUILD_FLAGS` is adopted from container-terraform, which added it for the
same class of problem. This matters more here than in either upstream: this
repo's images are entirely composed of other people's rebuilt content, so a
plain `make build` can produce an image identical to yesterday's while both
inputs have moved.

### Version tagging

`version-tag-%` reads **both** versions out of the freshly built image and
applies them in the one-line `FROM`+`LABEL` pass both upstreams use:

- `ansible-community --version` → the Ansible bundle version (e.g. `13.0.0`).
  This is the bundle version, not `ansible --version`, which reports core.
- `terraform version` → first line, last field, leading `v` stripped (e.g.
  `1.15.8`).

Both are applied as the tag suffix `<os>-<ansible>-<terraform>` and as
`org.opencontainers.image.version`. Neither is ever typed into the repo, so tags
cannot drift from what is installed.

| Channel tag | Version tag |
|---|---|
| `alpine-stable` | `alpine-13.0.0-1.15.8` |
| `alpine-development` | `alpine-14.2.0-1.16.0-beta2` |
| `ubuntu-stable` | `ubuntu-13.1.0-1.15.8` |
| `ubuntu-development` | `ubuntu-14.2.0-1.16.0-beta2` |

Both versions appear because either can move independently — a rebuild picking up
a newer Ansible with the same Terraform would otherwise silently reuse a tag.

**Known divergence:** container-ansible has since grown to a 15-tag scheme
(`latest`, `<os>`, `<os>-<major>`, `<os>-<version>`, `<os>-<channel>`) and
container-terraform to a 4-tag one including `latest`. This repo's two-tags-per-variant
scheme no longer matches either. Aligning it is deferred — it belongs with the
publishing phase, since a `latest` tag has little meaning for images that are
never pushed.

### Clean

As both upstreams: remove only the tags this repo applies, and never run a
blanket `podman image prune`, which would delete images this repo never built.

## Testing

`community.general.terraform` is present in the Ansible base images
(community.general 12.0.1, verified 2026-08-08, no deprecation notice;
`cloud.terraform` is not in the bundle). The smoke test drives Terraform through
a real Ansible module rather than shelling out, because that composition is the
entire reason these images exist.

### `test/terraform/main.tf`

```hcl
variable "greeting" {
  type    = string
  default = "ok"
}

resource "terraform_data" "smoke" {   # builtin since TF 1.4 — no provider plugin
  input = var.greeting
}

output "message" {
  value = "${terraform_data.smoke.output}-from-terraform"
}
```

No providers and no backend, so `init` needs no registry access and the test runs
fully offline. `terraform_data` is a builtin managed resource, which makes this
more than a syntax check: it exercises the real init → plan → apply → state path.

### `test/smoke.yml`

Run as both upstreams run theirs:

```
podman run --rm -v ./test:/apps:ro,z $(LOCAL_IMAGE):$* \
  ansible-playbook -i localhost, -c local smoke.yml
```

The playbook:

1. Copies `main.tf` into `/tmp/tfsmoke`. Required, not incidental: `test/` is
   mounted read-only and Terraform must write `.terraform/` and state.
2. Runs it with `community.general.terraform`, `project_path: /tmp/tfsmoke`,
   `state: present`, `force_init: true`.
3. Asserts the registered output `message` equals `ok-from-terraform`.

That is the whole test. A Terraform binary that is present but broken — wrong
architecture, truncated, missing execute bit — fails at step 2.

### No version or channel assertions

Earlier revisions asserted the Terraform minor line and that `development`
carried a `-beta`/`-rc` while `stable` did not. Both assertions are dropped.

container-terraform declares those lines and asserts them in its own smoke test,
against its own images, before publishing. Re-asserting here would place the
guard somewhere other than where the declaration lives: this repo would need a
matching bump every time an upstream channel moved, and would fail its build over
a correct upstream change. Ansible's own capabilities — `json_query`,
`password_hash`, the WinRM/Kerberos/SELinux stack — are likewise
container-ansible's contract, covered by its suite, and are not retested here.

What remains untested as a result: nothing verifies that `alpine-stable` received
`terraform:stable` rather than `terraform:development`. A miswired `COPY --from`
would produce a working image on the wrong channel, and only the version tag
would reveal it. This is an accepted consequence of keeping each guard in the repo
that owns the declaration.

## Licensing

Terraform 1.6.0 and later are BUSL-1.1, not open source. Verified against the
1.15.8 tag on 2026-08-08: licensor IBM; the Additional Use Grant permits
production use *provided* it does not include offering Terraform to third parties
on a hosted or embedded basis in order to compete with IBM's paid versions;
Change Date is four years from publication, Change License MPL-2.0.

Redistribution inside a container image is permitted, so building and using these
images is fine. But container-ansible's `GPL-3.0-or-later` would be inaccurate
here — a scanner reading that label alone would conclude the image is freely
usable.

These images therefore carry `GPL-3.0-or-later AND BUSL-1.1`, a valid SPDX
expression covering the inherited Ansible stack and this repo's own contribution
(GPL) alongside the Terraform binary (BUSL). container-terraform labels its own
images `BUSL-1.1` alone, correctly — it carries no GPL Ansible stack.

`LICENSE` stays as the bare GPLv3 text for this repo's own code. As upstream, the
README makes the "or later" election explicit, since the license text does not
make it itself, and a README section states the BUSL terms in plain language.
That section is what makes the label honest rather than merely present.

## README

Following the structure both upstreams share:

- Usage aliases for running `terraform` and `ansible-playbook` out of the image,
  with the same single-quoted `"$PWD"` caveat and the same SELinux warning about
  mounting `~/.ssh`.
- The variant table, naming both upstream images each variant composes.
- Capability differences inherited from the Ansible base: the Alpine variants have
  no WinRM/Kerberos/SELinux support, the Ubuntu variants do.
- Building locally — noting that both bases pull from Docker Hub, that no local
  build of either upstream is needed, and that `PODMAN_BUILD_FLAGS="--pull"` is
  required to pick up republished upstreams.
- The tag scheme, and that these images are not published anywhere yet.
- The licensing section described above.
- A `## Planned` section for the deferred items below.

## Error Handling

Make halts on any non-zero exit, so nothing broken reaches tagging and a failed
assertion cannot yield a green `make test`. Specifically:

- A missing or unpublished upstream tag → `podman build` fails on the `FROM`
  with a registry error naming the tag.
- Either version unreadable in `version-tag-%` → fails loudly rather than
  emitting an unversioned tag.

## Out of Scope

Deferred: pushing these images to a registry, CI, aligning the tag scheme with
the upstreams' (including `latest`), multi-arch manifests, digest-pinning the
upstream bases, provider mirroring or caching inside the image, and OpenTofu.

Both upstreams now publish to Docker Hub and container-ansible runs CI, so
publishing is the natural next phase for this repo — and the tag-scheme alignment
noted above belongs with it.

## Revision history

**2026-08-08, original.** Four variants built `FROM localhost/ansible:<variant>`,
each downloading and verifying Terraform from `releases.hashicorp.com` in a
throwaway stage: version resolution within a declared line, GPG signature check
against a pinned fingerprint, SHA256 verification. Smoke test asserted the
Terraform line and prerelease-ness per channel.

**2026-08-08, revised.** container-ansible began publishing to
`docker.io/pdutton/ansible`, and the Terraform install was split out into
container-terraform, which builds locally today and publishes to
`docker.io/pdutton/terraform` shortly. Consequently:

- Both bases now pull from Docker Hub; the local-image preflight is dropped.
- The download/verify stage is deleted entirely. Terraform arrives as a
  `COPY --from` of one static file.
- The Terraform line declaration, `TF_LINE`, the pinned GPG fingerprint, and the
  channel assertions all move to container-terraform.
- `PODMAN_BUILD_FLAGS` is adopted, because composed images go stale invisibly.
- Implementation is blocked until `pdutton/terraform` publishes.
