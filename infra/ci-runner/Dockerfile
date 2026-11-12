# syntax=docker/dockerfile:1.7
#
# Runner image for the self-hosted GitHub Actions runners (ARC scale set
# "arc-conservices"). The upstream runner image plus a C compiler, which
# `go test -race` needs, and envsubst (gettext-base), which
# sigstore/cosign-installer needs. Built and published by
# .github/workflows/ci-runner-image.yml as
# ghcr.io/aglelectronics/ci-runner:<RUNNER_VERSION>-<BUILD> (see VERSION).
# Docs: https://aglelectronics.github.io/con-services/contributing/ci/#where-it-runs
FROM ghcr.io/actions/actions-runner:2.338.2@sha256:759a1d94a15b05941aba5196974ff43fe15b4cbba29b694b35cbc32a1166b232

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev gettext-base \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*

# The runner runs JavaScript actions with externals/node*/bin/node only; the
# npm bundled with the Node 20 external is never used and carries an old
# node-tar (CVE-2026-59873).
RUN rm -rf /home/runner/externals/node20/lib/node_modules/npm \
    /home/runner/externals/node20/bin/npm /home/runner/externals/node20/bin/npx

USER runner
