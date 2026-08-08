# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

This repository is a stub: the only tracked files are `README.md` and `LICENSE`
(GPL-3.0). There is no Containerfile/Dockerfile, build script, CI config, or test
suite yet.

Intended purpose, per `README.md`: a container image bundling Ansible and
Terraform.

## Maintaining this file

Because nothing has been built yet, this file deliberately documents no build,
lint, or test commands — inventing them would mislead. Once the image definition
and any build/CI tooling land, replace this section with:

- the actual build command (e.g. `podman build` / `docker build` invocation,
  including any required `--build-arg`s and the image tag convention)
- how the image's tool versions (Ansible, Terraform) are pinned and bumped
- how to run/verify the image locally, and how to run a single test if a test
  harness exists
