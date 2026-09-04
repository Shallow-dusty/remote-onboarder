# Remote-Onboarder working agreement

One-click Windows x64 onboarding tool: it modifies sshd configuration, Windows
Firewall rules, and authorized_keys on real machines, so the rules below are
product safety contracts, not process theater.

## Safety contracts

- Never commit private keys, Tailscale auth keys, or any real device details.
  All secrets live in `build/oneclick/private-config.json` (0600, git-ignored);
  the repository carries only `config.example.json` placeholders.
- `setup.ps1 -SelfTest` must stay non-mutating: it exercises transforms and
  hashing against throwaway state under `%TEMP%`, never the live sshd config.
- SSH exposure is public-key only and firewall-scoped to the Tailscale range
  (`100.64.0.0/10`); never weaken these defaults.
- A change that could cut an operator's active SSH/Tailscale path needs a
  rollback story (config backups, restore-on-failure) before it ships.

## Development

- Keep platform commands in `payload/*.ps1` templates; the build script owns
  secret injection via `__*_MARKER__` placeholders. New build inputs must be
  documented in `README.md`, `docs/build.md`, and `config.example.json` at the
  same time — those three documents must never drift apart.
- After changing planner output, Apply, rollback, firewall scoping, or the
  repair logic, rerun the build (it parses the generated PowerShell 5.1 and
  runs the self-test) and update the docs in the same commit.
- Generated artifacts go under `build/`; never commit them.
