#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
config=${1:-"$repo/build/oneclick/private-config.json"}
payload_dir="$repo/build/oneclick/payloads"
source_dir="$repo/payload"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null || fail 'jq is required'
command -v curl >/dev/null || fail 'curl is required'
command -v powershell.exe >/dev/null || fail 'Windows PowerShell is required (run from WSL)'
command -v iexpress.exe >/dev/null || fail 'Windows IExpress is required (run from WSL)'
[[ -f "$config" ]] || fail "private config not found: $config"

auth_key=$(jq -er '.tailscaleAuthKey | select(type=="string" and startswith("tskey-auth-") and length>20)' "$config") || fail 'invalid tailscaleAuthKey in private config'
public_key=$(jq -er '.publicKey | select(type=="string" and startswith("ssh-") and length>40)' "$config") || fail 'invalid publicKey in private config'
expected_tailnet=$(jq -er '.expectedTailnet | select(type=="string" and length>5 and contains("."))' "$config") || fail 'invalid expectedTailnet in private config'
log_endpoints=$(jq -c '.logEndpoints // [] | select(type=="array")' "$config") || fail 'invalid logEndpoints in private config'
jq -e '.logEndpoints // [] | length == 0 or all(type == "string" and startswith("http"))' "$config" >/dev/null || fail 'logEndpoints must be http(s) URLs'

mkdir -p "$payload_dir"
openssh_name='OpenSSH-Win64-v10.0.0.0.msi'
tailscale_name='tailscale-setup-1.102.3-amd64.msi'
openssh_url='https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64-v10.0.0.0.msi'
tailscale_url='https://pkgs.tailscale.com/stable/tailscale-setup-1.102.3-amd64.msi'

fetch() {
  local url=$1 output=$2
  if [[ ! -s "$output" ]]; then
    printf 'Downloading %s\n' "$(basename "$output")"
    curl -fL --retry 4 --retry-delay 2 --continue-at - --output "$output" "$url"
  fi
}
fetch "$openssh_url" "$payload_dir/$openssh_name"
fetch "$tailscale_url" "$payload_dir/$tailscale_name"

openssh_sha=$(sha256sum "$payload_dir/$openssh_name" | awk '{print $1}')
tailscale_sha=$(sha256sum "$payload_dir/$tailscale_name" | awk '{print $1}')

# shellcheck disable=SC2016 # $env:TEMP is intentionally evaluated by Windows PowerShell.
win_temp=$(powershell.exe -NoProfile -Command '$env:TEMP' | tr -d '\r' | tail -n1)
[[ "$win_temp" =~ ^[A-Za-z]:\\ ]] || fail "unexpected Windows TEMP: $win_temp"
stage_win="${win_temp}\\ssh-launchpad-oneclick-build"
stage=$(wslpath -u "$stage_win")
output_win="${win_temp}\\SSH-Launchpad-OneClick-Windows-x64.exe"
output=$(wslpath -u "$output_win")
sed_win="${stage_win}\\package.sed"
sed_path="$stage/package.sed"

powershell.exe -NoProfile -Command "Remove-Item -LiteralPath '$stage_win' -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path '$stage_win' | Out-Null; Remove-Item -LiteralPath '$output_win' -Force -ErrorAction SilentlyContinue; exit 0"
mkdir -p "$stage"
cp "$source_dir/launcher.cmd" "$source_dir/bootstrap.ps1" "$stage/"
cp "$payload_dir/$openssh_name" "$payload_dir/$tailscale_name" "$stage/"

SOURCE_SETUP="$source_dir/setup.ps1" OUTPUT_SETUP="$stage/setup.ps1" \
AUTH_KEY="$auth_key" PUBLIC_KEY="$public_key" OPENSSH_SHA="$openssh_sha" TAILSCALE_SHA="$tailscale_sha" \
EXPECTED_TAILNET="$expected_tailnet" LOG_ENDPOINTS_JSON="$log_endpoints" \
python3 - <<'PY'
from pathlib import Path
import os
source = Path(os.environ['SOURCE_SETUP']).read_text(encoding='utf-8-sig')
values = {
    '__TAILSCALE_AUTH_KEY__': os.environ['AUTH_KEY'],
    '__SSH_PUBLIC_KEY__': os.environ['PUBLIC_KEY'],
    '__OPENSSH_SHA256__': os.environ['OPENSSH_SHA'],
    '__TAILSCALE_SHA256__': os.environ['TAILSCALE_SHA'],
    '__EXPECTED_TAILNET__': os.environ['EXPECTED_TAILNET'],
    '__LOG_ENDPOINTS_JSON__': '@(' + ', '.join("'%s'" % e for e in __import__('json').loads(os.environ['LOG_ENDPOINTS_JSON'])) + ')',
}
for marker, value in values.items():
    if marker not in source:
        raise SystemExit(f'missing template marker: {marker}')
    source = source.replace(marker, value)
if '__' in source and any(marker in source for marker in values):
    raise SystemExit('unreplaced template marker')
Path(os.environ['OUTPUT_SETUP']).write_text(source, encoding='utf-8-sig', newline='\r\n')
PY

# Parse the exact generated PowerShell on Windows PowerShell 5.1.
powershell.exe -NoProfile -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$stage_win\\setup.ps1',[ref]\$null,[ref]\$e); if(\$e.Count){\$e | ForEach-Object { Write-Error (\$_.Extent.StartLineNumber.ToString()+': '+\$_.Message) }; exit 1}; 'PowerShell syntax: OK'"

# Require the official payload signatures before packaging.
powershell.exe -NoProfile -Command "\$files=@('$stage_win\\$openssh_name','$stage_win\\$tailscale_name'); foreach(\$f in \$files){\$s=Get-AuthenticodeSignature -LiteralPath \$f; Write-Host ((Split-Path \$f -Leaf)+': '+\$s.Status+' / '+\$s.SignerCertificate.Subject); if(\$s.Status -ne 'Valid'){exit 1}}"

# Safe self-test: exercises hashes, idempotent config/key transforms, process wrapper and live log upload.
set +e
selftest_output=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$stage_win\\setup.ps1" -SelfTest -NoPause 2>&1)
selftest_code=$?
set -e
printf '%s\n' "$selftest_output"
[[ $selftest_code -eq 0 ]] || fail "generated setup self-test failed ($selftest_code)"
session=$(printf '%s\n' "$selftest_output" | tr -d '\r' | grep -oE 'SELFTEST_SESSION=[A-Za-z0-9._-]+' | tail -n1 | cut -d= -f2)
[[ -n "$session" ]] || fail 'self-test session id missing'
first_endpoint=$(printf '%s' "$log_endpoints" | jq -r '.[0] // empty')
if [[ -n "$first_endpoint" && "$first_endpoint" == */events ]]; then
  verify_url="${first_endpoint%/events}/sessions/$session"
  curl -fsS "$verify_url" | grep -q 'SELFTEST_SESSION' || fail 'server did not persist self-test log'
  printf 'Remote log verification: OK (%s)\n' "$session"
else
  printf 'Remote log verification: skipped (no /events endpoint configured)\n'
fi

TARGET_NAME="$output_win" STAGE_WIN="$stage_win" SED_PATH="$sed_path" python3 - <<'PY'
from pathlib import Path
import os
stage = os.environ['STAGE_WIN']
target = os.environ['TARGET_NAME']
files = ['launcher.cmd', 'bootstrap.ps1', 'setup.ps1', 'OpenSSH-Win64-v10.0.0.0.msi', 'tailscale-setup-1.102.3-amd64.msi']
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
for f in launcher.cmd bootstrap.ps1 setup.ps1 "$openssh_name" "$tailscale_name"; do
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
