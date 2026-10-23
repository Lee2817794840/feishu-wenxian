param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $projectRoot 'weekly_literature.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($field in @('group_name', 'semester_name', 'responsible_name', 'teaching_week_1_monday')) {
    if ([string]::IsNullOrWhiteSpace($config.$field)) { throw "Missing config: $field" }
}
foreach ($field in @('group_name', 'semester_name')) {
    if ($config.$field -match '[<>:"/\\|?*]' -or $config.$field -in @('.', '..')) { throw "Invalid directory name: $field" }
}
if ($config.topics.Count -eq 0) { throw 'No research topics configured.' }
$weekOne = [datetime]::ParseExact($config.teaching_week_1_monday, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
if ($weekOne.DayOfWeek -ne [DayOfWeek]::Monday) { throw 'Teaching week 1 must begin on Monday.' }
$now = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, 'China Standard Time')
if ($now.Date -lt $weekOne.Date) { throw 'The semester has not started.' }
if ($config.semester_end_date -and $now.Date -gt [datetime]::ParseExact($config.semester_end_date, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)) {
    Write-Output 'Semester finished. Update config before running again.'
    exit 0
}
$codexCommand = Get-Command codex.exe -ErrorAction SilentlyContinue
if ($codexCommand) {
    $codexPath = $codexCommand.Source
} else {
    $installRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.vscode\extensions'
    $codexPath = Get-ChildItem -Path (Join-Path $installRoot 'openai.chatgpt-*\bin\windows-x86_64\codex.exe') -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $codexPath) { throw 'Codex CLI not found. Install or enable the Codex extension.' }
$relativePrompt = -join ([char[]]@(0x6BCF,0x5468,0x6587,0x732E,0x6574,0x7406,0x4EFB,0x52A1))
$promptPath = Join-Path $projectRoot ($relativePrompt + '.md')
if (-not (Test-Path -LiteralPath $promptPath)) { throw 'Weekly prompt is missing.' }
$monday = $now.Date.AddDays(-(([int]$now.DayOfWeek + 6) % 7))
$week = [int](($monday - $weekOne.Date).TotalDays / 7) + 1
if ($CheckOnly) {
    [pscustomobject]@{Codex=$codexPath; Week=$week; Date=$now.ToString('yyyy-MM-dd'); Group=$config.group_name; Semester=$config.semester_name}
    exit 0
}
# An enabled upload must fail visibly if credentials are missing.
$feishuEnabled = $config.feishu.enabled -eq $true
if ($feishuEnabled -and -not (Test-Path -LiteralPath (Join-Path $projectRoot 'feishu.local.json'))) {
    throw 'Feishu upload is enabled but feishu.local.json is missing.'
}
$outputRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot $config.output_root))
if ($outputRoot -ne $projectRoot -and -not $outputRoot.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Output root must stay inside this project.' }
$semesterRoot = Join-Path (Join-Path $outputRoot $config.group_name) $config.semester_name
$weekPrefix = ([string][char]0x7B2C) + ('{0:D2}' -f $week) + [char]0x5468 + '_'
if (Test-Path -LiteralPath $semesterRoot) {
    $existingReport = Get-ChildItem -LiteralPath $semesterRoot -File -Filter ($weekPrefix + '*.md') | Select-Object -First 1
    if ($existingReport) {
        Write-Output ('Report already exists; preserved: ' + $existingReport.FullName)
        # Even when local generation is skipped, retry pending Feishu uploads so a missed upload is not lost.
        if ($feishuEnabled) {
            & (Join-Path $PSScriptRoot 'feishu-upload.ps1') -ReportPath $existingReport.FullName
            if ($LASTEXITCODE -ne 0) {
                Write-Output ("Feishu upload failed (exit $LASTEXITCODE). Local report preserved; upload will be retried on next run.")
                exit $LASTEXITCODE
            }
        }
        exit 0
    }
}
$logRoot = Join-Path $projectRoot 'task-logs'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$stamp = $now.ToString('yyyy-MM-dd_HHmmss')
$stdoutPath = Join-Path $logRoot ($stamp + '.jsonl')
$stderrPath = Join-Path $logRoot ($stamp + '.stderr.log')
$summaryPath = Join-Path $logRoot ($stamp + '.summary.md')
$runPrompt = "Read and follow '$relativePrompt.md' and weekly_literature.config.json. Today's archive date is $($now.ToString('yyyy-MM-dd')) in Asia/Shanghai, teaching week $week. Complete the local literature report using live web search and verified primary sources. Read existing semester reports to avoid duplicates. Save actual files, preserve human edits, and clearly report incomplete searches. Do not upload to Feishu, change permissions or configure any scheduler."
# Auto-review keeps workspace-write boundaries without an interactive approval dialog.
$arguments = @('--search', 'exec', '--approve-for-me', '--skip-git-repo-check', '--cd', ('"' + $projectRoot + '"'), '--color', 'never', '--json', '--output-last-message', ('"' + $summaryPath + '"'), ('"' + $runPrompt + '"'))
$process = Start-Process -FilePath $codexPath -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Codex failed (exit $($process.ExitCode)). See $stderrPath" }
$generatedReports = @(Get-ChildItem -LiteralPath $semesterRoot -File -Filter ($weekPrefix + '*.md') -ErrorAction SilentlyContinue)
if ($generatedReports.Count -ne 1 -or $generatedReports[0].Length -eq 0) {
    throw "Generation incomplete: expected one nonempty teaching-week $week report. No upload attempted. See $summaryPath"
}
Write-Output "Completed. Summary: $summaryPath"
# Upload only the verified current-week artifact, never count an older report as this week's success.
if ($feishuEnabled) {
    & (Join-Path $PSScriptRoot 'feishu-upload.ps1') -ReportPath $generatedReports[0].FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Output ("Feishu upload failed (exit $LASTEXITCODE). Local report preserved; upload will be retried on next run.")
        exit $LASTEXITCODE
    }
}
