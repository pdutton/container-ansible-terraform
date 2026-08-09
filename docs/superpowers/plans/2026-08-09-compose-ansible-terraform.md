# Ansible + Terraform Image Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build four container images that compose the published Ansible images with the Terraform binary from the published Terraform image, verified by having Ansible drive Terraform inside each.

**Architecture:** Each variant is one Containerfile with two `FROM` lines — a named `terraform` stage used only as a copy source, and the Ansible image as the actual base — plus a single `COPY --from` of `/usr/local/bin/terraform`. This repo installs nothing: version resolution, signature verification and channel guards all live in the two upstream repos. A Makefile drives build, smoke test, dual-version tagging and cleanup.

**Tech Stack:** Podman 5.x, GNU Make, Ansible playbooks (`community.general.terraform`), Terraform (`terraform_data` builtin), HCL.

**Spec:** `docs/superpowers/specs/2026-08-08-terraform-image-build-design.md`

## Global Constraints

- Image name: `IMAGE ?= ansible-terraform`. Every local reference goes through `LOCAL_IMAGE = localhost/$(IMAGE)` — never a bare `$(IMAGE)`, which can resolve by an implicit registry tie-break.
- The four variants are exactly: `alpine-stable`, `alpine-development`, `ubuntu-stable`, `ubuntu-development`.
- Ansible base: `docker.io/pdutton/ansible:<variant>`. Terraform source: `docker.io/pdutton/terraform:stable` for `*-stable`, `docker.io/pdutton/terraform:development` for `*-development`.
- **No build args in Containerfiles.** The `FROM` lines are the selectors and are edited deliberately.
- **No `ENTRYPOINT`.** `CMD ["terraform", "-help"]` in every variant.
- Every image carries `org.opencontainers.image.licenses="GPL-3.0-or-later AND BUSL-1.1"` — verbatim, both halves.
- `org.opencontainers.image.base.name` names the **Ansible** image only. The Terraform image is a copy source, not a base.
- Dynamic labels (`created`, `revision`) come from the Makefile via `--label`; static labels live in the Containerfile.
- Version tags are read out of the built image, never typed.
- This repo publishes nothing. No `push` target, no CI, no `latest` tag.
- Do not add version, channel, or prerelease assertions to the smoke test. Those guards live in container-terraform, where the declarations live.

---

### Task 1: Repo scaffolding, smoke test, and the first variant

Delivers a buildable, testable `alpine-stable` image. `VARIANTS` holds only that one variant so `make test` is green at the end of this task; Task 2 expands it.

**Files:**
- Create: `.gitignore`
- Create: `.dockerignore`
- Create: `test/terraform/main.tf`
- Create: `test/smoke.yml`
- Create: `Containerfile.alpine-stable`
- Create: `Makefile`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `make build-<variant>` and `make test-<variant>` pattern rules; `LOCAL_IMAGE = localhost/ansible-terraform`; the smoke playbook at `test/smoke.yml` expecting the config at `/apps/terraform/main.tf` and asserting the string `ok-from-terraform`.

- [x] **Step 1: Write the failing test — the Terraform config and the smoke playbook**

`test/terraform/main.tf`:

```hcl
# No providers and no backend: `terraform init` needs no registry access, so the
# smoke test runs fully offline. terraform_data is a builtin managed resource
# (Terraform 1.4+), which makes this more than a syntax check -- it exercises the
# real init -> plan -> apply -> state path.
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

`test/smoke.yml`:

```yaml
---
- name: Smoke-test the ansible-terraform image
  hosts: localhost
  gather_facts: false
  vars:
    ansible_python_interpreter: "{{ ansible_playbook_python }}"

  tasks:
    # /apps is mounted read-only and Terraform must write .terraform/ and state,
    # so the config is copied somewhere writable first. `copy` does not create a
    # missing destination directory, hence this task.
    - name: Create a writable working directory
      ansible.builtin.file:
        path: /tmp/tfsmoke
        state: directory
        mode: "0755"

    - name: Copy the Terraform config somewhere writable
      ansible.builtin.copy:
        src: /apps/terraform/main.tf
        dest: /tmp/tfsmoke/main.tf
        mode: "0644"

    # Driving Terraform through a real Ansible module, not a shell-out, is the
    # point: the composition is what this image exists to provide.
    - name: Run it with the Terraform module
      community.general.terraform:
        project_path: /tmp/tfsmoke
        state: present
        force_init: true
      register: tf

    - name: Assert the output round-tripped
      ansible.builtin.assert:
        that:
          - tf.outputs.message.value == "ok-from-terraform"
        success_msg: "composition OK: {{ tf.outputs.message.value }}"
        fail_msg: "expected ok-from-terraform, got {{ tf.outputs | default('no outputs') }}"
```

- [x] **Step 2: Run it to verify it fails**

Run: `make test-alpine-stable`

Expected: FAIL — `make: *** No rule to make target 'test-alpine-stable'`. There is no Makefile yet. This confirms the test cannot pass by accident before the image exists.

- [x] **Step 3: Write `.gitignore` and `.dockerignore`**

`.gitignore` (vim artifacts, matching both upstream repos):

```
# Vim temporary files
# Swap files, including the dot-prefixed form vim uses beside the edited file
# (e.g. .Makefile.swp)
[._]*.s[a-v][a-z]
[._]*.sw[a-p]
[._]s[a-v][a-z]
[._]sw[a-p]
*.s[a-v][a-z]
*.sw[a-p]

# Backup files and persistent undo
*~
[._]*.un~
*.un~

# Session and netrw history
Session.vim
Sessionx.vim
.netrwhist
```

`.dockerignore` — nothing is `COPY`d from the context, so this exists purely to keep the context near-empty:

```
.git/
docs/
test/
Makefile
README.md
LICENSE
CLAUDE.md
```

- [x] **Step 4: Write `Containerfile.alpine-stable`**

```dockerfile
# The terraform stage is a copy source only -- none of its layers are inherited.
# Naming it puts both upstream dependencies at the top of the file where they can
# be read at a glance.
FROM docker.io/pdutton/terraform:stable AS terraform

FROM docker.io/pdutton/ansible:alpine-stable

LABEL org.opencontainers.image.title="ansible-terraform" \
      org.opencontainers.image.description="Terraform (stable) with Ansible 13 (stable) on Alpine 3.23" \
      org.opencontainers.image.licenses="GPL-3.0-or-later AND BUSL-1.1" \
      org.opencontainers.image.source="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.url="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="docker.io/pdutton/ansible:alpine-stable"

COPY --from=terraform /usr/local/bin/terraform /usr/local/bin/terraform

WORKDIR /apps
CMD ["terraform", "-help"]
```

- [x] **Step 5: Write the minimal `Makefile`**

```make
IMAGE       ?= ansible-terraform
VARIANTS    := alpine-stable

# Every local image reference goes through this, never a bare $(IMAGE): an
# unqualified name can resolve by an implicit registry tie-break, which is not
# something the highest-stakes lines in this file should depend on.
LOCAL_IMAGE  = localhost/$(IMAGE)

# External tools, overridable: `make PODMAN=/usr/local/bin/podman build`
AWK      ?= /usr/bin/awk
PODMAN   ?= /usr/bin/podman

# Extra build flags. Empty by default. Neither FROM line's TEXT changes when an
# upstream republishes its tags, so podman reuses the cached layers and a plain
# rebuild will NOT pick up a new base. This matters more here than upstream:
# these images are composed entirely of other repos' content, so a plain
# `make build` can reproduce yesterday's image while both inputs have moved.
#
#   make build PODMAN_BUILD_FLAGS="--pull"
PODMAN_BUILD_FLAGS ?=

BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_REV    := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)

.DEFAULT_GOAL := help
.PHONY: help build test

help:
	@echo "Targets:"
	@echo "  build                 Build all variants"
	@echo "  test                  Smoke-test all variants"
	@$(foreach v,$(VARIANTS),echo "  build-$(v)"; echo "  test-$(v)";)
	@echo
	@echo "Variants: $(VARIANTS)"
	@echo
	@echo "A plain rebuild reuses cached layers and will not see republished"
	@echo "upstream images. To refresh:"
	@echo '  make build PODMAN_BUILD_FLAGS="--pull"'

build: $(addprefix build-,$(VARIANTS))

test: $(addprefix test-,$(VARIANTS))

build-%: Containerfile.%
	$(PODMAN) build -f Containerfile.$* -t $(LOCAL_IMAGE):$* \
	  --label org.opencontainers.image.created=$(BUILD_DATE) \
	  --label org.opencontainers.image.revision=$(GIT_REV) \
	  $(PODMAN_BUILD_FLAGS) \
	  .

test-%: build-%
	$(PODMAN) run --rm -v ./test:/apps:ro,z $(LOCAL_IMAGE):$* \
	  ansible-playbook -i localhost, -c local smoke.yml
```

- [x] **Step 6: Run the test to verify it passes**

Run: `make test-alpine-stable`

Expected: the build pulls both upstream images, then the playbook runs and ends with:

```
TASK [Assert the output round-tripped] *****
ok: [localhost] => {
    "changed": false,
    "msg": "composition OK: ok-from-terraform"
}

PLAY RECAP ****
localhost : ok=4  changed=3  unreachable=0  failed=0
```

If `community.general.terraform` reports "Destination directory /tmp/tfsmoke does not exist", the `file:` task in Step 1 is missing or misordered.

- [x] **Step 7: Verify the labels landed**

Run:

```bash
podman inspect --format '{{index .Labels "org.opencontainers.image.licenses"}} | {{index .Labels "org.opencontainers.image.base.name"}} | {{index .Labels "org.opencontainers.image.revision"}}' localhost/ansible-terraform:alpine-stable
```

Expected: `GPL-3.0-or-later AND BUSL-1.1 | docker.io/pdutton/ansible:alpine-stable | <the current git SHA>`

- [x] **Step 8: Commit**

```bash
git add .gitignore .dockerignore Makefile Containerfile.alpine-stable test/
git commit -m "Add the alpine-stable variant and its smoke test

Composes docker.io/pdutton/ansible:alpine-stable with the Terraform
binary from docker.io/pdutton/terraform:stable. The smoke test drives
Terraform through community.general.terraform against a provider-less
terraform_data config, so it exercises the real init/plan/apply path
offline."
```

---

### Task 2: The remaining three variants

**Files:**
- Create: `Containerfile.alpine-development`
- Create: `Containerfile.ubuntu-stable`
- Create: `Containerfile.ubuntu-development`
- Modify: `Makefile` (the `VARIANTS` line only)

**Interfaces:**
- Consumes: the `build-%` / `test-%` pattern rules and `LOCAL_IMAGE` from Task 1; `test/smoke.yml` unchanged — it is variant-agnostic.
- Produces: all four variants buildable as `localhost/ansible-terraform:<variant>`.

- [x] **Step 1: Run the full test suite to verify three variants are missing**

Run: `make test`

Expected: PASS, but only `alpine-stable` runs — `VARIANTS` still holds one entry. This is the baseline.

- [x] **Step 2: Write `Containerfile.ubuntu-stable`**

Differs from `alpine-stable` in the Ansible `FROM`, `base.name` and description. The Terraform `FROM` stays `:stable` — Terraform has no OS axis, so its `FROM` changes on the channel axis only.

```dockerfile
FROM docker.io/pdutton/terraform:stable AS terraform

FROM docker.io/pdutton/ansible:ubuntu-stable

LABEL org.opencontainers.image.title="ansible-terraform" \
      org.opencontainers.image.description="Terraform (stable) with Ansible 13 (stable) on Ubuntu 26.04" \
      org.opencontainers.image.licenses="GPL-3.0-or-later AND BUSL-1.1" \
      org.opencontainers.image.source="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.url="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="docker.io/pdutton/ansible:ubuntu-stable"

COPY --from=terraform /usr/local/bin/terraform /usr/local/bin/terraform

WORKDIR /apps
CMD ["terraform", "-help"]
```

- [x] **Step 3: Write `Containerfile.alpine-development`**

```dockerfile
FROM docker.io/pdutton/terraform:development AS terraform

FROM docker.io/pdutton/ansible:alpine-development

LABEL org.opencontainers.image.title="ansible-terraform" \
      org.opencontainers.image.description="Terraform (development) with Ansible 14 (development) on Alpine 3.23" \
      org.opencontainers.image.licenses="GPL-3.0-or-later AND BUSL-1.1" \
      org.opencontainers.image.source="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.url="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="docker.io/pdutton/ansible:alpine-development"

COPY --from=terraform /usr/local/bin/terraform /usr/local/bin/terraform

WORKDIR /apps
CMD ["terraform", "-help"]
```

- [x] **Step 4: Write `Containerfile.ubuntu-development`**

```dockerfile
FROM docker.io/pdutton/terraform:development AS terraform

FROM docker.io/pdutton/ansible:ubuntu-development

LABEL org.opencontainers.image.title="ansible-terraform" \
      org.opencontainers.image.description="Terraform (development) with Ansible 14 (development) on Ubuntu 26.04" \
      org.opencontainers.image.licenses="GPL-3.0-or-later AND BUSL-1.1" \
      org.opencontainers.image.source="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.url="https://github.com/pdutton/container-ansible-terraform" \
      org.opencontainers.image.vendor="pdutton" \
      org.opencontainers.image.base.name="docker.io/pdutton/ansible:ubuntu-development"

COPY --from=terraform /usr/local/bin/terraform /usr/local/bin/terraform

WORKDIR /apps
CMD ["terraform", "-help"]
```

- [x] **Step 5: Expand `VARIANTS` in the Makefile**

Replace:

```make
VARIANTS    := alpine-stable
```

with:

```make
VARIANTS    := alpine-stable alpine-development ubuntu-stable ubuntu-development
```

- [x] **Step 6: Run the full test suite to verify all four pass**

Run: `make test`

Expected: four builds, four playbook runs, each ending `failed=0` with `composition OK: ok-from-terraform`.

- [x] **Step 7: Verify each variant got the right Terraform channel**

Nothing in the smoke test asserts this (by design — the guard lives in container-terraform), so check it by hand once, here:

```bash
for v in alpine-stable alpine-development ubuntu-stable ubuntu-development; do
  printf '%-20s ' "$v"
  podman run --rm localhost/ansible-terraform:$v sh -c 'terraform version | head -1; ansible-community --version' | tr '\n' ' '
  echo
done
```

Expected: both `*-stable` rows show a plain Terraform version (no `-beta`/`-rc`) with Ansible 13.x; both `*-development` rows show a `-beta`/`-rc` version with Ansible 14.x. A `*-stable` row showing a beta means a Containerfile's Terraform `FROM` is miswired.

- [x] **Step 8: Commit**

```bash
git add Containerfile.alpine-development Containerfile.ubuntu-stable Containerfile.ubuntu-development Makefile
git commit -m "Add the remaining three variants

The Terraform FROM changes on the channel axis only -- both *-stable
variants share terraform:stable and both *-development variants share
terraform:development, since a static binary makes the base OS
irrelevant to Terraform and container-terraform has no OS axis."
```

---

### Task 3: Dual-version tagging and cleanup

**Files:**
- Modify: `Makefile` — add `version-tag-%` and `clean`, add `@$(MAKE) version-tag-$*` to `build-%`, add `clean` to `.PHONY` and `help`.

**Interfaces:**
- Consumes: `LOCAL_IMAGE`, `PODMAN`, `AWK`, and the `build-%` rule from Task 1.
- Produces: a second tag per variant, `<os>-<ansible-version>-<terraform-version>`, e.g. `alpine-13.0.0-1.15.8`; and `org.opencontainers.image.version` set to `<ansible-version>-<terraform-version>`.

- [x] **Step 1: Write the failing test — assert the version tag exists**

There is no test harness for the Makefile, so the check is a command. Run:

```bash
podman image exists localhost/ansible-terraform:alpine-13.0.0-1.15.8 && echo TAGGED || echo MISSING
```

Expected: `MISSING`. (If the Ansible or Terraform versions have moved since this plan was written, substitute the versions reported by Task 2 Step 7 — the point is that no `<os>-<av>-<tv>` tag exists yet.)

- [x] **Step 2: Add `version-tag-%` to the Makefile**

Insert after the `build-%` rule:

```make
# Read BOTH versions out of the freshly built image and apply them as a tag and
# a label, so a tag can never drift from what is installed.
#
#  * `ansible-community --version` prints the BUNDLE version ("Ansible community
#    version 13.0.0"). NOT `ansible --version`, which reports core (2.20.x) -- a
#    different number that is not what these tags mean.
#  * `terraform version` prints "Terraform v1.15.8" on its first line; the
#    leading v is stripped.
#
# Both versions appear in the tag because either can move independently: a
# rebuild picking up a newer Ansible with the same Terraform would otherwise
# silently reuse a tag.
#
# Guard: os/channel come from word 1/2 of $* split on '-', which silently
# discards anything past word 2. Without the check, a future variant such as
# ubuntu-stable-slim would compute os=ubuntu and claim ubuntu-stable's tag.
# Reassembling and comparing to $* is used rather than a case/glob pattern,
# because a shell glob `*` matches '-' too and so cannot exclude extra segments.
version-tag-%:
	@set -eu; \
	av=$$($(PODMAN) run --rm $(LOCAL_IMAGE):$* ansible-community --version | $(AWK) 'NR==1{print $$NF}'); \
	case "$$av" in \
	  [0-9]*.[0-9]*.[0-9]*) ;; \
	  *) echo "ERROR: could not read the Ansible bundle version from $(LOCAL_IMAGE):$* (got '$$av')" >&2; exit 1 ;; \
	esac; \
	tv=$$($(PODMAN) run --rm $(LOCAL_IMAGE):$* terraform version | $(AWK) 'NR==1{print $$NF}'); \
	tv=$${tv#v}; \
	case "$$tv" in \
	  [0-9]*.[0-9]*.[0-9]*) ;; \
	  *) echo "ERROR: could not read the Terraform version from $(LOCAL_IMAGE):$* (got '$$tv')" >&2; exit 1 ;; \
	esac; \
	os="$(word 1,$(subst -, ,$*))"; \
	channel="$(word 2,$(subst -, ,$*))"; \
	if [ -z "$$os" ] || [ -z "$$channel" ] || [ "$$os-$$channel" != "$*" ]; then \
	  echo "ERROR: variant '$*' is not exactly two non-empty '-'-separated words (<os>-<channel>); refusing to tag, since word 1/word 2 would silently drop the rest and could overwrite another variant's tags" >&2; \
	  exit 1; \
	fi; \
	printf 'FROM %s:%s\nLABEL org.opencontainers.image.version="%s"\n' "$(LOCAL_IMAGE)" "$*" "$$av-$$tv" \
	  | $(PODMAN) build -f - -t "$(LOCAL_IMAGE):$*" -t "$(LOCAL_IMAGE):$$os-$$av-$$tv" .; \
	echo "Tagged $(LOCAL_IMAGE):$$os-$$av-$$tv"
```

- [x] **Step 3: Call it from `build-%`**

Append this line to the end of the `build-%` recipe, after the `.`:

```make
	@$(MAKE) --no-print-directory version-tag-$*
```

- [x] **Step 4: Run the build and verify the tag appears**

Run: `make build-alpine-stable`

Expected: the build ends with `Tagged localhost/ansible-terraform:alpine-13.0.0-1.15.8` (versions per your build). Then:

```bash
podman image exists localhost/ansible-terraform:alpine-13.0.0-1.15.8 && echo TAGGED || echo MISSING
podman inspect --format '{{index .Labels "org.opencontainers.image.version"}}' localhost/ansible-terraform:alpine-stable
```

Expected: `TAGGED`, then `13.0.0-1.15.8`.

- [x] **Step 5: Add the `clean` target**

Add `clean` to `.PHONY`, add a help line for it, and append:

```make
# Removes only the tags this repo applies. It does NOT reclaim the orphaned
# <none> base layers each version-tag-% build leaves behind -- podman rmi on a
# tag does not cascade to the image it was derived from. Run `podman image
# prune` periodically to clear those; this target deliberately does not, since a
# blanket prune would delete images this repo never built.
clean:
	@ids=$$($(PODMAN) images --format '{{.Repository}}:{{.Tag}}' \
	          | grep -E "^(localhost/)?$(IMAGE):" || true); \
	if [ -n "$$ids" ]; then $(PODMAN) rmi -f $$ids; else echo "nothing to clean"; fi
```

The help line, placed after the `test` line:

```make
	@echo "  clean                 Remove all tagged images built by this repo"
```

- [x] **Step 6: Verify the full cycle**

Run:

```bash
make clean
make test
podman images --format '{{.Repository}}:{{.Tag}}' | grep ansible-terraform | sort
```

Expected: eight tags — four `<os>-<channel>` and four `<os>-<av>-<tv>`. Then `make clean` again, followed by the same `podman images` command, should print nothing.

- [x] **Step 7: Commit**

```bash
git add Makefile
git commit -m "Tag images with both versions, and add clean

Both the Ansible bundle version and the Terraform version go in the tag
because either can move independently -- a rebuild picking up a newer
Ansible with the same Terraform would otherwise silently reuse a tag.
Both are read out of the built image, never typed, so a tag cannot drift
from what is installed."
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md` (currently two lines — replace wholesale)
- Modify: `CLAUDE.md` (replace the Status and Maintaining sections, which describe a stub)

**Interfaces:**
- Consumes: the variant list, tag scheme and `make` targets from Tasks 1–3.
- Produces: nothing other tasks depend on. This is the last task.

- [x] **Step 1: Gather the real numbers**

Do not type versions from memory. Run:

```bash
make build
for v in alpine-stable alpine-development ubuntu-stable ubuntu-development; do
  printf '%-22s ' "$v"
  podman run --rm localhost/ansible-terraform:$v sh -c \
    'ansible-community --version | tr "\n" " "; terraform version | head -1'
done
```

Use exactly what this prints in the README table.

- [x] **Step 2: Write `README.md`**

Structure it as both upstream repos do. It must contain:

- A one-line description, then a usage section with aliases:

  ```
  alias terraform='podman run -ti --rm -v "$PWD":/apps -w /apps localhost/ansible-terraform:alpine-stable terraform'
  alias ansible-playbook='podman run -ti --rm -v ~/.ssh:/root/.ssh:ro -v "$PWD":/apps -w /apps localhost/ansible-terraform:alpine-stable ansible-playbook'
  ```

  with both caveats copied from container-ansible's README: the alias body is single-quoted and uses `"$PWD"` so the mount resolves per invocation (a double-quoted body substitutes `$(pwd)` once, at definition time, and silently mounts that one directory forever); and on an SELinux-enforcing host, mounting a real `~/.ssh` needs `--security-opt label=disable` rather than a `:z`/`:Z` suffix, since relabeling `~/.ssh` would alter the SELinux context of the actual keys.

- A variant table with the columns: Tag, Ansible base, Terraform source, Ansible bundle, Terraform version — filled from Step 1.

- A **Capability differences** section: the Alpine variants have no WinRM, Kerberos or SELinux support and the Ubuntu variants do, inherited from the Ansible base. Point at container-ansible for the detail.

- A **Building locally** section stating: requires Podman and GNU Make; both bases pull from Docker Hub so neither upstream needs a local build; `make build`, `make test`, `make build-<variant>`, `make clean`; and that a plain rebuild reuses cached layers and will not see republished upstreams, so `make build PODMAN_BUILD_FLAGS="--pull"` is the refresh. Note that `make clean` cannot cascade-delete the orphaned `<none>` layers each version-tag build leaves, and `podman image prune` clears those.

- A **Tags** section: two tags per variant, `<os>-<channel>` (stable across rebuilds, use this in scripts) and `<os>-<ansible>-<terraform>` (derived at build time by reading both versions out of the image). State that these images are **not published to any registry**, unlike both upstreams.

- A **License** section making the GPL "or later" election explicit, since `LICENSE` holds the bare GPLv3 text which does not state it. Then, in plain language: these images contain Terraform under **BUSL-1.1** (licensor IBM), which is not an open-source license. Redistribution is permitted; production use is permitted *provided* it does not include offering Terraform to third parties on a hosted or embedded basis in order to compete with IBM's paid versions; each version converts to MPL-2.0 four years after publication. State that this is why the images are labeled `GPL-3.0-or-later AND BUSL-1.1` rather than upstream's bare GPL.

- A **Planned** section listing what is deliberately absent: publishing to a registry, CI, aligning the tag scheme with the upstreams' (they have 15 and 7 tags respectively, including `latest`), multi-arch manifests, and digest-pinning the upstream bases.

- [x] **Step 3: Update `CLAUDE.md`**

Replace the `## Status` section — which says the repo is a stub with no Containerfile, build script or test suite — with a description of what now exists: four Containerfiles composing published upstream images, a Makefile, and a smoke test.

Replace the `## Maintaining this file` section with the real commands:

- Build: `make build` (all four) or `make build-<variant>`; `make test` smoke-tests, `make clean` removes this repo's tags.
- Versions are not pinned in this repo. The Ansible channel comes from the `docker.io/pdutton/ansible:<variant>` tag and the Terraform channel from `docker.io/pdutton/terraform:<channel>`; both are selected by the `FROM` lines and resolved upstream.
- Add a warning that a plain rebuild will not pick up republished upstreams — `PODMAN_BUILD_FLAGS="--pull"` is required.
- Add a note that version, channel and prerelease assertions belong in container-terraform, not here, and must not be added to `test/smoke.yml`.

- [x] **Step 4: Verify the documented commands actually work**

Run every command the README's "Building locally" section names:

```bash
make clean && make build && make test && make clean
make help
```

Expected: all succeed; `make help` lists `build`, `test`, `clean` and the eight per-variant targets. Then verify one alias end to end:

```bash
podman run --rm -v "$PWD":/apps -w /apps localhost/ansible-terraform:alpine-stable terraform version
```

Expected: prints a Terraform version. (Run `make build` first if the preceding `make clean` removed the image.)

- [x] **Step 5: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "Document the composed images, tags, and licensing

Records why the images carry GPL-3.0-or-later AND BUSL-1.1 rather than
upstream's bare GPL: Terraform 1.6+ is BUSL, so a scanner reading the
GPL label alone would wrongly conclude the image is freely usable."
```

---

## Self-Review

**Spec coverage.** Walked each spec section against the tasks:

| Spec section | Task |
|---|---|
| Variant matrix, both bases from Docker Hub | 1, 2 |
| Containerfile shape, named stage, no build args, no ENTRYPOINT | 1, 2 |
| Labels including `base.name` naming Ansible only | 1, 2 |
| Repository layout (all 10 files) | 1–4 |
| Makefile shape, `LOCAL_IMAGE`, `PODMAN_BUILD_FLAGS` | 1, 3 |
| No preflight check | not implemented, as specified |
| Version tagging, both versions, read never typed | 3 |
| Clean | 3 |
| Testing: `terraform_data` config, module-driven playbook | 1 |
| No version/channel assertions | enforced in Global Constraints; Task 2 Step 7 does it as a one-off manual check instead |
| Licensing label and README section | 1, 2, 4 |
| README structure | 4 |
| Error handling | covered by `set -eu` and the version guards in Task 3 |
| Out of scope: no push, no CI, no latest | Global Constraints |

No gaps found.

**Placeholder scan.** No TBD/TODO, no "add appropriate error handling", no "similar to Task N" — Containerfiles are repeated in full in Tasks 1 and 2 precisely because a reader may take them out of order. Task 4 describes README *content requirements* rather than supplying finished prose, deliberately: Step 1 forces the versions to be read from the built images rather than transcribed from this plan, where they would already be stale.

**Type consistency.** Checked the names that cross task boundaries: `IMAGE`, `LOCAL_IMAGE`, `VARIANTS`, `PODMAN_BUILD_FLAGS`, `BUILD_DATE`, `GIT_REV`, `AWK`, `PODMAN` are spelled identically in Tasks 1 and 3. The `build-%`, `test-%`, `version-tag-%` rule names match their invocations. The smoke test's `/apps/terraform/main.tf` path matches the `-v ./test:/apps:ro,z` mount, and the asserted string `ok-from-terraform` matches the `main.tf` output expression. Tag format `<os>-<av>-<tv>` is consistent between Task 3's recipe, its verification step, and Task 4's README section.

**Verified before planning.** Both corner variants were built and smoke-tested for real against the published images on 2026-08-09: `ubuntu-development` (Terraform 1.16.0-beta2, Ansible 14.2.0) and `alpine-stable` (Terraform 1.15.8, Ansible 13.0.0). Both passed. The `file: state=directory` task in Task 1 Step 1 exists because its absence was an observed failure, not a guess.
