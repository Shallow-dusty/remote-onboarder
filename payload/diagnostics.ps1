#requires -Version 5.1
# Read-only probes run in parallel; installers and SSH mutations stay serial.
function Start-OnboardDiagnostics {
    $worker = {
        param([string]$SafetyFile, [string]$Kind)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        . $SafetyFile
        if ($Kind -eq 'system') {
            [pscustomobject]@{ Type='OS'; Data=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,OSArchitecture,LastBootUpTime) }
            [pscustomobject]@{ Type='Services'; Data=@(Get-CimInstance Win32_Service | Where-Object { $_.Name -in @('sshd','Tailscale') } | Select-Object Name,State,StartMode,PathName,ProcessId) }
            [pscustomobject]@{ Type='Listeners'; Data=@(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue | Select-Object LocalAddress,LocalPort,OwningProcess) }
        } else {
            [pscustomobject]@{ Type='Profiles'; Data=@(Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name,Enabled,DefaultInboundAction) }
            $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Inbound -Enabled True -Action Allow)
            # NetSecurity associates filters by InstanceID. Bulk queries avoid
            # hundreds of sequential CIM round trips on a normal Windows desktop.
            $apps=@{}; $services=@{}; $portsById=@{}; $addresses=@{}
            foreach ($value in @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore)) { $apps[[string]$value.InstanceID]=$value }
            foreach ($value in @(Get-NetFirewallServiceFilter -PolicyStore ActiveStore)) { $services[[string]$value.InstanceID]=$value }
            foreach ($value in @(Get-NetFirewallPortFilter -PolicyStore ActiveStore)) { $portsById[[string]$value.InstanceID]=$value }
            foreach ($value in @(Get-NetFirewallAddressFilter -PolicyStore ActiveStore)) { $addresses[[string]$value.InstanceID]=$value }
            $count = 0
            foreach ($rule in $rules) {
                try {
                    $id=[string]$rule.InstanceID
                    if (-not $apps.ContainsKey($id) -or -not $services.ContainsKey($id) -or -not $portsById.ContainsKey($id) -or -not $addresses.ContainsKey($id)) { throw 'Incomplete rule filters' }
                    $app = @($apps[$id])
                    $service = @($services[$id])
                    $port = @($portsById[$id])
                    $program = [Environment]::ExpandEnvironmentVariables([string]$app[0].Program)
                    if ($program -and $program -ne 'Any' -and [IO.Path]::GetFileName($program) -ine 'sshd.exe') { continue }
                    if ([string]$service[0].Service -notin @('','Any','sshd')) { continue }
                    if ([string]$port[0].Protocol -notin @('TCP','6','Any','256')) { continue }
                    $ports = [string]::Join(',', @($port[0].LocalPort))
                    $portError = ''
                    try { if (-not (Test-PortIncludesSSH $ports)) { continue } } catch { $portError = $_.Exception.Message }
                    $address = @($addresses[$id])
                    [pscustomobject]@{ Type='Rule'; Name=$rule.Name; DisplayName=$rule.DisplayName; Description=$rule.Description; Source=$rule.PolicyStoreSourceType; Profile=[string]$rule.Profile; Program=$program; Package=(Get-OnboardProperty $app[0] 'Package'); Service=[string]$service[0].Service; Protocol=[string]$port[0].Protocol; LocalPort=$ports; RemoteAddress=@($address | ForEach-Object { $_.RemoteAddress }); PortError=$portError }
                } catch { [pscustomobject]@{ Type='RuleError'; Name=$rule.Name; Error=$_.Exception.Message } }
                $count++
                if ($count -ge 300) { [pscustomobject]@{ Type='Truncated'; Limit=300 }; break }
            }
        }
    }
    foreach ($kind in @('system','firewall')) {
        try {
            $job = Start-Job -ScriptBlock $worker -ArgumentList (Join-Path $PSScriptRoot 'safety.ps1'), $kind -ErrorAction Stop
            [pscustomobject]@{ Kind=$kind; Job=$job; Error='' }
        } catch { [pscustomobject]@{ Kind=$kind; Job=$null; Error=$_.Exception.Message } }
    }
}

function Complete-OnboardDiagnostics([object[]]$Jobs, [int]$TimeoutSeconds = 20) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($entry in $Jobs) {
        $data = @(); $errors = @(); $state = 'Unavailable'
        if (-not $entry.Job) { $errors = @($entry.Error) }
        else {
            $job = $entry.Job
            try {
                $remaining = [int][Math]::Max(0, [Math]::Ceiling($TimeoutSeconds - $clock.Elapsed.TotalSeconds))
                if ($remaining -gt 0) { $job | Wait-Job -Timeout $remaining | Out-Null }
                $state = [string]$job.State
                if ($state -notin @('Completed','Failed','Stopped')) { Stop-Job $job; $state = 'TimedOut' }
                $receiveErrors = @()
                $data = @(Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable receiveErrors)
                $errors = @($receiveErrors | ForEach-Object { $_.ToString() })
                if ($state -eq 'TimedOut') { $errors += 'Diagnostic timeout; collected partial results only' }
            } catch { $errors += $_.Exception.Message }
            finally { Remove-Job $job -Force -ErrorAction SilentlyContinue }
        }
        [pscustomobject]@{ Kind=$entry.Kind; State=$state; Data=$data; Errors=$errors }
    }
}

function Get-SshPrerequisiteFailures {
    try {
        $path = Join-Path $env:ProgramData 'ssh\sshd_config'
        Assert-NoReparsePath $path
        if (Test-Path -LiteralPath $path) { Assert-SimpleSshPolicy ([IO.File]::ReadAllText($path)) }
    } catch { [pscustomobject]@{ Component='ssh-policy'; Message=$_.Exception.Message } }
    try { [void]@(Get-UnsafeSshRules) }
    catch { [pscustomobject]@{ Component='firewall'; Message=$_.Exception.Message } }
}

function Invoke-OnboardingFlow([string]$OpenSshMsi, [string]$TailscaleMsi) {
    $failures = @(Get-SshPrerequisiteFailures)
    foreach ($failure in $failures) {
        [void]$script:DiagnosticIssues.Add($failure)
        Write-SetupEvent WARN ('SSH 前置问题（继续独立的网络接入）：' + $failure.Message)
    }
    # Joining the network does not require weakening/replacing existing SSH policy.
    $tailscale = Install-Tailscale $TailscaleMsi
    $script:TailscaleIP = Connect-Tailscale $tailscale
    if ($failures.Count) {
        throw 'Tailscale 已接入，但 SSH 前置条件未满足；没有安装/修改 SSH。诊断报告会自动保存到桌面'
    }
    Install-OpenSSH $OpenSshMsi
    Save-RecoverySnapshot
    Configure-Firewall
    Configure-OpenSSH
    Verify-Result $script:TailscaleIP
    Remove-Item -LiteralPath (Join-Path $StateRoot 'recovery-pending.txt') -Force -ErrorAction Stop
    $script:Success = $true
    $script:ExitCode = 0
    Remove-Item -LiteralPath $PayloadRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-InstallerLogTail([string]$Path, [int]$MaxBytes = 131072) {
    # Avoid PS 5.1 Get-Content -Tail: unterminated small files can hang its
    # backwards scan. Read a bounded byte snapshot, including an in-use MSI log.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $header = New-Object byte[] 3
        $headerCount = $stream.Read($header, 0, 3)
        $encoding = [Text.Encoding]::UTF8
        $wide = $false
        if ($headerCount -ge 2 -and $header[0] -eq 255 -and $header[1] -eq 254) { $encoding = [Text.Encoding]::Unicode; $wide = $true }
        elseif ($headerCount -ge 2 -and $header[0] -eq 254 -and $header[1] -eq 255) { $encoding = [Text.Encoding]::BigEndianUnicode; $wide = $true }
        $length = $stream.Length
        $start = [long][Math]::Max(0, $length - $MaxBytes)
        if ($wide) { $start -= $start % 2 }
        $stream.Position = $start
        $buffer = New-Object byte[] ([int]($length - $start))
        $read = 0
        while ($read -lt $buffer.Length) {
            $n = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($n -eq 0) { break }
            $read += $n
        }
        return @($encoding.GetString($buffer,0,$read) -split '\r?\n' | Select-Object -Last 100)
    } finally { $stream.Dispose() }
}

function Export-OnboardReport {
    $diagnostics = @(Complete-OnboardDiagnostics $script:DiagnosticJobs)
    $script:DiagnosticJobs = @()
    $installerTails = @()
    if (Test-Path -LiteralPath $LogRoot) {
        foreach ($log in @(Get-ChildItem -LiteralPath $LogRoot -Filter ($script:SessionId + '*-msi.log') -File -ErrorAction SilentlyContinue)) {
            try { $installerTails += [pscustomobject]@{ Name=$log.Name; Tail=(Get-InstallerLogTail $log.FullName) } }
            catch { $installerTails += [pscustomobject]@{ Name=$log.Name; Error='Unable to read installer log' } }
        }
    }
    $report = [ordered]@{
        version=$ToolVersion; sessionId=$script:SessionId; time=[DateTime]::UtcNow.ToString('o')
        computer=$env:COMPUTERNAME; targetUser=$TargetUser
        compatibilityMode=$CompatibilityMode; success=$script:Success
        tailscaleIP=$script:TailscaleIP; failedStep=$script:CurrentStep; error=$script:LastFailure
        rebootRequired=$script:RebootRequired; nativeOperationUncertain=$script:NativeUncertain
        recoveryPath=$script:RecoveryPath; issues=@($script:DiagnosticIssues.ToArray())
        warnings=@($script:CompatibilityWarnings.ToArray()); diagnostics=$diagnostics; installerLogs=$installerTails
    }
    $json = Protect-SetupText ($report | ConvertTo-Json -Depth 12)
    $desktop = Get-TargetDesktop
    $name = 'SSH-诊断报告.json'
    $saved = $false
    $reportSource = ''
    foreach ($directory in @($LogRoot,$desktop) | Select-Object -Unique) {
        try {
            if (Test-Path -LiteralPath $directory -PathType Container) {
                [IO.File]::WriteAllText((Join-Path $directory $name), $json, (New-Object Text.UTF8Encoding($true)))
                Write-Host ('诊断报告：' + (Join-Path $directory $name)) -ForegroundColor Cyan
                $saved = $true
                $reportSource = Join-Path $directory $name
            }
        } catch { Write-Host ('无法保存报告到该目录：' + $directory) -ForegroundColor Yellow }
    }
    if (-not $script:Success -and $desktop -and (Test-Path -LiteralPath $desktop)) {
        $partial = @('本次接入未完成，SSH 尚未确认可用。', ('Tailscale IP：' + $script:TailscaleIP), ('目标用户：' + $TargetUser), ('失败步骤：' + $script:CurrentStep), ('原因：' + $script:LastFailure), '请把桌面的 SSH-反馈资料.zip 发给协助者，不需要另行输入排查命令；若没有 ZIP，则发送诊断报告和安装日志。') -join "`r`n"
        [IO.File]::WriteAllText((Join-Path $desktop 'SSH-连接信息.txt'), (Protect-SetupText $partial), (New-Object Text.UTF8Encoding($true)))
    }
    if (-not $saved) { Write-Host '诊断报告无法写入，请拍下当前错误窗口。' -ForegroundColor Yellow }
    elseif ($desktop -and (Test-Path -LiteralPath $desktop)) {
        $bundleStage = Join-Path $env:TEMP ('SSH-Feedback-' + [guid]::NewGuid().ToString('N'))
        $pendingZip = Join-Path $desktop ('SSH-Feedback-' + [guid]::NewGuid().ToString('N') + '.zip')
        try {
            New-Item -ItemType Directory -Path $bundleStage | Out-Null
            Copy-Item -LiteralPath $reportSource -Destination (Join-Path $bundleStage $name)
            if (Test-Path -LiteralPath $script:TextLog) {
                $text = Protect-SetupText ([IO.File]::ReadAllText($script:TextLog))
                [IO.File]::WriteAllText((Join-Path $bundleStage 'SSH-安装日志.log'), $text, (New-Object Text.UTF8Encoding($true)))
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::CreateFromDirectory($bundleStage, $pendingZip)
            Move-Item -LiteralPath $pendingZip -Destination (Join-Path $desktop 'SSH-反馈资料.zip') -Force
            Write-Host '排查信息已自动打包。出错时只需发送桌面的 SSH-反馈资料.zip，不用输入命令。' -ForegroundColor Cyan
        } catch { Write-Host '反馈 ZIP 未能生成，诊断 JSON 仍已保存。' -ForegroundColor Yellow }
        finally {
            Remove-Item -LiteralPath $bundleStage -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $pendingZip -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-LogRequest([string]$Method, [string]$Uri, [byte[]]$Body, [string]$ContentType, [int]$TimeoutSeconds) {
    $url=[uri]$Uri
    $mapping=Get-Variable -Name LogEndpointAddresses -ErrorAction SilentlyContinue
    if ($mapping -and $mapping.Value.ContainsKey($url.Host)) {
        $curl=Join-Path $env:SystemRoot 'System32\curl.exe'
        if (-not (Test-Path -LiteralPath $curl)) { throw 'Windows curl.exe unavailable for private DNS fallback' }
        $temporary=Join-Path $LogRoot ('upload-'+[guid]::NewGuid().ToString('N')+'.tmp')
        try {
            [IO.File]::WriteAllBytes($temporary,$Body)
            $resolve=$url.Host+':'+$url.Port+':'+$mapping.Value[$url.Host]
            # --resolve preserves TLS hostname/certificate verification. No insecure
            # flag, redirect following, global hosts edits, or public fallback.
            $reply=& $curl --silent --show-error --fail --proto '=https' --noproxy '*' --connect-timeout 5 --max-time $TimeoutSeconds --resolve $resolve --request $Method --header ('Content-Type: '+$ContentType) --data-binary ('@'+$temporary) $Uri 2>$null
            if ($LASTEXITCODE -ne 0) { throw ('Private log request failed; curl exit '+$LASTEXITCODE) }
            return (($reply -join "`n") | ConvertFrom-Json)
        } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Body $Body -ContentType $ContentType -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -UseBasicParsing
}

function Get-FullRedactedLog([string]$Path) {
    # Preserve the entire file, not merely the diagnostic tail. BOM-aware UTF-8/
    # UTF-16 reading supports Windows Installer logs. Reject rather than truncate.
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -gt 32MB) { throw 'File exceeds 32 MiB upload limit; full local file retained' }
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
        return Protect-SetupText $text
    } finally { $stream.Dispose() }
}

function Send-OnboardArtifacts {
    if ($LogEndpoints.Count -eq 0) { return }
    $deadline=[DateTime]::UtcNow.AddSeconds(120)
    $desktop=Get-TargetDesktop
    $sources=[ordered]@{
        'setup.log'=$script:TextLog
        'events.jsonl'=$script:JsonLog
        'diagnostics.json'=(Join-Path $LogRoot 'SSH-诊断报告.json')
        'openssh-msi.log'=(Join-Path $LogRoot ($script:SessionId+'-openssh-msi.log'))
        'tailscale-msi.log'=(Join-Path $LogRoot ($script:SessionId+'-tailscale-msi.log'))
        'connection.txt'=(Join-Path $desktop 'SSH-连接信息.txt')
    }
    $results=New-Object System.Collections.Generic.List[object]
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        foreach($name in $sources.Keys) {
            $path=$sources[$name]
            if(-not (Test-Path -LiteralPath $path -PathType Leaf)){continue}
            $sent=$false;$reason='No reachable log endpoint';$size=0;$digest=''
            try {
                $body=[Text.Encoding]::UTF8.GetBytes((Get-FullRedactedLog $path))
                $size=$body.Length
                if($size -gt 32MB){throw 'UTF-8 log exceeds upload size limit; not truncated'}
                $digest=([BitConverter]::ToString($hash.ComputeHash($body))).Replace('-','').ToLowerInvariant()
                foreach($endpoint in $LogEndpoints){
                    if($sent){break}
                    if(([uri]$endpoint).Host.EndsWith('.ts.net') -and -not $script:TailscaleIP){$reason='Tailnet not connected; full log retained locally';continue}
                    $base=$endpoint.Substring(0,$endpoint.Length-'/events'.Length)
                    $url=$base+'/artifacts/'+[uri]::EscapeDataString($script:SessionId)+'/'+$name
                    for($attempt=1;$attempt -le 2;$attempt++){
                        $remaining=[int][Math]::Floor(($deadline-[DateTime]::UtcNow).TotalSeconds)
                        if($remaining -le 0){$reason='Upload deadline reached; local log retained';break}
                        try {
                            $ack=Invoke-LogRequest -Method 'PUT' -Uri $url -Body $body -ContentType 'text/plain; charset=utf-8' -TimeoutSeconds ([Math]::Min(20,$remaining))
                            if(-not $ack.ok -or [long]$ack.bytes -ne $size -or [string]$ack.sha256 -ne $digest){throw 'Server acknowledgement mismatch'}
                            $sent=$true;$reason='';break
                        } catch {$reason=Protect-SetupText $_.Exception.Message}
                    }
                }
            } catch {$reason=Protect-SetupText $_.Exception.Message}
            $results.Add([pscustomobject]@{name=$name;uploaded=$sent;bytes=$size;sha256=$digest;error=$reason})
            if($sent){Write-Host ('云日志已保存：'+$name+' ('+$size+' bytes)') -ForegroundColor Green}
            else{Write-Host ('云日志待补传：'+$name+'；'+$reason) -ForegroundColor Yellow}
        }
    } finally {$hash.Dispose()}
    $status=[ordered]@{sessionId=$script:SessionId;files=$results.ToArray();time=[DateTime]::UtcNow.ToString('o')}
    $text=$status|ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $LogRoot 'upload-status.json'),$text,(New-Object Text.UTF8Encoding($true)))
    try {[IO.File]::WriteAllText((Join-Path $desktop 'SSH-云日志状态.json'),$text,(New-Object Text.UTF8Encoding($true)))}catch{}
    Write-Host ('云日志会话编号：'+$script:SessionId) -ForegroundColor Cyan
    Write-Host '上传失败不会删除本地日志；如尚未入网，发送桌面反馈 ZIP。' -ForegroundColor Cyan
}

