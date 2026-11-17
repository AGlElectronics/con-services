# Changelog

All notable changes to Stats are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Compatible with Den MAJOR 1.

### Changed

- Dashboard shell redesign: Con Services–led composition, Syne/Fraunces
  typography, dark-only atmosphere, and source rows that read as a snapshot
  board rather than generic tiles.
- Local Compose default `STATS_SOURCES` now polls all eight modules
  (`hr`, `events`, `tasks`, `desk`, `wiki`, `stash`, `learn`, `finance`).

### Added

- Local stack wiring so Den can list Stats: `stats.conservices.test` on the
  Caddy proxy, Compose `APP_BASE_URL`, and `DEN_PREREGISTER_MODULES` entry
  (scaffold still uses `AUTH_MODE=dev` without denlink).
- Development scaffold with a Go polling backend, static aggregate dashboard,
  migration placeholder, Docker images and local Compose profile.
- Version 1 internal module metrics pull contract with configurable one-to-five
  minute polling, bounded requests and last-successful in-memory snapshots.
- Explicit 1.1 scope boundaries: no infrastructure metrics, person-level data
  or public signage consumers.
