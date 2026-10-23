$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path (Join-Path $projectRoot 'task-logs') ('runner-regression-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$shellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$results = @()
foreach ($case in @('missing-current-report','generated-current-report','existing-current-report')) {
    $caseRoot = Join-Path $fixtureRoot $case
    $scriptsRoot = Join-Path $caseRoot 'scripts'
    $semesterRoot = Join-Path $caseRoot 'test-group\test-semester'
    New-Item -ItemType Directory -Path $scriptsRoot,$semesterRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'scripts\run-weekly.ps1') -Destination $scriptsRoot
    $promptName = -join ([char[]]@(0x6BCF,0x5468,0x6587,0x732E,0x6574,0x7406,0x4EFB,0x52A1))
    Set-Content -LiteralPath (Join-Path $caseRoot ($promptName + '.md')) -Value 'Fixture only.'
    $now = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, 'China Standard Time')
    $monday = $now.Date.AddDays(-(([int]$now.DayOfWeek+6)%7))
    @{group_name='test-group';semester_name='test-semester';responsible_name='test';teaching_week_1_monday=$monday.AddDays(-35).ToString('yyyy-MM-dd');topics=@(@{name='fixture'});output_root='.';feishu=@{enabled=$true}} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $caseRoot 'weekly_literature.config.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $caseRoot 'feishu.local.json') -Value '{}'
    $weekPrefix = ([string][char]0x7B2C) + '06' + [char]0x5468 + '_'
    $currentPath = Join-Path $semesterRoot ($weekPrefix + $now.ToString('yyyy-MM-dd') + '_fixture.md')
    Set-Content -LiteralPath (Join-Path $semesterRoot (([string][char]0x7B2C)+'05'+[char]0x5468+'_old.md')) -Value '# Old report'
    if ($case -eq 'existing-current-report') { Set-Content -LiteralPath $currentPath -Value '# Preserved report' }
    @'
param([string]$ReportPath)
if ([string]::IsNullOrWhiteSpace($ReportPath)) { throw 'Upload must be scoped to this week.' }
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'uploaded-path.txt'),$ReportPath)
exit 0
'@ | Set-Content -LiteralPath (Join-Path $scriptsRoot 'feishu-upload.ps1') -Encoding UTF8
    $bootstrap = @'
$ErrorActionPreference = 'Stop'
$global:fixtureRoot = $PSScriptRoot
$fixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixture.json') -Raw | ConvertFrom-Json
function global:Get-Command { param($Name,$ErrorAction) [pscustomobject]@{Source='fixture-codex.exe'} }
function global:Start-Process {
    param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,$RedirectStandardOutput,$RedirectStandardError,[switch]$Wait,[switch]$PassThru)
    Set-Content -LiteralPath (Join-Path $global:fixtureRoot 'model-started.txt') -Value 'started'
    $fixture = Get-Content -LiteralPath (Join-Path $global:fixtureRoot 'fixture.json') -Raw | ConvertFrom-Json
    if ($fixture.case -eq 'generated-current-report') { Set-Content -LiteralPath $fixture.currentPath -Value '# Generated report' }
    return [pscustomobject]@{ExitCode=0}
}
& (Join-Path $PSScriptRoot 'scripts\run-weekly.ps1')
'@
    $bootstrapPath = Join-Path $caseRoot 'bootstrap.ps1'
    [IO.File]::WriteAllText($bootstrapPath,$bootstrap,[Text.UTF8Encoding]::new($true))
    @{case=$case;currentPath=$currentPath} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $caseRoot 'fixture.json') -Encoding UTF8
    $ErrorActionPreference = 'Continue'
    $output = & $shellPath -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $bootstrapPath 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $uploadedMarker = Join-Path $caseRoot 'uploaded-path.txt'
    $uploaded = Test-Path -LiteralPath $uploadedMarker
    if ($case -eq 'missing-current-report') {
        if ($exitCode -eq 0 -or $uploaded -or ($output -join "`n") -notmatch 'Generation incomplete') { throw 'Missing current report was not rejected.' }
    } else {
        if ($exitCode -ne 0 -or -not $uploaded -or [IO.File]::ReadAllText($uploadedMarker) -ne $currentPath) { throw "Scoped upload failed for $case." }
        if ($case -eq 'existing-current-report' -and (Test-Path -LiteralPath (Join-Path $caseRoot 'model-started.txt'))) { throw 'Existing report was regenerated.' }
    }
    $results += [pscustomobject]@{Case=$case;ExitCode=$exitCode;UploadAttempted=$uploaded;Passed=$true}
}
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixtureRoot 'results.json') -Encoding UTF8
$results | Format-Table
