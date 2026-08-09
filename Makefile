IMAGE       ?= ansible-terraform
VARIANTS    := alpine-stable alpine-development ubuntu-stable ubuntu-development

# Every local image reference goes through this, never a bare $(IMAGE): an
# unqualified name can resolve by an implicit registry tie-break, which is not
# something the highest-stakes lines in this file should depend on.
LOCAL_IMAGE  = localhost/$(IMAGE)

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
# Five guards, in order, all before any tag is applied:
#  1. The variant stem is exactly two '-'-separated words. os/channel come from
#     word 1/2 of $* and silently discard anything past word 2, so a future
#     variant such as ubuntu-stable-slim would compute os=ubuntu,
#     channel=stable and claim ubuntu-stable's tags -- overwriting them in the
#     public registry. Checked by reassembling and comparing to $*, not by a
#     case/glob: a shell `*` matches '-' too, so no bracket-class pattern can
#     exclude extra segments.
#  2. $version is non-empty. push-% reads it from a label that could simply be
#     absent; without this guard an empty $version falls through to guard 3
#     and is reported as "contains no '-'", which names the wrong problem --
#     there is no version at all, not a one-axis one.
#  3. $version contains a '-' at all. $${version\#*-} returns the string
#     UNCHANGED when it contains none, so a one-axis version like 13.0.0 would
#     set av=tv=13.0.0, pass guard 4 twice, and publish alpine-13.0.0 -- a tag
#     shaped like a version tag that names only one of the two axes.
#  4. Both halves are X.Y.Z. Checked separately: because a glob `*` matches
#     '-', that same pattern applied to the composite matches 13.0.0 alone.
#     Splitting on the FIRST '-' is safe in both directions -- an Ansible
#     bundle version is always X.Y.Z and never contains a '-', so a Terraform
#     -beta/-rc suffix can only ever land in tv.
#  5. The messages name the image and say "derive the tag set" rather than
#     "tag", because this now fires from push-% too, where nothing is tagged
#     and $version came from a label rather than from two containers.
TAG_SET_SH = os="$(word 1,$(subst -, ,$*))"; \
             channel="$(word 2,$(subst -, ,$*))"; \
             if [ -z "$$os" ] || [ -z "$$channel" ] || [ "$$os-$$channel" != "$*" ]; then \
               echo "ERROR: $(LOCAL_IMAGE):$*: variant stem is not exactly two non-empty '-'-separated words (<os>-<channel>); refusing to derive the tag set, since word 1/word 2 would silently drop the rest and could overwrite another variant's tags" >&2; \
               exit 1; \
             fi; \
             if [ -z "$$version" ]; then \
               echo "ERROR: $(LOCAL_IMAGE):$*: carries no usable org.opencontainers.image.version label; refusing to derive the tag set" >&2; \
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

.DEFAULT_GOAL := help
.PHONY: help build test push clean

help:
	@echo "Targets:"
	@echo "  build                 Build all variants"
	@echo "  test                  Smoke-test all variants"
	@echo "  push                  Push all variants to $(REGISTRY)/$(IMAGE)"
	@echo "  clean                 Remove all tagged images built by this repo"
	@$(foreach v,$(VARIANTS),echo "  build-$(v)"; echo "  test-$(v)"; echo "  push-$(v)";)
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
	@$(MAKE) --no-print-directory tag-$*

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

test-%: build-%
	$(PODMAN) run --rm -v ./test:/apps:ro,z $(LOCAL_IMAGE):$* \
	  ansible-playbook -i localhost, -c local smoke.yml

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

# Removes only the tags this repo applies. It does NOT reclaim the orphaned
# <none> base layers each tag-% build leaves behind -- podman rmi on a
# tag does not cascade to the image it was derived from. Run `podman image
# prune` periodically to clear those; this target deliberately does not, since a
# blanket prune would delete images this repo never built.
clean:
	@ids=$$($(PODMAN) images --format '{{.Repository}}:{{.Tag}}' \
	          | grep -E "^(localhost/)?$(IMAGE):" || true); \
	if [ -n "$$ids" ]; then $(PODMAN) rmi -f $$ids; else echo "nothing to clean"; fi
