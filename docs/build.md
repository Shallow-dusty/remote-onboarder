# Windows one-click onboarding package

This is a personal, Windows x64-only, console installer for onboarding one
remote machine without the Wails UI. The distributable is a single IExpress
self-extracting executable; the recipient does not open a zip or locate a
PowerShell file.

## Recipient flow

1. Double-click `SSH-Launchpad-OneClick-Windows-x64.exe`.
2. Accept the UAC prompt.
3. Keep the progress window open until it prints the SSH command.
4. Send `SSH-连接信息.txt` from the desktop back to the controller.

The installer probes actual machine state on every run: existing supported
OpenSSH/Tailscale installations are reused, keys are deduplicated, and the
managed sshd block is replaced. Re-running is not unconditional recovery:
pending installer/recovery markers block another run until an operator verifies
the previous outcome. Do not delete markers just to bypass the guard.

## Embedded payloads

| Payload | Version | SHA-256 |
|---|---:|---|
| Microsoft Win32-OpenSSH x64 MSI | 10.0.0.0p2-Preview | `ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9` |
| Tailscale amd64 MSI | 1.102.3 | `03ac8183c6e3ce276e9b44281ebe7e4c02aef28a971034ca170c4b665df42dce` |

Both payloads must match hard-coded SHA-256 pins and the expected vendor's
valid Authenticode signature during packaging. The same hashes are checked
again on the target before installation; hashes are not derived from whatever
bytes happened to download. Initial URLs and redirects must remain HTTPS. OpenSSH is installed with the
`Client,Server` MSI features; Tailscale is installed with incoming connections
enabled.

Official references:

- <https://github.com/PowerShell/Win32-OpenSSH/releases>
- <https://learn.microsoft.com/en-us/troubleshoot/windows-server/system-management-components/upgrade-in-box-openssh-to-latest-openssh-release>
- <https://tailscale.com/docs/install/windows/msi>
- <https://pkgs.tailscale.com/stable/>

## Build

The private build input is intentionally under the ignored `build/` tree:

```json
{
  "tailscaleAuthKey": "tskey-auth-...",
  "publicKey": "ssh-ed25519 AAAA... controller",
  "expectedTailnet": "your-tailnet.ts.net",
  "logEndpoints": [
    "https://your-log-receiver.example.com/ssh-launchpad-log/events"
  ]
}
```

Create it at `build/oneclick/private-config.json` with mode `0600`, then run
from WSL:

```bash
./scripts/build-oneclick-windows.sh
# Parse, check pinned payloads/signatures and self-test, without making an EXE:
./scripts/build-oneclick-windows.sh build/oneclick/private-config.json --validate-only
```

The builder downloads missing pinned payloads using a partial file, validates
and safely quotes private input through `scripts/render-setup.py`, parses the
generated script with PowerShell 5.1, validates hashes/vendor signatures, and
runs the non-mutating self-test. Self-test forces logging off and deletes its
unique temporary fixture directory. Normal packaging then builds IExpress,
extracts without execution, compares every embedded file (including
`safety.ps1`), and copies the result to Desktop. The unique credential-bearing
Windows staging directory is removed on exit. The distributed EXE itself is
still plaintext-extractable and must be treated as a credential.

Inputs remain the same four fields in `config.example.json`. `logEndpoints`
accepts up to three HTTPS `/events` URLs without embedded credentials, queries,
fragments, or redirects. Existing HTTP configurations require migration before
building; this change does not alter any live endpoint or private config.

## Runtime steps

1. Require local execution, elevation, a shared system mutation mutex, a
   protected non-linked state directory, no unresolved prior run, Windows x64,
   target profile, free space, payload hashes, and supported SSH/firewall policy.
2. Install/reuse Tailscale.
3. Reuse the expected running Tailnet; only a confirmed NeedsLogin/NoState
   client may authenticate. Never force-reauth/reset an existing different or
   uncertain network. Remote SSH invocation is rejected before elevation too.
4. Install/reuse OpenSSH. Missing binary repair is limited to known MSI paths
   using MSI repair properties; do not delete a service first or convert an
   unknown/capability installation. MSI work is inherently not transactional.
5. Save configuration/key bytes and ACLs, sshd running/start mode, and changed
   firewall rule names before configuration work; persist recovery intent.
   Disable only known local broad OpenSSH TCP-22 rules, retain an already-valid
   managed rule, or add a new Tailnet-IPv4-only rule. Require enabled profiles
   with default inbound block and complete applicable allow-rule inventory.
6. Generate missing host keys, merge the controller public key, apply key ACLs,
   replace managed settings and old top-level Ports, validate configuration,
   then start sshd. Only the exact Windows stock administrator Match block is
   supported; Include/custom Match/ListenAddress require manual review.
7. Verify local service/listener/key/effective SSH policy, complete relevant
   firewall policy, and Tailnet identity/IP. Copy connection details; explicitly
   ask the controller to try a real connection. Local checks are not end-to-end
   reachability or authentication evidence.

On an ordinary configuration failure, attempt restoration of the captured
files/ACLs, firewall rules and service state. An interrupted or failed recovery
leaves `recovery-pending.txt` pointing to the protected CLIXML snapshot. An
unconfirmed MSI action leaves `installer-pending.txt`; an interrupted login or
native timeout leaves `native-pending.txt`. An operator must inspect
these and the real state before deciding recovery; no generic blind replay or
one-click manual rollback UI is added. Native timeouts may leave child/service
work in flight, so they never initiate concurrent automatic recovery. MSI codes
1641/3010 are followed by effective-state checks. Installed packages, host keys
and Tailnet authentication are not undone by configuration recovery.

## Logs and results

Local artifacts:

```text
C:\ProgramData\SSHLaunchpad\logs\<session>.log
C:\ProgramData\SSHLaunchpad\logs\<session>.jsonl
C:\ProgramData\SSHLaunchpad\logs\<session>-openssh-msi.log
C:\ProgramData\SSHLaunchpad\logs\<session>-tailscale-msi.log
C:\ProgramData\SSHLaunchpad\backups\sshd_config-<session>.bak
C:\ProgramData\SSHLaunchpad\backups\<session>.recovery.clixml
C:\ProgramData\SSHLaunchpad\recovery-pending.txt (only while unresolved)
C:\ProgramData\SSHLaunchpad\installer-pending.txt (only while unresolved)
C:\ProgramData\SSHLaunchpad\native-pending.txt (only while unresolved)
Desktop\SSH-安装日志.log
Desktop\SSH-连接信息.txt
```

Every event is uploaded immediately to the endpoints configured in
`logEndpoints`. If no endpoint is configured, remote logging is skipped; if all
currently configured endpoints are unavailable, events are queued locally and
retried with bounded synchronous timeouts and backoff; network latency can delay
steps, but upload failure does not fail the installation. There is no persistent
background queue worker after the process exits. Auth-key-shaped strings and
the exact injected key are redacted before writing events.

Endpoint ordering is operator-defined; no provider is assumed. The dashboard
refreshes every two seconds without overlapping requests, pauses when hidden,
and supports search, explicit refresh, pause/resume, and optional tail-follow.
Errors retain prior content with a visible stale-data notice. All displayed
records are inserted as text, not assembled HTML.

## Log receiver

Source: `log-receiver/`

Example deployment on any Linux host with Docker:

```text
/opt/ssh-launchpad-log/
container: ssh-launchpad-log
reverse-proxy route: /ssh-launchpad-log/* -> container
persisted data: /opt/ssh-launchpad-log/data/*.jsonl
```

Build and run the container from `log-receiver/` (multi-stage build, no
manually prepared binary):

```bash
cd log-receiver
docker build -t log-receiver:local .
docker run -d --name log-receiver -p 127.0.0.1:8080:8080 -v "$PWD/data:/data" log-receiver:local
curl -fsS http://127.0.0.1:8080/healthz
```

The receiver is a statically linked Go service with bounded request bodies,
strict event decoding, append-and-sync persistence, health/session endpoints,
and a small live browser view. Back up your reverse-proxy configuration before
adding the route.

The standalone listener defaults to loopback. Docker explicitly listens inside
its private network; do not publish the port directly. There is no application
login/multi-tenant system: protect ingestion and dashboard access with private
network routing or suitable authenticated reverse-proxy policy. HTTPS alone is
not authorization. No live deployment or proxy was changed in this audit.

Limits: 64 KiB per event, 16 MiB per session, 1,000 sessions and 256 MiB total
JSONL storage. Full storage returns HTTP 507 without deleting history. Archive
records operationally before retrying; the application does not auto-delete.
Cached identity responses and framing are disabled; linked/non-regular log
files are rejected. The data directory must remain writable only by the
trusted service operator.

## Safe developer checks

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_render_setup.py
shellcheck scripts/build-oneclick-windows.sh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$PWD/scripts/test-safety.ps1")"
(cd log-receiver && go test -race ./... && go vet ./...)
# Optional: reuse an existing Playwright installation, without new runtime deps.
node scripts/test-dashboard.mjs /absolute/path/to/playwright-project/package.json
```

The same checks run on every push in `.github/workflows/ci.yml` (receiver
tests plus a container smoke test, renderer and ShellCheck, the browser
dashboard checks, PowerShell 5.1 parsing and the safety fixtures, govulncheck
and a secret scan). Building the single-EXE and the `--validate-only` run still
happen locally because they need a private config and pinned payloads.

Use a synthetic 0600 build config and existing pinned payloads for
`--validate-only`. Do not run `setup.ps1` without `-SelfTest` on a development
machine. Snapshot recovery tests mock every service/firewall command and only
change files inside unique temporary fixture directories.
