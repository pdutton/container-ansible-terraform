# container-ansible-terraform

Container images with both Ansible and Terraform.

These images compose two upstream repos: the Ansible images from
[container-ansible](https://github.com/pdutton/container-ansible) and the
Terraform binary from
[container-terraform](https://github.com/pdutton/container-terraform). Nothing is
installed here — no archives are downloaded, no signatures verified, no versions
resolved. All of that lives upstream. This repo composes.

## Ansible and Terraform Without Installing

```
alias terraform='podman run -ti --rm -v "$PWD":/apps -w /apps localhost/ansible-terraform:alpine-stable terraform'
terraform <follow command>
```

```
alias ansible-playbook='podman run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps localhost/ansible-terraform:alpine-stable ansible-playbook'
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
make build-alpine-stable   # build just one variant
make clean                 # remove all tagged images this repo builds
```

Run `make help` (or just `make`) to list every target, including the per-variant `build-<variant>` and
`test-<variant>` names (`test-<variant>` builds first).

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

Each variant produces **two tags** pointing at the same image:

- `<os>-<channel>` — e.g. `alpine-stable`, `ubuntu-development`. Stable across rebuilds; use this in scripts and
  aliases.
- `<os>-<ansible>-<terraform>` — e.g. `alpine-13.0.0-1.15.8`, `ubuntu-14.2.0-1.16.0-beta2`. Derived at build time
  by reading `ansible-community --version` and `terraform version` out of the freshly built image, so they always
  reflect what is actually installed.

Both versions appear in the tag because either can move independently — a rebuild picking up a newer Ansible with
the same Terraform would otherwise silently reuse a tag. You can read either value yourself:

```bash
podman run --rm localhost/ansible-terraform:alpine-stable ansible-community --version
podman run --rm localhost/ansible-terraform:alpine-stable terraform version
```

The eight tags that exist after a full build: `alpine-stable`, `alpine-development`, `ubuntu-stable`,
`ubuntu-development`, `alpine-13.0.0-1.15.8`, `alpine-14.2.0-1.16.0-beta2`, `ubuntu-13.1.0-1.15.8`,
`ubuntu-14.2.0-1.16.0-beta2`.

**These images are not published to any registry.** Both upstreams publish to Docker Hub; this repo does not yet.

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

- Publishing these images to Docker Hub, and the CI to do it. Both upstreams already do this.
- A tag scheme aligned with the upstreams'. container-ansible produces 15 tags and container-terraform 7,
  including `latest`, `<os>`, and major/minor-line tags; this repo produces two per variant and no `latest`.
- Multi-arch builds for both `amd64` and `arm64`.
- Digest-pinning the upstream base images rather than tracking their tags.
