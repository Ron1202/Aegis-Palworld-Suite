# Contributing

## Before Submitting an Issue

Include:

- Aegis version
- Windows version
- PowerShell version
- Relevant logs
- Reproduction steps
- Screenshots when useful

## Pull Requests

1. Create a feature branch.
2. Keep changes focused.
3. Test with Windows PowerShell 5.1 when applicable.
4. Update user-facing documentation.
5. Add an entry under `Unreleased` in `CHANGELOG.md`.
6. Never commit credentials, webhooks, server addresses, or private data.

## Coding Guidelines

- Use clear PowerShell function names.
- Prefer explicit error handling.
- Resolve paths relative to the Suite root.
- Preserve WPF and JSON compatibility.
- Document database schema changes.
