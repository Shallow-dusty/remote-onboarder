#requires -Version 5.1
# Helpers only. Dot-sourcing this file never changes machine state.
function Protect-SetupText([string]$Text) {
    if ($TailscaleAuthKey) { $Text = $Text.Replace($TailscaleAuthKey, '[REDACTED]') }
    return [regex]::Replace($Text, 'tskey-[A-Za-z0-9_-]+', '[REDACTED]')
}

function Assert-NoReparsePath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -Force -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '路径含链接/重解析点，请人工检查后再运行' }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }; $current = $parent
    }
}

function Initialize-ProtectedState {
    Assert-NoReparsePath $StateRoot
    if (Test-Path -LiteralPath $StateRoot) {
        $owner = (Get-Acl -LiteralPath $StateRoot).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @('S-1-5-18', 'S-1-5-32-544')) { throw '工作目录不是 SYSTEM/Administrators 所有，请人工检查，未信任已有文件' }
        foreach ($item in @(Get-ChildItem -LiteralPath $StateRoot -Force -Recurse)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '工作目录含重解析点，已停止' }
        }
    }
    New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($admins); $acl.SetAccessRuleProtection($true, $false)
    foreach ($id in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($id)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $StateRoot -AclObject $acl
    if (Test-Path -LiteralPath (Join-Path $StateRoot 'native-pending.txt')) { throw '有未确认完成的原生操作，请先检查进程与 Tailnet 状态；不要直接重跑' }
    if (Test-Path -LiteralPath (Join-Path $StateRoot 'installer-pending.txt')) { throw '上次软件安装未确认结束，请检查 Windows Installer/软件状态后由协助者处理 installer-pending.txt' }
    if (Test-Path -LiteralPath (Join-Path $StateRoot 'recovery-pending.txt')) { throw '有未完成的配置恢复，请协助者检查 recovery-pending.txt 指向的快照；不要直接重跑' }
}

function Assert-SimpleSshPolicy([string]$Text) {
    $inMatch = $false
    foreach ($line in ($Text -split '\r?\n')) {
        $line = ($line -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        if ($line -match '^(?i:Match)\s+Group\s+administrators$' -and -not $inMatch) { $inMatch = $true; continue }
        if ($line -match '^(?i:Match|Include|ListenAddress)\b') { throw '现有 SSH 包含自定义 Match/Include/ListenAddress；请人工检查，本工具不会猜测或覆盖' }
        if ($inMatch -and $line -notmatch '^(?i:AuthorizedKeysFile)\s+__PROGRAMDATA__/ssh/administrators_authorized_keys$') { throw '只支持 Windows 默认的 administrators Match 块' }
    }
}

function Test-PortIncludesSSH([string]$Ports) {
    foreach ($part in ($Ports -split ',')) {
        $part = $part.Trim()
        if ($part -eq 'Any' -or $part -eq '22') { return $true }
        if ($part -match '^(\d+)-(\d+)$') {
            if ([int]$Matches[1] -le 22 -and [int]$Matches[2] -ge 22) { return $true }
        } elseif ($part -notmatch '^\d+$') { throw '发现无法解析的防火墙端口条件，请人工检查' }
    }
    return $false
}

function Get-UnsafeSshRules {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    if ($profiles.Count -ne 3 -or @($profiles | Where-Object { [string]$_.Enabled -ne 'True' -or [string]$_.DefaultInboundAction -ne 'Block' }).Count) { throw 'Windows 防火墙必须启用且所有配置文件默认阻止入站' }
    foreach ($rule in @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Inbound -Enabled True -Action Allow -ErrorAction Stop)) {
        $application = @($rule | Get-NetFirewallApplicationFilter -ErrorAction Stop)
        $service = @($rule | Get-NetFirewallServiceFilter -ErrorAction Stop)
        if ($application.Count -ne 1 -or $service.Count -ne 1) { throw '防火墙程序/服务证据不完整' }
        $program = [Environment]::ExpandEnvironmentVariables([string]$application[0].Program)
        if ($program -and $program -ne 'Any' -and [IO.Path]::GetFileName($program) -ine 'sshd.exe') { continue }
        if ($service[0].Service -and [string]$service[0].Service -notin @('Any','sshd')) { continue }
        $port = @($rule | Get-NetFirewallPortFilter -ErrorAction Stop)
        if ($port.Count -ne 1) { throw '防火墙端口证据不完整' }
        $protocol = [string]$port[0].Protocol
        if ($protocol -notin @('TCP', '6', 'Any', '256')) { continue }
        if (-not (Test-PortIncludesSSH ([string]::Join(',', @($port[0].LocalPort))))) { continue }
        $addresses = @($rule | Get-NetFirewallAddressFilter -ErrorAction Stop)
        if ($addresses.Count -ne 1) { throw '防火墙地址证据不完整' }
        $scopes = @($addresses[0].RemoteAddress)
        if ($scopes.Count -eq 1 -and $scopes[0] -in @($TailscaleRemoteAddress, $TailscaleRemoteAddressNormalized)) { continue }
        # Only conventional OpenSSH TCP-22 rules may be disabled automatically.
        # Any-protocol, range, GPO or unfamiliar rules need manual review.
        if ($rule.Name -notin @('OpenSSH-Server-In-TCP','sshd') -or $protocol -notin @('TCP','6') -or [string]$port[0].LocalPort -ne '22' -or [string]$rule.PolicyStoreSourceType -ne 'Local') {
            throw ('存在额外放行 SSH 的规则，需人工检查：' + $rule.Name)
        }
        $rule
    }
}

function Save-RecoverySnapshot {
    $files = @((Join-Path $env:ProgramData 'ssh\sshd_config'), (Join-Path $TargetProfile '.ssh\authorized_keys'), (Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'))
    $entries = @()
    foreach ($path in $files) {
        Assert-NoReparsePath $path
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $entries += [pscustomobject]@{ Path=$path; Exists=$exists; Bytes=$(if ($exists) { [IO.File]::ReadAllBytes($path) } else { @() }); Sddl=$(if ($exists) { (Get-Acl -LiteralPath $path).Sddl } else { '' }) }
    }
    $service = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction Stop
    if (-not $service) { throw '无法读取 sshd 服务原状态' }
    $unsafe = @(Get-UnsafeSshRules)
    $managed = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name 'SSH-Launchpad-OneClick-22' -ErrorAction SilentlyContinue)
    # Avoid lossy recreation of pre-existing managed rules: leave valid ones intact.
    if ($managed.Count -gt 1) { throw '托管规则不唯一' }
    if ($managed.Count -eq 1) {
        $p = @($managed | Get-NetFirewallPortFilter -ErrorAction Stop)
        $a = @($managed | Get-NetFirewallAddressFilter -ErrorAction Stop)
        if ([string]$managed[0].Enabled -ne 'True' -or [string]$managed[0].Direction -ne 'Inbound' -or [string]$managed[0].Action -ne 'Allow' -or $p.Count -ne 1 -or [string]$p[0].Protocol -ne 'TCP' -or [string]$p[0].LocalPort -ne '22' -or $a.Count -ne 1 -or @($a[0].RemoteAddress).Count -ne 1 -or @($a[0].RemoteAddress)[0] -notin @($TailscaleRemoteAddress,$TailscaleRemoteAddressNormalized)) { throw '已有托管规则发生漂移，请人工处理；不覆盖原规则' }
    }
    $snapshot = [pscustomobject]@{ Files=$entries; Running=($service.State -eq 'Running'); StartMode=$service.StartMode; UnsafeNames=@($unsafe | ForEach-Object { $_.Name }); ManagedExisted=($managed.Count -eq 1) }
    $script:RecoveryPath = Join-Path $BackupRoot ($script:SessionId + '.recovery.clixml')
    $snapshot | Export-Clixml -LiteralPath $script:RecoveryPath -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $StateRoot 'recovery-pending.txt'), $script:RecoveryPath)
    $script:Recovery = $snapshot
    Write-SetupEvent INFO '已记录配置、公钥 ACL、服务与防火墙恢复快照'
}

function Restore-RecoverySnapshot {
    if (-not $script:Recovery) { return }
    $snapshot = $script:Recovery
    # Fail loudly on any failed restore. Never claim whole-machine rollback.
    Stop-Service sshd -ErrorAction Stop
    foreach ($entry in $snapshot.Files) {
        Assert-NoReparsePath $entry.Path
        if ($entry.Exists) {
            [IO.File]::WriteAllBytes($entry.Path, [byte[]]$entry.Bytes)
            $acl = New-Object Security.AccessControl.FileSecurity
            $acl.SetSecurityDescriptorSddlForm($entry.Sddl)
            Set-Acl -LiteralPath $entry.Path -AclObject $acl
        } elseif (Test-Path -LiteralPath $entry.Path) { Remove-Item -LiteralPath $entry.Path -Force }
    }
    if (-not $snapshot.ManagedExisted) { Get-NetFirewallRule -Name 'SSH-Launchpad-OneClick-22' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction Stop }
    foreach ($name in $snapshot.UnsafeNames) { Enable-NetFirewallRule -Name $name -ErrorAction Stop }
    $startup = switch ($snapshot.StartMode) { 'Auto' {'Automatic'} 'Manual' {'Manual'} 'Disabled' {'Disabled'} default {throw '未知服务启动策略'} }
    if ($snapshot.Running) { Set-Service sshd -StartupType Manual; Start-Service sshd }
    Set-Service sshd -StartupType $startup
    Remove-Item -LiteralPath (Join-Path $StateRoot 'recovery-pending.txt') -Force -ErrorAction Stop
    Write-SetupEvent WARN ('可逆配置已恢复；已安装的软件和 Tailscale 登录不会撤销。恢复快照：' + $script:RecoveryPath)
}
