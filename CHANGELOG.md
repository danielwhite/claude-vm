# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1-alpha] - 2026-05-22

### Added

- `claude-vm list` shows projects with a pending restore (post-rebase, before relaunch) as `[pending restore]`. Previously these projects were invisible until their first `launch` recreated a snapshot.

### Fixed

- `claude-vm rebase` cleans `.ports` sidecars and orphan `.project` sidecars during its destruction phase. `.project` sidecars for projects with a backup are preserved so `list` can surface pending restores; orphans (no backup, no qcow2) accumulated in `~/.claude-vm/snapshots/` indefinitely before and are now swept.
- `claude-vm list` skips 0-byte `.qcow2` placeholders. Interrupted snapshot creation (SIGINT/SIGTERM during `qemu-img create`) could leave an empty file behind that surfaced as a confusing `(unknown) … [stopped]` row.
- `create_project_snapshot` traps `INT`/`TERM` and removes the partial `.qcow2` (and the sidecar it would have written) before exiting. Closes the upstream of the 0-byte qcow2 files that the `list` filter now hides.

## [0.1.0-alpha] - 2026-05-20

### Added

- `claude-vm rebase` command: refreshes the shared base image (Claude Code, OS packages, kernel) while preserving each project VM's persistent state by extracting `~/.claude/`, `~/.claude.json`, `~/.gitconfig`, and `~/.config/gh/` to a per-project backup directory, rebuilding the base from upstream, and lazy-restoring the extracted state on the project's next launch.

[Unreleased]: https://github.com/shudza/claude-vm/compare/v0.1.1-alpha...HEAD
[0.1.1-alpha]: https://github.com/shudza/claude-vm/compare/v0.1.0-alpha...v0.1.1-alpha
[0.1.0-alpha]: https://github.com/shudza/claude-vm/releases/tag/v0.1.0-alpha
