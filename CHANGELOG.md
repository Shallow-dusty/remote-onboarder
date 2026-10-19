# Changelog

## 1.2.1 — 2026-10-20

### Fixed

- Chinese usernames in `SSH-连接信息.txt`: stop emitting `ssh -l "尚明阳"`, which
  OpenSSH rejects with `remote username contains invalid characters`. ASCII
  usernames keep the one-line command; non-ASCII usernames now emit an
  `~/.ssh/config` Host block, with the controller adding `IdentityFile`.
- Added regression assertions for both paths.

### Verification

PowerShell 7.6/macOS parsed `setup.ps1` and passed 49 resilience assertions.
Windows PowerShell 5.1 parsing, SelfTest and a rebuilt package are still pending.

## 1.2.0 — 2026-10-10

### Added

- Tailnet-only HTTPS log receiver, full artifact upload with byte and SHA-256
  receipts, and optional private DNS mapping for `--resolve`.
- Migration compatibility mode, parallel read-only diagnostics, bounded MSI 1618
  retries, partial-result reporting and a desktop feedback ZIP.

### Verified

- Real Windows 11 Chinese account (`LAPTOP-RNN171NI`): 7/7 steps, Tailscale
  enrollment, SSH public-key login and cloud event logs.
- Synthetic artifact uploads with hash readback; Python 11 tests, Windows 42
  assertions, Go race/vet and browser checks.

### Not verified

- Isolated Windows VM clean install, UAC, power-loss recovery, other Chinese
  accounts. No persistent background upload retry.

## 1.1.0 — 2026-10-10

### Added

- Migration compatibility mode, parallel read-only diagnostics, bounded MSI
  retries, explicit partial results, portable ZIP/update builder.

### Verified

Python 10 tests, Windows 42 resilience assertions and on-host read-only
diagnostics. No live installation acceptance at that time.

## 1.0.0 audit — 2026-09-13

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
