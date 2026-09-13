#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path $PSScriptRoot -Parent
$SshPort = 22
$TailscaleRemoteAddress = '100.64.0.0/10'
$TailscaleRemoteAddressNormalized = '100.64.0.0/255.192.0.0'
$TailscaleAuthKey = 'tskey-auth-SYNTHETIC-NOT-A-CREDENTIAL'
. (Join-Path $root 'payload/safety.ps1')
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'payload/setup.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'setup parse failed' }
# Evaluate only trusted repository function definitions; never the setup entry point.
foreach ($name in @('Get-ManagedSshConfig','Merge-PublicKey')) {
    $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function MustReject([scriptblock]$action) { $rejected=$false; try { & $action } catch { $rejected=$true }; Assert $rejected 'unsafe input accepted' }
$sample = "Port 2222`r`nPasswordAuthentication yes`r`nMatch Group administrators`r`n AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys"
$once = Get-ManagedSshConfig $sample
Assert ((Get-ManagedSshConfig $once) -eq $once) 'configuration is not idempotent'
Assert (@($once -split '\r?\n' | Where-Object { $_ -match '^Port ' }).Count -eq 1) 'extra port survives'
foreach ($text in @('Include other.conf', 'ListenAddress 0.0.0.0', "Match User guest`n PasswordAuthentication yes", "Match Group administrators`n PasswordAuthentication yes")) { MustReject { Get-ManagedSshConfig $text } }
Assert ((Protect-SetupText ('failure '+$TailscaleAuthKey)) -notmatch 'SYNTHETIC') 'auth key leaked'
foreach ($ports in @('Any','22','20-30','443,22')) { Assert (Test-PortIncludesSSH $ports) 'SSH range missed' }
Assert (-not (Test-PortIncludesSSH '80,443')) 'unrelated ports changed'
MustReject { Test-PortIncludesSSH 'RPC' }
# Inventory fixtures: no NetSecurity cmdlet is ever invoked by these mocks.
function Get-NetFirewallProfile { @('Domain','Private','Public') | ForEach-Object { [pscustomobject]@{ Enabled='True'; DefaultInboundAction='Block' } } }
$script:Rules=@()
function Get-NetFirewallRule { $script:Rules }
function Get-NetFirewallApplicationFilter { process { [pscustomobject]@{Program='Any'} } }
function Get-NetFirewallServiceFilter { process { [pscustomobject]@{Service='Any'} } }
function Get-NetFirewallPortFilter { process { [pscustomobject]@{ Protocol=$_.Protocol; LocalPort=$_.LocalPort } } }
function Get-NetFirewallAddressFilter { process { [pscustomobject]@{ RemoteAddress=@($_.Scope) } } }
$script:Rules=@([pscustomobject]@{Name='foreign';Protocol='Any';LocalPort='Any';Scope='Any';PolicyStoreSourceType='Local'})
MustReject { Get-UnsafeSshRules }
$script:Rules=@([pscustomobject]@{Name='OpenSSH-Server-In-TCP';Protocol='TCP';LocalPort='22';Scope='Any';PolicyStoreSourceType='Local'})
Assert (@(Get-UnsafeSshRules).Count -eq 1) 'stock broad rule not identified'
$script:Rules[0].Scope='100.64.0.0/10'
Assert (@(Get-UnsafeSshRules).Count -eq 0) 'narrow rule not preserved'
function Get-NetFirewallProfile { [pscustomobject]@{Enabled='False';DefaultInboundAction='Allow'} }
MustReject { Get-UnsafeSshRules }
# Recovery is exercised only on temporary files, with all service/firewall
# commands replaced by in-process fakes.
function Get-NetFirewallProfile { @('Domain','Private','Public') | ForEach-Object { [pscustomobject]@{Enabled='True';DefaultInboundAction='Block'} } }
$script:Rules=@()
function Get-CimInstance { [pscustomobject]@{State='Stopped';StartMode='Manual'} }
function Stop-Service { }
function Set-Service { }
function Start-Service { throw 'stopped service must not be started during recovery' }
function Enable-NetFirewallRule { }
function Remove-NetFirewallRule { }
function Write-SetupEvent { }
$oldProgramData=$env:ProgramData
$temp=Join-Path $env:TEMP ('Onboarder-Recovery-Fixture-'+[guid]::NewGuid().ToString('N'))
try {
    $env:ProgramData=Join-Path $temp 'programdata'
    $TargetProfile=Join-Path $temp 'user'
    $StateRoot=Join-Path $temp 'state'
    $BackupRoot=Join-Path $StateRoot 'backups'
    $script:SessionId='fixture'
    New-Item -ItemType Directory -Force -Path (Join-Path $env:ProgramData 'ssh'),(Join-Path $TargetProfile '.ssh'),$BackupRoot | Out-Null
    $config=Join-Path $env:ProgramData 'ssh\sshd_config'
    [IO.File]::WriteAllText($config,"# original`r`nPort 22")
    $before=[IO.File]::ReadAllBytes($config)
    Save-RecoverySnapshot
    Assert (Test-Path -LiteralPath (Join-Path $StateRoot 'recovery-pending.txt')) 'intent not persisted'
    [IO.File]::WriteAllText($config,'changed')
    [IO.File]::WriteAllText((Join-Path $TargetProfile '.ssh\authorized_keys'),'introduced')
    Restore-RecoverySnapshot
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -eq [Convert]::ToBase64String($before)) 'config preimage not restored'
    Assert (-not (Test-Path -LiteralPath (Join-Path $TargetProfile '.ssh\authorized_keys'))) 'new key file survived rollback'
    Assert (-not (Test-Path -LiteralPath (Join-Path $StateRoot 'recovery-pending.txt'))) 'recovery remained pending after success'
} finally { $env:ProgramData=$oldProgramData; if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }
Write-Host 'Safety fixtures PASS (no service, firewall or account mutations)'
