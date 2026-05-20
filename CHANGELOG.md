# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0-alpha] - 2026-05-20

### Added

- `claude-vm rebase` command: refreshes the shared base image (Claude Code, OS packages, kernel) while preserving each project VM's persistent state by extracting `~/.claude/`, `~/.claude.json`, `~/.gitconfig`, and `~/.config/gh/` to a per-project backup directory, rebuilding the base from upstream, and lazy-restoring the extracted state on the project's next launch.

[0.1.0-alpha]: https://github.com/shudza/claude-vm/releases/tag/v0.1.0-alpha
