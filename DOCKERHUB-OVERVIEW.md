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

This repo's Tags list on Docker Hub also carries a version-shaped tag per variant
(`<os>-<ansible-version>-<terraform-version>`). Those look like pins but are not: every tag here,
version-shaped or not, is a moving pointer that a later rebuild can re-push at a new image. If you
need reproducibility, pin by digest rather than by tag.

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
