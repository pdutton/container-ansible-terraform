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
