#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TargetUser = $env:USERNAME,
    [string]$TargetProfile = $env:USERPROFILE,
    [switch]$SelfTest,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ToolVersion = '1.0.0'
$SshPort = 22
$TailscaleRemoteAddress = '100.64.0.0/10'
$TailscaleRemoteAddressNormalized = '100.64.0.0/255.192.0.0'
$ExpectedTailnet = '__EXPECTED_TAILNET__'
$PublicKey = '__SSH_PUBLIC_KEY__'
$TailscaleAuthKey = '__TAILSCALE_AUTH_KEY__'
$OpenSshPayloadName = 'OpenSSH-Win64-v10.0.0.0.msi'
$OpenSshPayloadSHA256 = '__OPENSSH_SHA256__'
$TailscalePayloadName = 'tailscale-setup-1.102.3-amd64.msi'
$TailscalePayloadSHA256 = '__TAILSCALE_SHA256__'
$LogEndpoints = __LOG_ENDPOINTS_JSON__

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Sequence = 0
$script:CurrentStep = 'startup'
$script:ActiveEndpoint = $null
$script:UploadRetryAfter = [DateTime]::MinValue
$script:ExitCode = 1
$script:Success = $false

function Get-SafeName([string]$Value) {
    $safe = $Value -replace '[^A-Za-z0-9._-]', '-'
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'unknown' }
    return $safe
}

$safeComputer = Get-SafeName $env:COMPUTERNAME
$sessionStamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$script:SessionId = '{0}-{1}-{2}' -f $sessionStamp, $safeComputer, $PID
if ($SelfTest) {
    $StateRoot = Join-Path $env:TEMP ('SSHLaunchpad-SelfTest-{0}' -f $PID)
} else {
    $StateRoot = Join-Path $env:ProgramData 'SSHLaunchpad'
}
$LogRoot = Join-Path $StateRoot 'logs'
$BackupRoot = Join-Path $StateRoot 'backups'
$PayloadRoot = Join-Path $StateRoot 'payloads'
New-Item -ItemType Directory -Force -Path $LogRoot, $BackupRoot, $PayloadRoot | Out-Null
$script:TextLog = Join-Path $LogRoot ($script:SessionId + '.log')
$script:JsonLog = Join-Path $LogRoot ($script:SessionId + '.jsonl')
$script:UploadQueue = Join-Path $LogRoot ($script:SessionId + '.upload-queue.jsonl')

function Invoke-Upload([string]$Json) {
    $ordered = New-Object System.Collections.Generic.List[string]
    if ($script:ActiveEndpoint) { $ordered.Add($script:ActiveEndpoint) }
    foreach ($endpoint in $LogEndpoints) {
        if (-not $ordered.Contains($endpoint)) { $ordered.Add($endpoint) }
    }
    $body = $Utf8NoBom.GetBytes($Json)
    foreach ($endpoint in $ordered) {
        try {
            Invoke-RestMethod -Method Post -Uri $endpoint -ContentType 'application/json; charset=utf-8' `
                -Body $body -TimeoutSec 4 -UseBasicParsing | Out-Null
            $script:ActiveEndpoint = $endpoint
            return $true
        } catch { }
    }
    return $false
}

function Flush-UploadQueue([switch]$Force) {
    if (-not (Test-Path -LiteralPath $script:UploadQueue)) { return }
    if (-not $Force -and [DateTime]::UtcNow -lt $script:UploadRetryAfter) { return }
    $lines = @(Get-Content -LiteralPath $script:UploadQueue -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) {
        Remove-Item -LiteralPath $script:UploadQueue -Force -ErrorAction SilentlyContinue
        return
    }
    $remaining = New-Object System.Collections.Generic.List[string]
    $failed = $false
    foreach ($line in $lines) {
        if (-not $failed -and (Invoke-Upload $line)) { continue }
        $failed = $true
        $remaining.Add($line)
    }
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath $script:UploadQueue -Force -ErrorAction SilentlyContinue
        $script:UploadRetryAfter = [DateTime]::MinValue
    } else {
        [IO.File]::WriteAllLines($script:UploadQueue, [string[]]$remaining, $Utf8NoBom)
        $script:UploadRetryAfter = [DateTime]::UtcNow.AddSeconds(20)
    }
}

function Write-SetupEvent {
    param(
        [ValidateSet('DEBUG','INFO','OK','WARN','ERROR')][string]$Level,
        [string]$Message,
        [string]$Step = $script:CurrentStep
    )
    $script:Sequence++
    $now = [DateTime]::UtcNow.ToString('o')
    $line = '{0} [{1}] [{2}] {3}' -f $now, $Level, $Step, $Message
    [IO.File]::AppendAllText($script:TextLog, $line + "`r`n", $Utf8NoBom)
    $event = [ordered]@{
        sessionId = $script:SessionId
        sequence = $script:Sequence
        timestamp = $now
        level = $Level
        step = $Step
        message = $Message
        computer = $env:COMPUTERNAME
        user = $TargetUser
    }
    $json = $event | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($script:JsonLog, $json + "`r`n", $Utf8NoBom)
    $color = switch ($Level) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host ('[{0,-5}] {1}' -f $Level, $Message) -ForegroundColor $color

    Flush-UploadQueue
    if ([DateTime]::UtcNow -ge $script:UploadRetryAfter) {
        if (-not (Invoke-Upload $json)) {
            [IO.File]::AppendAllText($script:UploadQueue, $json + "`r`n", $Utf8NoBom)
            $script:UploadRetryAfter = [DateTime]::UtcNow.AddSeconds(20)
        }
    } else {
        [IO.File]::AppendAllText($script:UploadQueue, $json + "`r`n", $Utf8NoBom)
    }
}

function Set-Step([string]$Name, [string]$Title) {
    $script:CurrentStep = $Name
    Write-Host ''
    Write-Host ('========== {0} ==========' -f $Title) -ForegroundColor Cyan
    Write-SetupEvent INFO $Title
}

function Assert-Payload([string]$Path, [string]$ExpectedSHA256) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "缺少内嵌安装包：$Path"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSHA256.ToLowerInvariant()) {
        throw "安装包校验失败：$(Split-Path $Path -Leaf)，实际 SHA-256=$actual"
    }
    Write-SetupEvent OK ("安装包校验通过：{0}" -f (Split-Path $Path -Leaf))
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [Parameter(Mandatory)][string]$DisplayName,
        [int]$TimeoutSeconds = 600,
        [int[]]$SuccessCodes = @(0),
        [switch]$QuietOutput
    )
    Write-SetupEvent INFO ("开始：$DisplayName") process
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "无法启动：$DisplayName" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "$DisplayName 超时（${TimeoutSeconds}s）"
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.Result.Trim()
    $stderr = $stderrTask.Result.Trim()
    if (-not $QuietOutput) {
        foreach ($line in @($stdout -split "`r?`n" | Where-Object { $_ })) { Write-SetupEvent DEBUG $line process }
        foreach ($line in @($stderr -split "`r?`n" | Where-Object { $_ })) { Write-SetupEvent WARN $line process }
    }
    if ($SuccessCodes -notcontains $process.ExitCode) {
        $detail = if ($stderr) { $stderr } elseif ($stdout) { $stdout } else { '没有额外输出' }
        throw "$DisplayName 失败，退出码=$($process.ExitCode)：$detail"
    }
    Write-SetupEvent OK ("完成：$DisplayName（退出码=$($process.ExitCode)）") process
    return [pscustomobject]@{ ExitCode=$process.ExitCode; StdOut=$stdout; StdErr=$stderr }
}

function Get-TargetSid([string]$ProfilePath, [string]$UserName) {
    $wanted = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    foreach ($key in @(Get-ChildItem 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
        $value = (Get-ItemProperty -LiteralPath $key.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if ($value) {
            $expanded = [Environment]::ExpandEnvironmentVariables([string]$value)
            if ([IO.Path]::GetFullPath($expanded).TrimEnd('\') -ieq $wanted) {
                return New-Object System.Security.Principal.SecurityIdentifier($key.PSChildName)
            }
        }
    }
    foreach ($name in @("$env:COMPUTERNAME\$UserName", $UserName)) {
        try {
            return (New-Object System.Security.Principal.NTAccount($name)).Translate([System.Security.Principal.SecurityIdentifier])
        } catch { }
    }
    throw "无法解析目标用户 SID：$UserName ($ProfilePath)"
}

function Set-KeyFileAcl([string]$Path, [System.Security.Principal.SecurityIdentifier]$Owner, [System.Security.Principal.SecurityIdentifier[]]$Allowed) {
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetOwner($Owner)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $Allowed) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Merge-PublicKey([string]$Path, [string]$Key) {
    $dir = Split-Path $Path -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace($line) -and -not $lines.Contains($line.Trim())) {
                $lines.Add($line.Trim())
            }
        }
    }
    if (-not $lines.Contains($Key)) { $lines.Add($Key) }
    [IO.File]::WriteAllLines($Path, [string[]]$lines, [Text.Encoding]::ASCII)
}

function Get-ManagedSshConfig([string]$Existing) {
    $pattern = '(?ms)^\s*# BEGIN SSH-LAUNCHPAD-ONECLICK\s*$.*?^\s*# END SSH-LAUNCHPAD-ONECLICK\s*$(\r?\n)?'
    $clean = [regex]::Replace($Existing, $pattern, '')
    $block = @(
        '# BEGIN SSH-LAUNCHPAD-ONECLICK',
        ('Port {0}' -f $SshPort),
        'PubkeyAuthentication yes',
        'PasswordAuthentication no',
        'KbdInteractiveAuthentication no',
        'AuthorizedKeysFile .ssh/authorized_keys',
        '# END SSH-LAUNCHPAD-ONECLICK',
        ''
    ) -join "`r`n"
    return $block + $clean.TrimStart()
}

function Find-SshBinary([string]$Name) {
    $candidates = @(
        (Join-Path $env:ProgramFiles "OpenSSH\$Name"),
        (Join-Path $env:ProgramFiles "OpenSSH-Win64\$Name"),
        (Join-Path $env:SystemRoot "System32\OpenSSH\$Name")
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    return $null
}

function Find-TailscaleExe {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe')
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-TailnetIdentity($Status) {
    $current = $Status.PSObject.Properties['CurrentTailnet']
    if ($current -and $current.Value) {
        foreach ($name in @('MagicDNSSuffix', 'Name')) {
            $property = $current.Value.PSObject.Properties[$name]
            if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                return ([string]$property.Value).TrimEnd('.').ToLowerInvariant()
            }
        }
    }
    $self = $Status.PSObject.Properties['Self']
    if ($self -and $self.Value) {
        $dns = $self.Value.PSObject.Properties['DNSName']
        if ($dns -and $dns.Value) {
            $value = ([string]$dns.Value).TrimEnd('.').ToLowerInvariant()
            if ($value.EndsWith('.' + $ExpectedTailnet) -or $value -eq $ExpectedTailnet) { return $ExpectedTailnet }
        }
    }
    return ''
}

function Get-TargetDesktop {
    $currentDesktop = [Environment]::GetFolderPath('Desktop')
    if ($env:USERNAME -ieq $TargetUser -and $currentDesktop -and (Test-Path -LiteralPath $currentDesktop -PathType Container)) {
        return $currentDesktop
    }
    $profileDesktop = Join-Path $TargetProfile 'Desktop'
    if (Test-Path -LiteralPath $profileDesktop -PathType Container) { return $profileDesktop }
    return $TargetProfile
}

function Get-OpenSshInstallDecision([bool]$ServiceExists, [bool]$BinaryExists) {
    if (-not $ServiceExists) { return 'install' }
    if (-not $BinaryExists) { return 'repair' }
    return 'skip'
}

function Install-OpenSSH([string]$MsiPath) {
    Set-Step 'openssh-install' '第 2/7 步：安装或检查 OpenSSH'
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    $decision = Get-OpenSshInstallDecision ([bool]$service) ([bool](Find-SshBinary 'sshd.exe'))
    if ($decision -eq 'repair') {
        Write-SetupEvent WARN '检测到 sshd 服务但 sshd.exe 缺失（可能被杀毒软件误隔离），执行修复性重装'
        [void](Invoke-NativeProcess -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') `
            -Arguments 'delete sshd' -DisplayName '移除损坏的 sshd 服务' -TimeoutSeconds 60 -SuccessCodes @(0, 1060, 1062) -QuietOutput)
        $service = Get-Service sshd -ErrorAction SilentlyContinue
    }
    if (-not $service) {
        $msiLog = Join-Path $LogRoot ($script:SessionId + '-openssh-msi.log')
        $args = '/i "{0}" ADDLOCAL=Client,Server /qn /norestart /L*v "{1}"' -f $MsiPath, $msiLog
        [void](Invoke-NativeProcess -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
            -Arguments $args -DisplayName '安装 Microsoft Win32-OpenSSH' -TimeoutSeconds 600 -SuccessCodes @(0,1641,3010) -QuietOutput)
        $service = Get-Service sshd -ErrorAction SilentlyContinue
    } else {
        Write-SetupEvent OK '检测到 sshd 服务与 sshd.exe，跳过重复安装'
    }

    if (-not $service) {
        $installScript = @(
            (Join-Path $env:ProgramFiles 'OpenSSH\install-sshd.ps1'),
            (Join-Path $env:ProgramFiles 'OpenSSH-Win64\install-sshd.ps1')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($installScript) {
            [void](Invoke-NativeProcess -FilePath 'powershell.exe' `
                -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $installScript) `
                -DisplayName '注册 sshd 服务' -TimeoutSeconds 120)
            $service = Get-Service sshd -ErrorAction SilentlyContinue
        }
    }
    if (-not $service) { throw 'OpenSSH 安装结束后仍未找到 sshd 服务' }
    if (-not (Find-SshBinary 'sshd.exe')) { throw 'OpenSSH 安装结束后仍未找到 sshd.exe' }
    Write-SetupEvent OK 'OpenSSH 服务可用'
}

function Configure-OpenSSH {
    Set-Step 'openssh-config' '第 3/7 步：写入公钥并配置 OpenSSH'
    $sshd = Find-SshBinary 'sshd.exe'
    $sshKeygen = Find-SshBinary 'ssh-keygen.exe'
    if (-not $sshd -or -not $sshKeygen) { throw '找不到 OpenSSH 核心程序 sshd.exe / ssh-keygen.exe' }

    [void](Invoke-NativeProcess -FilePath $sshKeygen -Arguments '-A' -DisplayName '生成缺失的 SSH 主机密钥' -TimeoutSeconds 60 -QuietOutput)

    $targetSid = Get-TargetSid $TargetProfile $TargetUser
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $userKeys = Join-Path $TargetProfile '.ssh\authorized_keys'
    $adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    Merge-PublicKey $userKeys $PublicKey
    Merge-PublicKey $adminKeys $PublicKey
    Set-KeyFileAcl $userKeys $targetSid @($targetSid, $systemSid, $adminsSid)
    Set-KeyFileAcl $adminKeys $adminsSid @($systemSid, $adminsSid)
    Write-SetupEvent OK ("公钥已写入目标用户：$TargetUser")

    $configDir = Join-Path $env:ProgramData 'ssh'
    $configPath = Join-Path $configDir 'sshd_config'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    if (-not (Test-Path -LiteralPath $configPath)) {
        $defaultConfig = @(
            (Join-Path (Split-Path $sshd -Parent) 'sshd_config_default'),
            (Join-Path $env:SystemRoot 'System32\OpenSSH\sshd_config_default')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($defaultConfig) {
            Copy-Item -LiteralPath $defaultConfig -Destination $configPath
        } else {
            [IO.File]::WriteAllText($configPath, "Subsystem sftp sftp-server.exe`r`n", [Text.Encoding]::ASCII)
        }
    }
    $backupPath = Join-Path $BackupRoot ('sshd_config-{0}.bak' -f $script:SessionId)
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    $existing = [IO.File]::ReadAllText($configPath)
    $updated = Get-ManagedSshConfig $existing
    [IO.File]::WriteAllText($configPath, $updated, [Text.Encoding]::ASCII)

    try {
        [void](Invoke-NativeProcess -FilePath $sshd -Arguments ('-t -f "{0}"' -f $configPath) `
            -DisplayName '验证 sshd_config' -TimeoutSeconds 30 -QuietOutput)
    } catch {
        Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
        throw "sshd_config 验证失败，已恢复原配置：$($_.Exception.Message)"
    }

    try {
        Set-Service sshd -StartupType Automatic
        $service = Get-Service sshd
        if ($service.Status -eq 'Running') { Restart-Service sshd -Force } else { Start-Service sshd }
        $service = Get-Service sshd
        if ($service.Status -ne 'Running') { throw "sshd 当前状态=$($service.Status)" }
    } catch {
        Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
        try { Start-Service sshd -ErrorAction SilentlyContinue } catch { }
        throw "重启 sshd 失败，已恢复原配置：$($_.Exception.Message)"
    }
    Write-SetupEvent OK 'OpenSSH 配置有效，sshd 已启动并设为开机自启'
}

function Configure-Firewall {
    Set-Step 'firewall' '第 4/7 步：配置 Windows 防火墙'
    $ruleName = 'SSH-Launchpad-OneClick-22'
    Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $ruleName -DisplayName 'SSH Launchpad OneClick (TCP 22, Tailscale only)' `
        -Enabled True -Direction Inbound -Protocol TCP -LocalPort $SshPort `
        -RemoteAddress $TailscaleRemoteAddress -Action Allow -Profile Any | Out-Null
    Write-SetupEvent OK ("TCP 22 仅允许 Tailscale 地址范围：$TailscaleRemoteAddress")
}

function Install-Tailscale([string]$MsiPath) {
    Set-Step 'tailscale-install' '第 5/7 步：安装或检查 Tailscale'
    $tailscale = Find-TailscaleExe
    if (-not $tailscale) {
        $msiLog = Join-Path $LogRoot ($script:SessionId + '-tailscale-msi.log')
        $args = '/i "{0}" /qn /norestart /L*v "{1}" TS_ALLOWINCOMINGCONNECTIONS=always' -f $MsiPath, $msiLog
        [void](Invoke-NativeProcess -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
            -Arguments $args -DisplayName '安装 Tailscale' -TimeoutSeconds 600 -SuccessCodes @(0,1641,3010) -QuietOutput)
        for ($i = 0; $i -lt 30 -and -not $tailscale; $i++) {
            Start-Sleep -Seconds 2
            $tailscale = Find-TailscaleExe
        }
    } else {
        Write-SetupEvent OK '检测到 Tailscale，跳过重复安装'
    }
    if (-not $tailscale) { throw 'Tailscale 安装结束后仍找不到 tailscale.exe；请重启 Windows 后重新运行本工具' }
    $service = Get-Service Tailscale -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Running') { Start-Service Tailscale }
    Write-SetupEvent OK 'Tailscale 程序可用'
    return $tailscale
}

function Connect-Tailscale([string]$TailscaleExe) {
    Set-Step 'tailscale-connect' '第 6/7 步：接入 Tailscale 网络'
    $state = $null
    try {
        $statusResult = Invoke-NativeProcess -FilePath $TailscaleExe -Arguments 'status --json' `
            -DisplayName '读取 Tailscale 状态' -TimeoutSeconds 30 -SuccessCodes @(0,1) -QuietOutput
        if ($statusResult.StdOut) {
            $status = $statusResult.StdOut | ConvertFrom-Json
            $state = $status.BackendState
        }
    } catch {
        Write-SetupEvent WARN ("首次状态读取失败，将继续尝试登录：$($_.Exception.Message)")
    }

    $currentTailnet = if ($state -eq 'Running') { Get-TailnetIdentity $status } else { '' }
    if ($state -eq 'Running' -and $currentTailnet -eq $ExpectedTailnet) {
        Write-SetupEvent OK ("设备已在目标 Tailnet 在线：$ExpectedTailnet，跳过重复登录")
    } else {
        if ($state -eq 'Running') {
            Write-SetupEvent WARN ("当前 Tailnet '$currentTailnet' 不是目标 '$ExpectedTailnet'，将重新认证")
        }
        $arguments = 'up --reset --force-reauth --auth-key={0} --hostname={1} --timeout=120s' -f $TailscaleAuthKey, $safeComputer
        [void](Invoke-NativeProcess -FilePath $TailscaleExe -Arguments $arguments `
            -DisplayName '使用内置一次性密钥接入目标 Tailnet（密钥不写入日志）' -TimeoutSeconds 180 -QuietOutput)
    }

    $statusResult = Invoke-NativeProcess -FilePath $TailscaleExe -Arguments 'status --json' `
        -DisplayName '确认 Tailscale 在线状态' -TimeoutSeconds 30 -QuietOutput
    $status = $statusResult.StdOut | ConvertFrom-Json
    if ($status.BackendState -ne 'Running') { throw "Tailscale 未在线：BackendState=$($status.BackendState)" }
    $confirmedTailnet = Get-TailnetIdentity $status
    if ($confirmedTailnet -ne $ExpectedTailnet) { throw "已在线但 Tailnet 不匹配：当前='$confirmedTailnet'，目标='$ExpectedTailnet'" }
    $ipResult = Invoke-NativeProcess -FilePath $TailscaleExe -Arguments 'ip -4' `
        -DisplayName '读取 Tailscale IPv4' -TimeoutSeconds 30 -QuietOutput
    $ip = @($ipResult.StdOut -split "`r?`n" | Where-Object { $_ -match '^100\.' }) | Select-Object -First 1
    if (-not $ip) { throw 'Tailscale 已在线，但未取得 100.x IPv4 地址' }
    Write-SetupEvent OK ("Tailscale 在线：$ip")
    return $ip
}

function Verify-Result([string]$TailscaleIP) {
    Set-Step 'verify' '第 7/7 步：最终验证'
    $service = Get-Service sshd -ErrorAction Stop
    if ($service.Status -ne 'Running') { throw "sshd 未运行：$($service.Status)" }
    $listening = Get-NetTCPConnection -State Listen -LocalPort $SshPort -ErrorAction SilentlyContinue
    if (-not $listening) {
        $probe = Test-NetConnection -ComputerName 127.0.0.1 -Port $SshPort -InformationLevel Quiet -WarningAction SilentlyContinue
        if (-not $probe) { throw "本机 TCP $SshPort 未监听" }
    }
    $userKeys = Join-Path $TargetProfile '.ssh\authorized_keys'
    if (-not (Select-String -LiteralPath $userKeys -SimpleMatch $PublicKey -Quiet)) { throw '最终检查发现目标用户公钥缺失' }
    $firewallRule = Get-NetFirewallRule -Name 'SSH-Launchpad-OneClick-22' -ErrorAction SilentlyContinue
    $firewallPort = $firewallRule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    $firewallAddress = $firewallRule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
    $firewallRemoteAddresses = @($firewallAddress.RemoteAddress)
    $firewallScopeValid = $firewallRemoteAddresses.Count -eq 1 -and
        $firewallRemoteAddresses[0] -in @($TailscaleRemoteAddress, $TailscaleRemoteAddressNormalized)
    if (-not $firewallRule -or [string]$firewallPort.Protocol -ne 'TCP' -or
        [string]$firewallPort.LocalPort -ne [string]$SshPort -or -not $firewallScopeValid) {
        throw "最终检查发现 TCP $SshPort 防火墙规则未限制到 $TailscaleRemoteAddress"
    }
    Write-SetupEvent OK 'sshd 正在监听、公钥存在、防火墙仅限 Tailscale、Tailscale 在线'

    $sshCommand = 'ssh {0}@{1}' -f $TargetUser, $TailscaleIP
    $result = @(
        'SSH Launchpad 一键接入成功',
        ('时间：{0}' -f (Get-Date)),
        ('目标用户名：{0}' -f $TargetUser),
        ('主机名：{0}' -f $env:COMPUTERNAME),
        ('Tailscale IP：{0}' -f $TailscaleIP),
        ('连接命令：{0}' -f $sshCommand),
        ('本机日志：{0}' -f $script:TextLog),
        ('会话编号：{0}' -f $script:SessionId)
    ) -join "`r`n"
    $desktop = Get-TargetDesktop
    $resultPath = Join-Path $desktop 'SSH-连接信息.txt'
    [IO.File]::WriteAllText($resultPath, $result + "`r`n", (New-Object Text.UTF8Encoding($true)))
    Copy-Item -LiteralPath $script:TextLog -Destination (Join-Path $desktop 'SSH-安装日志.log') -Force
    Write-SetupEvent OK ("连接信息已保存到桌面：$resultPath")
    Write-Host ''
    Write-Host '==================== 完成 ====================' -ForegroundColor Green
    Write-Host ('Tailscale IP : {0}' -f $TailscaleIP) -ForegroundColor Green
    Write-Host ('Windows 用户 : {0}' -f $TargetUser) -ForegroundColor Green
    Write-Host ('连接命令      : {0}' -f $sshCommand) -ForegroundColor Yellow
    Write-Host '把「SSH-连接信息.txt」发回给 Shallow 即可。' -ForegroundColor Cyan
}

function Invoke-SelfTest {
    Set-Step 'selftest' '自检：脚本、安装包、日志链路'
    $sourceOpenSsh = Join-Path $PSScriptRoot $OpenSshPayloadName
    $sourceTailscale = Join-Path $PSScriptRoot $TailscalePayloadName
    Assert-Payload $sourceOpenSsh $OpenSshPayloadSHA256
    Assert-Payload $sourceTailscale $TailscalePayloadSHA256

    $sample = "# comment`r`n# BEGIN SSH-LAUNCHPAD-ONECLICK`r`nPort 99`r`n# END SSH-LAUNCHPAD-ONECLICK`r`nMatch Group administrators`r`n  AuthorizedKeysFile old"
    $rendered = Get-ManagedSshConfig $sample
    if (($rendered -split '# BEGIN SSH-LAUNCHPAD-ONECLICK').Count -ne 2) { throw '托管配置块未保持单例' }
    if ($rendered.IndexOf('# BEGIN SSH-LAUNCHPAD-ONECLICK') -gt $rendered.IndexOf('Match Group')) { throw '托管配置块未位于 Match 之前' }
    if ($rendered -notmatch '(?m)^PasswordAuthentication no\r?$') { throw '未关闭 SSH 密码认证' }
    if ($rendered -notmatch '(?m)^KbdInteractiveAuthentication no\r?$') { throw '未关闭 SSH 键盘交互认证' }
    if ($TailscaleRemoteAddress -ne '100.64.0.0/10') { throw 'Tailscale 防火墙范围自检失败' }
    if ((Get-OpenSshInstallDecision $false $false) -ne 'install') { throw '自检失败：缺少服务时应选择全新安装' }
    if ((Get-OpenSshInstallDecision $true $false) -ne 'repair') { throw '自检失败：服务在但 sshd.exe 缺失时应选择修复重装' }
    if ((Get-OpenSshInstallDecision $true $true) -ne 'skip') { throw '自检失败：服务与程序齐全时应跳过安装' }
    $fakeTailnet = ('{"BackendState":"Running","CurrentTailnet":{"MagicDNSSuffix":"' + $ExpectedTailnet + '"}}') | ConvertFrom-Json
    if ((Get-TailnetIdentity $fakeTailnet) -ne $ExpectedTailnet) { throw '目标 Tailnet 识别自检失败' }

    $keyPath = Join-Path $StateRoot '.ssh\authorized_keys'
    Merge-PublicKey $keyPath $PublicKey
    Merge-PublicKey $keyPath $PublicKey
    $keyMatches = @(Get-Content $keyPath | Where-Object { $_ -eq $PublicKey }).Count
    if ($keyMatches -ne 1) { throw '公钥幂等写入检查失败' }
    $testSid = Get-TargetSid $env:USERPROFILE $env:USERNAME
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    Set-KeyFileAcl $keyPath $testSid @($testSid, $systemSid, $adminsSid)
    if (-not (Get-Acl -LiteralPath $keyPath).AreAccessRulesProtected) { throw '公钥 ACL 继承未关闭' }
    Write-SetupEvent OK '公钥幂等写入与 Windows ACL 自检通过'

    [void](Invoke-NativeProcess -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
        -Arguments '/d /c echo native-process-ok' -DisplayName '原生命令包装器自检' -TimeoutSeconds 10)
    Flush-UploadQueue -Force
    Write-SetupEvent OK ("SELFTEST_SESSION=$($script:SessionId)")
    if ($LogEndpoints.Count -gt 0) {
        if (-not $script:ActiveEndpoint) { throw '日志上传端点均不可达' }
        Write-SetupEvent OK ("实时日志已上传到：$($script:ActiveEndpoint)")
    } else {
        Write-SetupEvent OK '未配置远程日志端点，跳过远程上传自检'
    }
}

try {
    Clear-Host
    Write-Host 'SSH + Tailscale 一键接入工具' -ForegroundColor Cyan
    Write-Host ('版本 {0}，会话 {1}' -f $ToolVersion, $script:SessionId) -ForegroundColor DarkGray
    Write-SetupEvent INFO ("程序启动；目标用户=$TargetUser；目标目录=$TargetProfile")

    if ($SelfTest) {
        Invoke-SelfTest
        $script:Success = $true
        $script:ExitCode = 0
    } else {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw '没有管理员权限；请重新双击安装包并同意 UAC 提权'
        }

        Set-Step 'preflight' '第 1/7 步：环境与安装包预检'
        if (-not [Environment]::Is64BitOperatingSystem) { throw '该安装包仅支持 Windows x64' }
        if ([Environment]::OSVersion.Version.Major -lt 10) { throw '需要 Windows 10 / Windows Server 2016 或更新版本' }
        if (-not (Test-Path -LiteralPath $TargetProfile -PathType Container)) { throw "目标用户目录不存在：$TargetProfile" }
        $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        if (-not $systemDrive -or $systemDrive.FreeSpace -lt 500MB) {
            $freeMB = if ($systemDrive) { [math]::Round($systemDrive.FreeSpace / 1MB) } else { 0 }
            throw "C 盘空间不足：当前约 ${freeMB}MB，至少需要 500MB"
        }
        Write-SetupEvent OK ("环境预检通过：Windows x64；C 盘剩余约 {0}MB" -f [math]::Round($systemDrive.FreeSpace / 1MB))

        $sourceOpenSsh = Join-Path $PSScriptRoot $OpenSshPayloadName
        $sourceTailscale = Join-Path $PSScriptRoot $TailscalePayloadName
        Assert-Payload $sourceOpenSsh $OpenSshPayloadSHA256
        Assert-Payload $sourceTailscale $TailscalePayloadSHA256
        $openSshMsi = Join-Path $PayloadRoot $OpenSshPayloadName
        $tailscaleMsi = Join-Path $PayloadRoot $TailscalePayloadName
        Copy-Item -LiteralPath $sourceOpenSsh -Destination $openSshMsi -Force
        Copy-Item -LiteralPath $sourceTailscale -Destination $tailscaleMsi -Force
        Assert-Payload $openSshMsi $OpenSshPayloadSHA256
        Assert-Payload $tailscaleMsi $TailscalePayloadSHA256

        Install-OpenSSH $openSshMsi
        Configure-OpenSSH
        Configure-Firewall
        $tailscale = Install-Tailscale $tailscaleMsi
        $tailscaleIP = Connect-Tailscale $tailscale
        Verify-Result $tailscaleIP
        $script:Success = $true
        $script:ExitCode = 0
        Remove-Item -LiteralPath $PayloadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    try { Write-SetupEvent ERROR $_.Exception.Message } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    Write-Host ''
    Write-Host '执行失败。可直接重新运行，本工具会从实际系统状态继续。' -ForegroundColor Red
    Write-Host ('日志位置：{0}' -f $script:TextLog) -ForegroundColor Yellow
    Write-Host ('会话编号：{0}' -f $script:SessionId) -ForegroundColor Yellow
    $script:ExitCode = 1
} finally {
    try { Flush-UploadQueue -Force } catch { }
    if (-not $SelfTest) {
        try {
            $desktop = Get-TargetDesktop
            if ($desktop -and (Test-Path -LiteralPath $script:TextLog)) {
                Copy-Item -LiteralPath $script:TextLog -Destination (Join-Path $desktop 'SSH-安装日志.log') -Force
            }
        } catch { }
    }
    if (-not $NoPause) {
        Write-Host ''
        Read-Host '按回车键关闭窗口' | Out-Null
    }
}

exit $script:ExitCode
