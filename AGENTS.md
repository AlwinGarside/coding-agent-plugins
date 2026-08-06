# Repository Guidelines

## Project Structure & Module Organization

This repository publishes coding-agent plugins. Plugin code lives under `plugins/`; currently, `plugins/github-utils/` contains the Codex and Claude manifests plus one directory per skill. Each skill keeps its instructions in `SKILL.md`, executable helpers in `scripts/`, and agent metadata in `agents/`.

Marketplace catalogs are stored in `.agents/plugins/marketplace.json` and `.claude-plugin/marketplace.json`. Shared agent guidance belongs in `docs/agents/`, while investigation notes belong in `docs/research/`. JSON schema support is kept in `.schemas/`.

## Build, Test, and Development Commands

There is no compiled build or package-manager workflow. Validate the files you change directly.

## Coding Style & Naming Conventions

Follow the Google Shell Style Guidelines.

## Testing Guidelines

No automated test framework or coverage threshold is configured. Every shell change should pass `bash -n` and ShellCheck. Exercise altered exit paths and GitHub API responses manually, including failure and timeout cases. Validate manifests after every metadata or version change.

## Commit & Pull Request Guidelines

Use Conventional Commit prefixes.

## Release & Security Notes

Keep the Codex and Claude plugin versions synchronized.

## Agent skills

### Issue tracker

Issues are tracked with GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

The repository uses the five default triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

The repository uses a single-context domain layout. See `docs/agents/domain.md`.
