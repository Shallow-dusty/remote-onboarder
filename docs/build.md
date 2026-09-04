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

The installer probes actual machine state on every run, so retrying is safe:
existing OpenSSH/Tailscale installations are reused, the SSH key is deduplicated,
the managed sshd block is replaced rather than appended, and the firewall rule
is refreshed.

## Embedded payloads

| Payload | Version | SHA-256 |
|---|---:|---|
| Microsoft Win32-OpenSSH x64 MSI | 10.0.0.0p2-Preview | `ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9` |
| Tailscale amd64 MSI | 1.102.3 | `03ac8183c6e3ce276e9b44281ebe7e4c02aef28a971034ca170c4b665df42dce` |

Both payloads are Authenticode-validated during packaging and SHA-256 checked
again on the target before installation. OpenSSH is installed with the
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
  "publicKey": "ssh-ed25519 AAAA... controller"
}
```

Create it at `build/oneclick/private-config.json` with mode `0600`, then run
from WSL:

```bash
./scripts/build-oneclick-windows.sh
```

The builder downloads missing pinned payloads, injects the private build input,
parses the generated script with Windows PowerShell 5.1, validates both vendor
signatures, executes the non-mutating self-test, verifies that its structured
logs reached the remote receiver, builds the IExpress SFX, extracts the SFX
without executing it, compares every embedded file, and places the result on
the Windows desktop.

## Runtime steps

1. Preflight Windows x64, target profile, at least 500 MiB free on the system
   drive, payload presence, and payload hashes.
2. Install/reuse Microsoft Win32-OpenSSH.
3. generate missing host keys, merge the controller public key into both user
   and administrators key files, apply SID-based ACLs, disable SSH password and
   keyboard-interactive authentication, validate `sshd_config` with `sshd -t`,
   and start `sshd`.
4. Recreate the TCP 22 Windows Firewall rule with remote addresses restricted
   to the Tailscale IPv4 range `100.64.0.0/10`.
5. Install/reuse Tailscale.
6. Reuse an already-running session only when it belongs to
   `tailnet.example.ts.net`; otherwise force reauthentication with the embedded
   one-time key.
7. Verify sshd, TCP 22, key presence, the expected Tailnet identity, Tailscale
   state, and Tailscale IPv4.

If config validation or sshd restart fails, the script restores the pre-change
`sshd_config` backup. Native processes have explicit timeouts. MSI return codes
`1641` and `3010` are accepted, followed by effective-state checks.

## Logs and results

Local artifacts:

```text
C:\ProgramData\SSHLaunchpad\logs\<session>.log
C:\ProgramData\SSHLaunchpad\logs\<session>.jsonl
C:\ProgramData\SSHLaunchpad\logs\<session>-openssh-msi.log
C:\ProgramData\SSHLaunchpad\logs\<session>-tailscale-msi.log
C:\ProgramData\SSHLaunchpad\backups\sshd_config-<session>.bak
Desktop\SSH-安装日志.log
Desktop\SSH-连接信息.txt
```

Every event is uploaded immediately. If both endpoints are unavailable, events
are queued locally and retried without blocking installation:

```text
http://203.0.113.10/ssh-launchpad-log/
https://log-receiver.example.com/ssh-launchpad-log/
```

The first URL is the direct Aliyun path; the second is the Cloudflare-backed
fallback. The dashboard refreshes session data every two seconds.

## Log receiver

Source: `log-receiver/`

Deployment on `Prism-Zero`:

```text
/opt/ssh-launchpad-log/
container: ssh-launchpad-log
network: pulse-tracker_default
Caddy route: /ssh-launchpad-log/*
data: /opt/ssh-launchpad-log/data/*.jsonl
```

The receiver is a statically linked Go service with bounded request bodies,
strict event decoding, append-and-sync persistence, health/session endpoints,
and a small live browser view. Caddy configuration was backed up before adding
the route.
