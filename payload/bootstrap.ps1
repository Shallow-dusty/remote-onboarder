#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TargetUser,
    [Parameter(Mandatory=$true)][string]$TargetProfile,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$setup = Join-Path $PSScriptRoot 'setup.ps1'
if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    Write-Host "Missing setup script: $setup" -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}

try {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $setup),
        '-TargetUser', ('"{0}"' -f $TargetUser.Replace('"', '')),
        '-TargetProfile', ('"{0}"' -f $TargetProfile.Replace('"', ''))
    )
    if ($SelfTest) {
        $arguments += @('-SelfTest', '-NoPause')
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList ($arguments -join ' ') -Wait -PassThru -NoNewWindow
    } else {
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($arguments -join ' ') -Wait -PassThru
    }
    exit $process.ExitCode
} catch {
    Write-Host ("Administrator launch failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
