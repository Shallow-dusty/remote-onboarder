#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
umask 077
config=${1:-"$repo/build/oneclick/private-config.json"}
mode=${2:-package}
[[ "$mode" == package || "$mode" == --validate-only ]] || { printf 'expected --validate-only or package\n' >&2; exit 1; }
payload_dir="$repo/build/oneclick/payloads"
source_dir="$repo/payload"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null || fail 'jq is required'
command -v curl >/dev/null || fail 'curl is required'
command -v powershell.exe >/dev/null || fail 'Windows PowerShell is required (run from WSL)'
command -v iexpress.exe >/dev/null || fail 'Windows IExpress is required (run from WSL)'
[[ -f "$config" ]] || fail "private config not found: $config"

command -v python3 >/dev/null || fail 'python3 is required'
# Do not export credentials through the environment or print generated source.
[[ $(stat -c '%a' "$config") == 600 ]] || fail 'private config must have mode 0600'

mkdir -p "$payload_dir"
openssh_name='OpenSSH-Win64-v10.0.0.0.msi'
tailscale_name='tailscale-setup-1.102.3-amd64.msi'
openssh_url='https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64-v10.0.0.0.msi'
tailscale_url='https://pkgs.tailscale.com/stable/tailscale-setup-1.102.3-amd64.msi'

fetch() {
  local url=$1 output=$2
  if [[ ! -s "$output" ]]; then
    printf 'Downloading %s\n' "$(basename "$output")"
    curl -fL --proto '=https' --proto-redir '=https' --retry 4 --retry-delay 2 --continue-at - --output "$output.part" "$url"
    mv "$output.part" "$output"
  fi
}
fetch "$openssh_url" "$payload_dir/$openssh_name"
fetch "$tailscale_url" "$payload_dir/$tailscale_name"

openssh_sha='ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9'
tailscale_sha='03ac8183c6e3ce276e9b44281ebe7e4c02aef28a971034ca170c4b665df42dce'
printf '%s  %s\n%s  %s\n' "$openssh_sha" "$payload_dir/$openssh_name" "$tailscale_sha" "$payload_dir/$tailscale_name" | sha256sum -c - || fail 'pinned payload hash mismatch'

# shellcheck disable=SC2016 # $env:TEMP is intentionally evaluated by Windows PowerShell.
win_temp=$(powershell.exe -NoProfile -Command '$env:TEMP' | tr -d '\r' | tail -n1)
[[ "$win_temp" =~ ^[A-Za-z]:\\ ]] || fail "unexpected Windows TEMP: $win_temp"
stage_win="${win_temp}\\ssh-launchpad-oneclick-build-$(date +%s)-$$"
stage=$(wslpath -u "$stage_win")
output_win="${stage_win}\\SSH-Launchpad-OneClick-Windows-x64.exe"
output=$(wslpath -u "$output_win")
sed_win="${stage_win}\\package.sed"
sed_path="$stage/package.sed"

powershell.exe -NoProfile -Command "Remove-Item -LiteralPath '$stage_win' -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path '$stage_win' | Out-Null; Remove-Item -LiteralPath '$output_win' -Force -ErrorAction SilentlyContinue; exit 0"
mkdir -p "$stage"
cp "$source_dir/launcher.cmd" "$source_dir/bootstrap.ps1" "$source_dir/safety.ps1" "$stage/"
cp "$payload_dir/$openssh_name" "$payload_dir/$tailscale_name" "$stage/"

# Remove only this invocation's unique credential-bearing staging directory.
trap 'powershell.exe -NoProfile -Command "Remove-Item -LiteralPath '\''$stage_win'\'' -Recurse -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1' EXIT
python3 "$repo/scripts/render-setup.py" "$source_dir/setup.ps1" "$config" "$stage/setup.ps1" "$openssh_sha" "$tailscale_sha"

# Parse the exact generated PowerShell on Windows PowerShell 5.1.
powershell.exe -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$stage_win\\setup.ps1',[ref]\$null,[ref]\$e); if(\$e.Count){\$e | ForEach-Object { Write-Error (\$_.Extent.StartLineNumber.ToString()+': '+\$_.Message) }; exit 1}; 'PowerShell syntax: OK'"

# Require the official payload signatures before packaging.
powershell.exe -NoProfile -Command "\$files=@('$stage_win\\$openssh_name','$stage_win\\$tailscale_name'); foreach(\$f in \$files){\$s=Get-AuthenticodeSignature -LiteralPath \$f; Write-Host ((Split-Path \$f -Leaf)+': '+\$s.Status+' / '+\$s.SignerCertificate.Subject); \$vendor=if(\$f -like '*OpenSSH*'){'Microsoft Corporation'}else{'Tailscale Inc.'}; if(\$s.Status -ne 'Valid' -or \$s.SignerCertificate.Subject -notlike ('*O='+\$vendor+',*')){exit 1}}"

# Safe self-test: hashes, temporary config/key transforms and process wrapper.
# It never uploads device identities or touches live SSH/firewall services.
set +e
selftest_output=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$stage_win\\setup.ps1" -SelfTest -NoPause 2>&1)
selftest_code=$?
set -e
printf '%s\n' "$selftest_output"
[[ $selftest_code -eq 0 ]] || fail "generated setup self-test failed ($selftest_code)"
session=$(printf '%s\n' "$selftest_output" | tr -d '\r' | grep -oE 'SELFTEST_SESSION=[A-Za-z0-9._-]+' | tail -n1 | cut -d= -f2)
[[ -n "$session" ]] || fail 'self-test session id missing'
printf 'Self-test passed (remote logging disabled).\n'
if [[ "$mode" == --validate-only ]]; then
  printf 'Validation complete; no EXE packaged or copied to Desktop.\n'
  exit 0
fi

TARGET_NAME="$output_win" STAGE_WIN="$stage_win" SED_PATH="$sed_path" python3 - <<'PY'
from pathlib import Path
import os
stage = os.environ['STAGE_WIN']
target = os.environ['TARGET_NAME']
files = ['launcher.cmd', 'bootstrap.ps1', 'safety.ps1', 'setup.ps1', 'OpenSSH-Win64-v10.0.0.0.msi', 'tailscale-setup-1.102.3-amd64.msi']
strings = [
    '[Version]', 'Class=IEXPRESS', 'SEDVersion=3', '',
    '[Options]', 'PackagePurpose=InstallApp', 'ShowInstallProgramWindow=1',
    'HideExtractAnimation=1', 'UseLongFileName=1', 'InsideCompressed=0',
    'CAB_FixedSize=0', 'CAB_ResvCodeSigning=0', 'RebootMode=N',
    'InstallPrompt=%InstallPrompt%', 'DisplayLicense=%DisplayLicense%',
    'FinishMessage=%FinishMessage%', 'TargetName=%TargetName%',
    'FriendlyName=%FriendlyName%', 'AppLaunched=%AppLaunched%',
    'PostInstallCmd=%PostInstallCmd%', 'AdminQuietInstCmd=%AdminQuietInstCmd%',
    'UserQuietInstCmd=%UserQuietInstCmd%', 'SourceFiles=SourceFiles', '',
    '[Strings]', 'InstallPrompt=""', 'DisplayLicense=""', 'FinishMessage=""',
    f'TargetName="{target}"', 'FriendlyName="SSH + Tailscale OneClick"',
    'AppLaunched="launcher.cmd"', 'PostInstallCmd="<None>"',
    'AdminQuietInstCmd=""', 'UserQuietInstCmd=""',
]
for i, filename in enumerate(files):
    strings.append(f'FILE{i}="{filename}"')
strings += ['', '[SourceFiles]', f'SourceFiles0={stage}\\', '', '[SourceFiles0]']
for i in range(len(files)):
    strings.append(f'%FILE{i}%=')
strings.append('')
Path(os.environ['SED_PATH']).write_text('\r\n'.join(strings), encoding='utf-8')
PY

iexpress.exe /N /Q "$sed_win"
[[ -s "$output" ]] || fail 'IExpress did not produce the package'

# Inspect and extract the SFX without executing it, then compare every embedded input.
inspect_dir="$stage/inspect"
rm -rf "$inspect_dir"
mkdir -p "$inspect_dir"
7z x -y -o"$inspect_dir" "$output" >/dev/null
for f in launcher.cmd bootstrap.ps1 safety.ps1 setup.ps1 "$openssh_name" "$tailscale_name"; do
  [[ -f "$inspect_dir/$f" ]] || fail "SFX missing: $f"
  cmp "$stage/$f" "$inspect_dir/$f" || fail "SFX content mismatch: $f"
done

# Copy through Windows APIs to avoid drvfs replacement/cache surprises.
desktop_win=$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("Desktop")' | tr -d '\r' | tail -n1)
final_win="${desktop_win}\\SSH-Launchpad-OneClick-Windows-x64.exe"
powershell.exe -NoProfile -Command "Copy-Item -LiteralPath '$output_win' -Destination '$final_win' -Force; Get-Item -LiteralPath '$final_win' | Select-Object FullName,Length,LastWriteTime | Format-List"

printf '\nBuild complete.\nSHA-256: '
sha256sum "$output" | awk '{print $1}'
printf 'Desktop: %s\n' "$final_win"
