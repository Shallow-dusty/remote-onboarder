#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'payload/safety.ps1')
. (Join-Path $root 'payload/diagnostics.ps1')
$script:Passed=0
function Check($condition,[string]$label) { if(-not $condition){throw ('FAIL: '+$label)}; $script:Passed++; Write-Host ('PASS: '+$label) }
function Reject([scriptblock]$action,[string]$label) { $rejected=$false;try{& $action | Out-Null}catch{$rejected=$true};Check $rejected $label }
function Write-SetupEvent { }
$CompatibilityMode=$false
$TailscaleRemoteAddress='100.64.0.0/10'
$TailscaleRemoteAddressNormalized='100.64.0.0/255.192.0.0'
$TailscaleAuthKey='tskey-auth-SYNTHETIC-RESILIENCE-ONLY'
$script:CompatibilityWarnings=New-Object 'System.Collections.Generic.List[string]'
function Get-NetFirewallProfile { @('Domain','Private','Public') | ForEach-Object { [pscustomobject]@{Enabled='True';DefaultInboundAction='Block'} } }
$script:Rule=[pscustomobject]@{Name='{fixture-rule}';DisplayName='Windows fixture';PolicyStoreSourceType='Local';Direction='Inbound';Enabled='True';Action='Allow'}
function Get-NetFirewallRule { $script:Rule }
function Get-NetFirewallApplicationFilter { process { [pscustomobject]@{Program='Any';Package='Any'} } }
function Get-NetFirewallServiceFilter { process { [pscustomobject]@{Service='Any'} } }
function Get-NetFirewallPortFilter { process { [pscustomobject]@{Protocol='TCP';LocalPort='Any'} } }
function Get-NetFirewallAddressFilter { process { [pscustomobject]@{RemoteAddress=@('Any')} } }
function Disable-NetFirewallRule { throw 'test must not mutate firewall' }
Reject {Get-UnsafeSshRules} 'strict mode still rejects a foreign broad rule'
$CompatibilityMode=$true
Check (@(Get-UnsafeSshRules).Count -eq 0) 'compatibility mode preserves foreign rule without scheduling its disable'
Check ($script:CompatibilityWarnings.Count -gt 0) 'compatibility warning retained for diagnostics'
Check (($script:CompatibilityWarnings -join ';') -match 'DisplayName=Windows fixture') 'warning contains human-readable rule details'
function Get-NetFirewallProfile { [pscustomobject]@{Enabled='False';DefaultInboundAction='Allow'} }
Check (@(Get-UnsafeSshRules).Count -eq 0) 'compatibility mode preserves permissive existing profiles'
$CompatibilityMode=$false
Reject {Get-UnsafeSshRules} 'strict mode still rejects permissive profiles'

# Only the safe MSI wrapper definition is extracted; never execute setup entry point.
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'payload/setup.ps1'),[ref]$null,[ref]$errors)
Check ($errors.Count -eq 0) 'setup parses under Windows PowerShell 5.1'
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SshConnectionInfo'},$true)
Check ($null -ne $node) 'connection helper is present'
. ([scriptblock]::Create($node.Extent.Text))
$asciiConnection=Get-SshConnectionInfo 'alice' '100.64.0.1' 'DESKTOP-TEST'
Check ($asciiConnection.Command -eq 'ssh -l "alice" 100.64.0.1') 'ASCII username keeps one-line ssh command'
Check (-not $asciiConnection.Config) 'ASCII username emits no ssh config'
$cnConnection=Get-SshConnectionInfo '尚明阳' '100.64.0.1' 'LAPTOP-RNN171NI'
Check ($cnConnection.Command -eq 'ssh friend-laptop-rnn171ni') 'non-ASCII username avoids invalid command-line user'
Check ($cnConnection.Command -notmatch '尚明阳') 'non-ASCII username absent from command'
Check ($cnConnection.Config -match 'User 尚明阳') 'non-ASCII username emitted via ssh config User'
Check ($cnConnection.Config -match 'HostName 100\.64\.0\.1') 'ssh config carries target address'
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-MsiInstall'},$true)
. ([scriptblock]::Create($node.Extent.Text))
$script:Codes=New-Object 'System.Collections.Generic.Queue[int]'
$script:Sleeps=0
function Invoke-NativeProcess { [pscustomobject]@{ExitCode=$script:Codes.Dequeue()} }
function Start-Sleep { $script:Sleeps++ }
$script:Codes.Enqueue(1618);$script:Codes.Enqueue(0)
Check ((Invoke-MsiInstall '/synthetic' 'fixture').ExitCode -eq 0) 'MSI busy then success retries automatically'
Check ($script:Sleeps -eq 1) 'MSI retry waits between attempts'
$script:Codes.Enqueue(1618);$script:Codes.Enqueue(1618);$script:Codes.Enqueue(1618)
Reject {Invoke-MsiInstall '/synthetic' 'fixture'} 'persistent MSI busy exits after three attempts'
$script:Codes.Enqueue(3010);$script:RebootRequired=$false
[void](Invoke-MsiInstall '/synthetic' 'fixture')
Check $script:RebootRequired 'MSI reboot request retained in outcome'
function Invoke-NativeProcess { throw 'synthetic installer failure' }
Reject {Invoke-MsiInstall '/synthetic' 'fixture'} 'non-busy installer failure is not blindly retried'

$temp=Join-Path $env:TEMP ('Onboarder-Resilience-'+[guid]::NewGuid().ToString('N'))
try {
    $StateRoot=Join-Path $temp 'state'
    $PayloadRoot=Join-Path $StateRoot 'payloads'
    $LogRoot=Join-Path $StateRoot 'logs'
    New-Item -ItemType Directory -Force -Path $StateRoot,$PayloadRoot,$LogRoot | Out-Null
    $script:Calls=New-Object 'System.Collections.Generic.List[string]'
    $script:DiagnosticIssues=New-Object 'System.Collections.Generic.List[object]'
    $script:Blockers=@()
    $script:FailAt=''
    function Step([string]$name){$script:Calls.Add($name);if($script:FailAt -eq $name){throw ('synthetic failure at '+$name)}}
    function Get-SshPrerequisiteFailures { $script:Blockers }
    function Install-Tailscale { Step 'install-ts'; 'synthetic-tailscale.exe' }
    function Connect-Tailscale { Step 'join-ts'; '100.100.1.2' }
    function Install-OpenSSH { Step 'install-ssh' }
    function Save-RecoverySnapshot { Step 'snapshot';[IO.File]::WriteAllText((Join-Path $StateRoot 'recovery-pending.txt'),'fixture') }
    function Configure-Firewall { Step 'firewall' }
    function Configure-OpenSSH { Step 'ssh' }
    function Verify-Result { Step 'verify' }
    $script:Success=$false;$script:ExitCode=1
    Invoke-OnboardingFlow 'synthetic-ssh.msi' 'synthetic-ts.msi'
    Check (($script:Calls -join ',') -eq 'install-ts,join-ts,install-ssh,snapshot,firewall,ssh,verify') 'installation and mutation ordering is serial'
    Check ($script:Success -and $script:ExitCode -eq 0) 'complete verification required for success'
    Check (-not (Test-Path (Join-Path $StateRoot 'recovery-pending.txt'))) 'success clears only its recovery marker'
    $script:Calls.Clear();$script:Success=$false;$script:TailscaleIP=''
    $script:Blockers=@([pscustomobject]@{Component='ssh-policy';Message='custom policy'},[pscustomobject]@{Component='firewall';Message='unknown firewall'})
    Reject {Invoke-OnboardingFlow 'ssh' 'ts'} 'SSH blockers produce explicit incomplete outcome'
    Check (($script:Calls -join ',') -eq 'install-ts,join-ts') 'network still joins when SSH is blocked; SSH remains untouched'
    Check ($script:TailscaleIP -eq '100.100.1.2' -and -not $script:Success) 'partial network IP retained without claiming SSH success'
    Check ($script:DiagnosticIssues.Count -eq 2) 'multiple prerequisite problems are aggregated'
    $script:Blockers=@();$script:Calls.Clear();$script:FailAt='join-ts'
    Reject {Invoke-OnboardingFlow 'ssh' 'ts'} 'network join failure is reported'
    Check (-not $script:Calls.Contains('install-ssh')) 'no unnecessary SSH install after network failure'
    foreach($point in @('install-ssh','firewall','ssh','verify')){
        $script:FailAt=$point;$script:Calls.Clear();$script:Success=$false
        Reject {Invoke-OnboardingFlow 'ssh' 'ts'} ('failure propagated at '+$point)
        Check (-not $script:Success) ('no false success at '+$point)
    }
    $script:FailAt='';$script:Success=$false;$script:TailscaleIP='100.100.1.2'
    $ToolVersion='fixture';$TargetUser='尚明阳';$CompatibilityMode=$true
    $script:SessionId='fixture';$script:CurrentStep='fixture';$script:LastFailure='failed '+$TailscaleAuthKey
    $script:NativeUncertain=$false;$script:RecoveryPath='fixture';$script:DiagnosticJobs=@()
    $script:TextLog=Join-Path $LogRoot 'fixture.log'
    [IO.File]::WriteAllText($script:TextLog,'log '+$TailscaleAuthKey)
    [IO.File]::WriteAllText((Join-Path $LogRoot 'fixture-test-msi.log'),'synthetic installer tail')
    function Get-TargetDesktop { $temp }
    # Preserve the real collector for the next test before stubbing export input.
    $realCollector=(Get-Command Complete-OnboardDiagnostics).ScriptBlock
    function Complete-OnboardDiagnostics { [pscustomobject]@{Kind='fixture';State='Completed';Data=@();Errors=@()} }
    Export-OnboardReport
    $report=Get-Content -LiteralPath (Join-Path $temp 'SSH-诊断报告.json') -Raw -Encoding UTF8
    $parsed=$report | ConvertFrom-Json
    Check ($parsed.targetUser -eq '尚明阳') 'Chinese username preserved in diagnostic JSON'
    Check (-not $report.Contains($TailscaleAuthKey)) 'diagnostic report redacts auth key'
    Check ($parsed.tailscaleIP -eq '100.100.1.2' -and -not $parsed.success) 'partial outcome survives report export'
    Check (Test-Path -LiteralPath (Join-Path $temp 'SSH-连接信息.txt')) 'failure also exports a current connection-status file'
    Check ($parsed.installerLogs.Count -eq 1) 'installer failure tail included automatically'
    Check (([string]$parsed.installerLogs[0].Tail) -match 'synthetic installer tail') 'unterminated installer log does not hang report generation'
    $unicodeLog=Join-Path $temp 'unicode-msi.log'
    [IO.File]::WriteAllText($unicodeLog, ((1..500 | ForEach-Object { '安装日志行 '+$_ }) -join "`r`n"), [Text.Encoding]::Unicode)
    $tail=@(Get-InstallerLogTail $unicodeLog)
    Check ($tail.Count -eq 100 -and $tail[-1] -eq '安装日志行 500') 'UTF-16 installer log tail is decoded and bounded'
    $largeLog=Join-Path $temp 'large-msi.log'
    [IO.File]::WriteAllText($largeLog, ('x' * 200000))
    Check (([string](Get-InstallerLogTail $largeLog)).Length -le 131072) 'large unterminated log read is byte-bounded'
    $zipPath=Join-Path $temp 'SSH-反馈资料.zip'
    Check (Test-Path -LiteralPath $zipPath) 'feedback is a single sendable ZIP'
    $archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entry=$archive.GetEntry('SSH-安装日志.log')
        $reader=New-Object IO.StreamReader($entry.Open())
        try {$logText=$reader.ReadToEnd()} finally {$reader.Dispose()}
        Check (-not $logText.Contains($TailscaleAuthKey)) 'feedback ZIP log is redacted'
    } finally {$archive.Dispose()}
    $jobs=@(
        [pscustomobject]@{Kind='one';Job=(Start-Job { 'first result' });Error=''},
        [pscustomobject]@{Kind='two';Job=(Start-Job { 'partial result'; throw 'synthetic probe failure' });Error=''}
    )
    $collected=@(& $realCollector $jobs 20)
    Check ($collected.Count -eq 2) 'parallel jobs both collected even when one fails'
    Check (($collected | Where-Object Kind -eq 'two').Data -contains 'partial result') 'partial diagnostic output retained after worker error'
    $slow=@([pscustomobject]@{Kind='slow';Job=(Start-Job { Start-Sleep -Seconds 30 });Error=''})
    $expired=@(& $realCollector $slow 0)
    Check ($expired[0].State -eq 'TimedOut') 'slow diagnostic worker is bounded and removed'
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }
Write-Host ('Resilience fixtures PASS: '+$script:Passed+' assertions; no live install/service/firewall/account changes')
