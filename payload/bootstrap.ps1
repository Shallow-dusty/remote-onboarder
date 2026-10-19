#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TargetUser,
    [Parameter(Mandatory=$true)][string]$TargetProfile,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$setup = Join-Path $PSScriptRoot 'setup.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($required in @('setup.ps1','safety.ps1','diagnostics.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $required) -PathType Leaf)) {
        Write-Host ('Missing file: '+$required+'. Extract the complete ZIP / copy ALL update files into the original folder.') -ForegroundColor Red
        if (-not $SelfTest) { Read-Host 'Press Enter to close' | Out-Null }
        exit 1
    }
}

try {
    if (-not $SelfTest -and ($env:SSH_CONNECTION -or $env:SSH_CLIENT)) { throw 'Run locally on the target computer; active SSH sessions are not supported.' }
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $setup),
        '-TargetUser', ('"{0}"' -f $TargetUser.Replace('"', '')),
        '-TargetProfile', ('"{0}"' -f $TargetProfile.Replace('"', ''))
    )
    if ($SelfTest) {
        $arguments += @('-SelfTest', '-NoPause')
        $process = Start-Process -FilePath $powershell -ArgumentList ($arguments -join ' ') -Wait -PassThru -NoNewWindow
    } else {
        $process = Start-Process -FilePath $powershell -Verb RunAs -ArgumentList ($arguments -join ' ') -Wait -PassThru
    }
    exit $process.ExitCode
} catch {
    $message = "Administrator launch failed or was cancelled: $($_.Exception.Message)"
    Write-Host $message -ForegroundColor Red
    try { [IO.File]::WriteAllText((Join-Path ([Environment]::GetFolderPath('Desktop')) 'SSH-launch-error.txt'), $message, (New-Object Text.UTF8Encoding($true))) } catch { }
    if (-not $SelfTest) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
