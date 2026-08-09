IMAGE       ?= ansible-terraform
VARIANTS    := alpine-stable alpine-development ubuntu-stable ubuntu-development

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
.PHONY: help build test clean

help:
	@echo "Targets:"
	@echo "  build                 Build all variants"
	@echo "  test                  Smoke-test all variants"
	@echo "  clean                 Remove all tagged images built by this repo"
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
	@$(MAKE) --no-print-directory version-tag-$*

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

test-%: build-%
	$(PODMAN) run --rm -v ./test:/apps:ro,z $(LOCAL_IMAGE):$* \
	  ansible-playbook -i localhost, -c local smoke.yml

# Removes only the tags this repo applies. It does NOT reclaim the orphaned
# <none> base layers each version-tag-% build leaves behind -- podman rmi on a
# tag does not cascade to the image it was derived from. Run `podman image
# prune` periodically to clear those; this target deliberately does not, since a
# blanket prune would delete images this repo never built.
clean:
	@ids=$$($(PODMAN) images --format '{{.Repository}}:{{.Tag}}' \
	          | grep -E "^(localhost/)?$(IMAGE):" || true); \
	if [ -n "$$ids" ]; then $(PODMAN) rmi -f $$ids; else echo "nothing to clean"; fi
