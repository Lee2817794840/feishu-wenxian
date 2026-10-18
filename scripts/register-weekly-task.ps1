param([switch]$Preview)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot 'weekly_literature.config.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($config.schedule.timezone -ne 'Asia/Shanghai' -or [TimeZoneInfo]::Local.Id -ne 'China Standard Time') {
    throw 'This registration script requires Asia/Shanghai and Windows China Standard Time.'
}
if ($config.schedule.weekday -ne 'FRIDAY' -or $config.schedule.time -ne '09:00') { throw 'Expected the agreed Friday 09:00 schedule.' }
$runner = Join-Path $PSScriptRoot 'run-weekly.ps1'
& $runner -CheckOnly
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Runner validation failed.' }
$taskName = $config.schedule.task_name
if ($taskName -ne 'Codex-Weekly-Literature-ZhinengSheji') { throw 'Unexpected task name.' }
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $runner + '"'
$action = New-ScheduledTaskAction -Execute $powershellPath -Argument $arguments -WorkingDirectory $projectRoot
$trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek Friday -At '09:00'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)
$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Weekly literature report. Friday 09:00 Asia/Shanghai. Workspace write, current signed-in Codex user. No Feishu upload.'
if ($Preview) {
    $task | Select-Object @{Name='TaskName';Expression={$taskName}},Actions,Triggers,Principal,Settings
    exit 0
}
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) { throw "A task with this name already exists. Inspect it before updating: $taskName" }
Register-ScheduledTask -TaskName $taskName -InputObject $task | Out-Null
$saved = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName
if ($saved.State -eq 'Disabled') { throw 'Registered task is disabled.' }
$config.schedule.status = 'registered'
$config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding UTF8
[pscustomobject]@{TaskName=$taskName; State=$saved.State; NextRun=$info.NextRunTime; TimeZone=[TimeZoneInfo]::Local.Id}
