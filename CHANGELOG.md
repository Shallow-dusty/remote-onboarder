# Changelog

## Unreleased — 2026-09-13

This does not change the embedded 1.0.0 version or publish a new installer.

### Security and reliability

- Validate build inputs and escape PowerShell literals through a pure renderer;
  pin official payload hashes and check expected signing organizations.
- Require HTTPS for payload transfers and log URLs; remove unique sensitive
  staging on exit. Add `--validate-only` without EXE/Desktop output.
- Inspect supported SSH and effective Windows Firewall policy, reject unknown
  cases, remove extra top-level Ports, and preserve valid managed rules.
- Share the mutation mutex with SSH Launchpad; persist recovery snapshots and
  unresolved-operation markers. Attempt reversible configuration recovery only
  when native work is not known to be uncertain.
- Repair known MSI installations without first deleting sshd; reject forced
  Tailnet switching and SSH-carried invocation.
- Redact auth-key text; disable remote logging in SelfTest and skip empty queues.
- Bound log storage, reject linked files, disable caching/framing and default
  the standalone receiver to loopback. External access control remains required.

### Interaction

- Keep the seven-step console and single-file recipient experience; clarify
  irreversible changes, failure handling and controller-side connection checks.
- Retain the Go/HTML log page while adding search, selection, pause, tail-follow,
  non-overlapping refresh, visibility handling and errors that preserve content.

### Verification

Renderer tests, ShellCheck, Windows PowerShell fixtures and generated SelfTest,
Go race/vet/build and browser mock checks passed. No live installation, new
IExpress distribution, online deployment or real-target recovery was performed.
See `STATUS.md` and `docs/audit-2026-09.md` for limitations and migration notes.
