#requires -Version 5.1
param([string]$Endpoint='')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'payload/safety.ps1')
. (Join-Path $root 'payload/diagnostics.ps1')
$TailscaleAuthKey='tskey-auth-SYNTHETIC-UPLOAD-TEST'
$temp=Join-Path $env:TEMP ('Onboarder-Cloud-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try {
 $LogRoot=$temp
 $script:SessionId='cloud-smoke-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmss')
 $script:TextLog=Join-Path $temp 'setup.log'
 $script:JsonLog=Join-Path $temp 'events.jsonl'
 $script:TailscaleIP='100.73.155.36'
 function Get-TargetDesktop { $temp }
 [IO.File]::WriteAllText($script:TextLog,"BEGIN full log`r`n"+('long line 中文 '+"`r`n")*12000+"END full log $TailscaleAuthKey",[Text.Encoding]::Unicode)
 [IO.File]::WriteAllText($script:JsonLog,'{"synthetic":true}',[Text.Encoding]::UTF8)
 [IO.File]::WriteAllText((Join-Path $temp 'SSH-诊断报告.json'),'{"test":"diagnostic"}',[Text.Encoding]::UTF8)
 [IO.File]::WriteAllText((Join-Path $temp ($script:SessionId+'-openssh-msi.log')),'BEGIN MSI '+('x'*180000)+' END MSI',[Text.Encoding]::Unicode)
 [IO.File]::WriteAllText((Join-Path $temp 'SSH-连接信息.txt'),'synthetic connection', [Text.Encoding]::UTF8)
 $full=Get-FullRedactedLog $script:TextLog
 if(-not $full.StartsWith('BEGIN full log') -or -not $full.Contains('END full log') -or $full.Contains($TailscaleAuthKey)){throw 'Full log/redaction failed'}
 'PASS: entire UTF16 log converted and redacted (not tail-only)'
 if(-not $Endpoint){
  $LogEndpoints=@('https://synthetic.ts.net/events')
  function Invoke-RestMethod { throw 'simulated unavailable receiver' }
  Send-OnboardArtifacts
  $state=Get-Content (Join-Path $temp 'upload-status.json') -Raw|ConvertFrom-Json
  if(@($state.files|Where-Object uploaded).Count){throw 'Failure incorrectly counted as success'}
  if(-not (Test-Path $script:TextLog)){throw 'Local log deleted'}
  'PASS: unavailable server retains local logs and failure manifest'
 }else{
  $LogEndpoints=@($Endpoint)
  $LogEndpointAddresses=@{'ekko-chronos.tail0d8d04.ts.net'='100.84.225.38'}
  $event=@{sessionId=$script:SessionId;sequence=1;message='Synthetic Windows cloud-upload validation';level='INFO'}|ConvertTo-Json -Compress
  Invoke-LogRequest -Uri $Endpoint -Method 'POST' -Body ([Text.Encoding]::UTF8.GetBytes($event)) -ContentType 'application/json' -TimeoutSeconds 15|Out-Null
  Send-OnboardArtifacts
  $state=Get-Content (Join-Path $temp 'upload-status.json') -Raw|ConvertFrom-Json
  if($state.files.Count -ne 5 -or @($state.files|Where-Object {-not $_.uploaded}).Count){throw 'Cloud test did not upload all expected files'}
  foreach($f in $state.files){'VERIFIED '+$f.name+' '+$f.bytes+' '+$f.sha256}
  'SESSION='+$script:SessionId
  'PASS: real Windows to private HTTPS receiver, full files acknowledged by size/hash'
 }
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
