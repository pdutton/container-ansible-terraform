# Phase 1: Terraform Images on the container-ansible Base

**Date:** 2026-08-08
**Status:** Approved

## Goal

Build four container image variants locally with Podman, each layering Terraform
onto the corresponding image from
[container-ansible](https://github.com/pdutton/container-ansible), and verify
each one by running Ansible against Terraform inside it. Nothing in this phase
publishes images, builds multi-arch manifests, or runs in CI.

Base images are consumed from the local Podman store as `localhost/ansible:<variant>`.
They are a prerequisite, not a dependency this repo builds.

## Variant Matrix

| Variant | Base image | Terraform line | Resolves to (2026-08-08) |
|---|---|---|---|
| `alpine-stable` | `localhost/ansible:alpine-stable` | 1.15 | 1.15.8 |
| `alpine-development` | `localhost/ansible:alpine-development` | 1.16 beta/RC | 1.16.0-beta2 |
| `ubuntu-stable` | `localhost/ansible:ubuntu-stable` | 1.15 | 1.15.8 |
| `ubuntu-development` | `localhost/ansible:ubuntu-development` | 1.16 beta/RC | 1.16.0-beta2 |

### Terraform is not packaged by either distro

Verified on 2026-08-08 against the actual base images:

- Alpine 3.23 has no `terraform` package. It was removed from aports after the
  BUSL relicense.
- Ubuntu 26.04 carries only peripheral tooling — `terraform-switcher`,
  `terraform-config-inspect`, `tfk8s`, and some Go libraries — not Terraform.

So the mechanism container-ansible uses for its STABLE channel, "install from the
distro package manager", has no analogue here. Both channels install the same
way: a verified zip from `releases.hashicorp.com`.

### What the channel names mean here

In container-ansible, STABLE and DEVELOPMENT differ in *install method* — distro
package versus pip-into-a-venv — and the pinned OS release acts as the version
selector.

Here both channels install identically and the only thing that varies is the
declared version line. The channel word therefore carries its meaning from two
places at once: the Ansible channel inherited from the base image, and the
Terraform line declared in the Containerfile. This asymmetry with upstream is
intentional and should not be "fixed" by inventing a second install method.

### Channel resolution

Each Containerfile declares its line as `ARG TF_LINE`, and stage 1 queries
`https://releases.hashicorp.com/terraform/index.json` for the newest match:

- STABLE: newest release on the line with no prerelease suffix.
- DEVELOPMENT: newest `-beta*` or `-rc*` on the line. Alphas are excluded — they
  have no quality bar and churn close to daily, so an image built from one is a
  different snapshot every rebuild.

If no match exists, **the build fails**. It does not fall back to stable, and it
does not roll onto the next line. When 1.16.0 goes final its betas stop being the
newest thing on the line, the DEVELOPMENT build fails, and the fix is to bump
STABLE to 1.16 and DEVELOPMENT to 1.17. This is container-ansible's rule — a
channel fails loudly rather than silently redefining itself — transplanted to a
source that has no distro release to pin it.

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

Four explicit Containerfiles, matching upstream. Nothing is `COPY`d from the
build context, so `.dockerignore` keeps the context near-empty exactly as
upstream's does.

Image name: `IMAGE ?= ansible-terraform`. Base repository: `BASE ?= localhost/ansible`.
Terraform is installed to `/usr/local/bin/terraform`, which is on `PATH` in all
four variants — on the DEVELOPMENT variants `/opt/ansible/bin` is *prepended* to
`PATH`, not substituted for it.

## Containerfiles

Two stages each. Stage 1 is a throwaway Alpine downloader; stage 2 is the shipped
image. Only the binary crosses between them, so `curl`, `jq`, `gnupg` and `unzip`
never appear in the result.

```dockerfile
FROM docker.io/library/alpine:3.23 AS terraform

ARG TF_LINE=1.15
ARG HASHICORP_KEY=C874011F0AB405110D02105534365D9472D7468F

RUN apk add --no-cache curl jq gnupg unzip coreutils

RUN set -eu; \
    version="$(curl -fsSL https://releases.hashicorp.com/terraform/index.json \
      | jq -r --arg l "$TF_LINE" '.versions|keys[]|select(startswith($l+"."))' \
      | grep -Ev -- '-(alpha|beta|rc)' | sort -V | tail -1)"; \
    [ -n "$version" ] || { echo "ERROR: no release on line $TF_LINE" >&2; exit 1; }; \
    case "$(uname -m)" in x86_64) arch=amd64;; aarch64) arch=arm64;; \
      *) echo "ERROR: unsupported arch $(uname -m)" >&2; exit 1;; esac; \
    base="https://releases.hashicorp.com/terraform/$version"; \
    curl -fsSLO "$base/terraform_${version}_linux_${arch}.zip"; \
    curl -fsSLO "$base/terraform_${version}_SHA256SUMS"; \
    curl -fsSLO "$base/terraform_${version}_SHA256SUMS.sig"; \
    curl -fsSL https://www.hashicorp.com/.well-known/pgp-key.txt | gpg --import; \
    gpg --with-colons --fingerprint | grep -q "^fpr:::::::::$HASHICORP_KEY:"; \
    gpg --verify "terraform_${version}_SHA256SUMS.sig" "terraform_${version}_SHA256SUMS"; \
    sha256sum --ignore-missing -c "terraform_${version}_SHA256SUMS"; \
    unzip "terraform_${version}_linux_${arch}.zip" -d /out

FROM localhost/ansible:alpine-stable

LABEL org.opencontainers.image.title="ansible-terraform" \
      org.opencontainers.image.description="Terraform 1.15 (stable) on Ansible 13 (stable), Alpine 3.23" \
      org.opencontainers.image.licenses="GPL-3.0-or-later AND BUSL-1.1" \
      org.opencontainers.image.source="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.url="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="localhost/ansible:alpine-stable"

COPY --from=terraform /out/terraform /usr/local/bin/terraform

WORKDIR /apps
CMD ["terraform", "-help"]
```

The file above is `Containerfile.alpine-stable`. The other three differ from it
only as follows:

| File | Differences |
|---|---|
| `Containerfile.ubuntu-stable` | stage 2 `FROM`, `base.name`, description |
| `Containerfile.alpine-development` | `ARG TF_LINE=1.16`; version filter keeps `-(beta\|rc)` matches instead of dropping all prereleases; stage 2 `FROM`, `base.name`, description |
| `Containerfile.ubuntu-development` | same as `alpine-development` |

Stage 1 stays on Alpine in all four, because it is thrown away and its only job
is to produce a verified binary.

Version ordering relies on GNU `sort -V` from `coreutils`, which Alpine installs
at `/usr/bin/sort` — ahead of busybox's `/bin/sort` on the default `PATH`. It
orders `1.16.0-beta2` before `1.16.0-rc1`, and both before `1.16.0`, which is the
ordering both filters need.

### The Terraform binary is portable across both bases

HashiCorp's official `linux_amd64` and `linux_arm64` Terraform builds are
statically linked. The same downloaded artifact runs on the musl (Alpine) and
glibc (Ubuntu) bases alike, which is why one Alpine downloader stage can serve
all four variants.

### Signature verification

The fingerprint pin is the load-bearing part. Fetching HashiCorp's key over HTTPS
and then verifying a signature with the key just fetched proves only that the two
came from the same place. Pinning `C874011F0AB405110D02105534365D9472D7468F` in
the repo is what makes it a real check.

Verified on 2026-08-08: `https://www.hashicorp.com/.well-known/pgp-key.txt` serves
`C874 011F 0AB4 0511 0D02 1055 3436 5D94 72D7 468F`, "HashiCorp Security
(hashicorp.com/security)", RSA 4096, expiring 2030-03-01. When that key expires or
rotates, the pin must be updated deliberately — the build failing is the intended
behavior, not a bug to route around.

`coreutils` is installed in the downloader because busybox's `sha256sum` does not
support `--ignore-missing`, which is needed since `SHA256SUMS` covers every
platform's artifact and only one was downloaded.

### Architecture

`arch` is derived from `uname -m` rather than hardcoded to `amd64`. Multi-arch
manifests remain out of scope; this is only about the build working on the host
it runs on. It costs three lines and converts a baffling runtime
`exec format error` on an arm64 host into a build that simply works. An
unrecognized machine type fails the build explicitly.

### CMD

`CMD ["terraform", "-help"]`. Upstream uses `ansible --help`; Terraform is what
this layer contributes, so it takes the default. As upstream, there is **no
`ENTRYPOINT`** — documented usage passes the binary explicitly, so the image
stays a plain command host.

## Makefile

Mirrors upstream's shape: `build-<variant>`, `test-<variant>`, `build`, `test`,
`version-tag-<variant>`, `clean`, and `help` as the default goal. Overridable
external tools follow the existing `AWK ?=` / `PODMAN ?=` pattern.

```make
IMAGE    ?= ansible-terraform
BASE     ?= localhost/ansible
VARIANTS := alpine-stable alpine-development ubuntu-stable ubuntu-development

tf-line-stable      := 1.15
tf-line-development := 1.16

prerelease-stable      := false
prerelease-development := true
```

### Declared twice, on purpose

`tf-line-*` in the Makefile feeds the smoke test's assertion only. The actual
selector is the `ARG TF_LINE` in each Containerfile. This mirrors upstream
exactly, where the real selector is the `FROM alpine:3.23` line and
`major-stable := 13` exists solely so the smoke test can check it. One side
declares, the other independently verifies; collapsing them into a single source
would remove the check.

### Preflight

Before building a variant, confirm `$(BASE):<variant>` is present in the local
image store. If it is absent, fail with a message naming container-ansible as the
prerequisite rather than letting Podman attempt a registry pull of
`localhost/ansible` and emit an opaque error.

### Build and version tagging

`build-%` runs `podman build` with `--label org.opencontainers.image.created`
and `.revision` supplied from the Makefile, keeping the Containerfiles free of
build args — as upstream does.

`version-tag-%` then reads **both** versions out of the freshly built image:

- `ansible-community --version` → the Ansible bundle version (e.g. `13.0.0`).
  Note this is the bundle version, not `ansible --version`, which reports core.
- `terraform version` → the Terraform version, with the leading `v` stripped
  (e.g. `1.15.8`).

Both are applied as the tag suffix `<os>-<ansible>-<terraform>` and as
`org.opencontainers.image.version`, in the same one-line `FROM`+`LABEL` pass
upstream uses. Neither version is ever typed into the repo, so tags cannot drift
from what is installed.

Tags existing after a full build:

| Channel tag | Version tag |
|---|---|
| `alpine-stable` | `alpine-13.0.0-1.15.8` |
| `alpine-development` | `alpine-14.2.0-1.16.0-beta2` |
| `ubuntu-stable` | `ubuntu-13.1.0-1.15.8` |
| `ubuntu-development` | `ubuntu-14.2.0-1.16.0-beta2` |

Both versions appear because either can move independently — a rebuild picking up
a newer Ansible base with the same Terraform would otherwise silently reuse a
tag. The prerelease suffix makes the DEVELOPMENT tags visually busy; that is
accepted in exchange for every distinct image having a distinct tag.

### Clean

As upstream: remove the tags this repo applies, and do not run a blanket
`podman image prune`, which would delete untagged images this repo never built.
The orphaned `<none>` layers left by each `version-tag-%` pass accumulate and are
documented in the README as something to prune manually.

## Testing

`community.general.terraform` is present in the base images (community.general
12.0.1, verified 2026-08-08 with no deprecation notice). `cloud.terraform` is not
in the bundle. The smoke test therefore drives Terraform through a real Ansible
module rather than shelling out — which is precisely the composition these images
exist to provide.

### `test/terraform/main.tf`

```hcl
variable "greeting" {
  type    = string
  default = "ok"
}

resource "terraform_data" "smoke" {
  input = var.greeting
}

output "message" {
  value = "${terraform_data.smoke.output}-from-terraform"
}
```

No providers and no backend, so `init` needs no registry access and the test runs
fully offline. `terraform_data` is a builtin managed resource (Terraform 1.4+),
which makes this more than a syntax check: it exercises the real
init → plan → apply → state path.

### `test/smoke.yml`

Run as upstream runs its own:

```
podman run --rm -v ./test:/apps:ro,z $(IMAGE):$* \
  ansible-playbook -i localhost, -c local smoke.yml \
  -e expect_tf_line=$(tf-line-<channel>) \
  -e expect_prerelease=$(prerelease-<channel>)
```

Assertions, in order:

1. `expect_tf_line` was supplied — guards against a bare invocation quietly
   asserting nothing.
2. `terraform version -json` reports a version on the declared line. This is the
   channel-drift guard, the counterpart to upstream's `expect_major` check.
3. Prerelease-ness matches the channel: DEVELOPMENT must carry a `-beta`/`-rc`
   suffix, STABLE must carry none. Catches a resolver bug that hands STABLE a
   prerelease or DEVELOPMENT a final release.
4. Ansible copies `main.tf` into `/tmp/tfsmoke`. Required, not incidental:
   `test/` is mounted read-only and Terraform must write `.terraform/` and state.
5. `community.general.terraform` runs it with `project_path: /tmp/tfsmoke`,
   `state: present`, `force_init: true`.
6. The registered output `message` equals `ok-from-terraform`.

Steps 4–6 are the substance. A Terraform binary that is present but broken —
wrong architecture, truncated download, missing execute bit — fails there even if
it somehow satisfied step 2.

### Not retested here

Ansible's own capabilities — `json_query`, `password_hash`, and the
WinRM/Kerberos/SELinux stack — are container-ansible's contract and are covered
by its suite. Duplicating those assertions here would drift out of sync with the
upstream definitions they mirror.

## Licensing

Terraform 1.6.0 and later are licensed under BUSL-1.1, not an open-source
license. Verified against the 1.15.8 tag on 2026-08-08:

- Licensor: International Business Machines Corporation (IBM).
- Additional Use Grant: production use is permitted, *provided* the use does not
  include offering Terraform to third parties on a hosted or embedded basis in
  order to compete with IBM's paid versions of it.
- Change Date: four years from publication. Change License: MPL-2.0.

Redistribution inside a container image is permitted, so building and using these
images is fine. But upstream's `org.opencontainers.image.licenses=GPL-3.0-or-later`
would be inaccurate on an image containing a BUSL binary — a scanner reading that
label alone would conclude the image is freely usable.

The images therefore carry `GPL-3.0-or-later AND BUSL-1.1`, a valid SPDX
expression covering this repo's own contribution and the inherited Ansible stack
(GPL) alongside the Terraform binary (BUSL).

`LICENSE` stays as the bare GPLv3 text for this repo's own code. As upstream, the
README makes the "or later" election explicit, since the license text does not
make it itself. A README section states the BUSL terms above in plain language;
that section is what makes the label honest rather than merely present.

## README

Following upstream's structure:

- Usage aliases for running `terraform` and `ansible-playbook` out of the image,
  with the same single-quoted `"$PWD"` caveat and the same SELinux warning about
  mounting `~/.ssh`.
- The variant table, including which Ansible bundle and Terraform version each
  currently resolves to.
- Capability differences inherited from the base: the Alpine variants have no
  WinRM/Kerberos/SELinux support, the Ubuntu variants do.
- Building locally, stating up front that container-ansible's images must be
  built first, and that both channels reach the network at build time to resolve
  and download Terraform.
- The tag scheme, and the note that DEVELOPMENT version tags are a snapshot
  rather than a promise — the resolver picks whatever the newest beta/RC is at
  build time.
- The licensing section described above.
- A `## Planned` section for the deferred items below.

## Error Handling

Make halts on any non-zero exit, so nothing broken reaches tagging and a failed
assertion cannot yield a green `make test`. Specifically:

- Missing base image → preflight fails naming container-ansible.
- Empty version resolution → build fails rather than defaulting to anything.
- GPG fingerprint mismatch, bad signature, or bad checksum → build fails.
- Unrecognized `uname -m` → build fails.
- Either version unreadable in `version-tag-%` → fails loudly rather than
  emitting an unversioned tag.

## Out of Scope

Deferred to later phases: pushing to a registry, multi-arch manifests, CI, a
`latest` tag, provider mirroring or caching inside the image, OpenTofu as an
alternative or additional binary, and Terraform lines other than the two current
channels.
