#requires -Version 5.1
<#
.SYNOPSIS
    将本地每周文献整理报告上传为飞书新版可编辑云文档（docx）。

.DESCRIPTION
    流程：获取 tenant_access_token -> 核验/解析 小组/学期 目录（缺失则创建）-> 检查云端是否
    已存在同周文档 -> 创建云文档 -> Markdown 转换 -> 创建嵌套块写入 -> 回读核验内容与父目录 ->
    记录文档 ID 与链接（运行记录/feishu_uploads.json）。

    - 默认扫描本地学期目录下所有 第*周_*.md，逐篇补传云端缺失的周报（幂等、可重试）。
    - 指定 -ReportPath 时只处理该篇。
    - -CheckOnly 为连接验证模式：取 token、解析并核验目录、只读检查，不创建文档。
    - 失败保留本地周报并记录原因（运行记录/feishu_upload_<时间>_<状态>.md），下次运行仅重试未完成的上传。

.NOTES
    依赖：weekly_literature.config.json（feishu.workspace_folder_token / group_name / semester_name）
    与 feishu.local.json（真实 App ID / App Secret，勿外发）。
    权限：需为应用开通云文档“创建及编辑新版文档”“文本内容转换为云文档块”以及云空间
    “查看、评论、编辑和管理云空间中所有文件”等接口权限，并将应用授权到目标文件夹。
#>
param(
    [string]$ReportPath = '',
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot 'weekly_literature.config.json'
$credPath   = Join-Path $projectRoot 'feishu.local.json'
$logDir     = Join-Path $projectRoot '运行记录'
$statePath  = Join-Path $logDir 'feishu_uploads.json'

# ---------- 日志 ----------
$script:logLines = [System.Collections.Generic.List[string]]::new()
function Write-Log {
    param([string]$Message)
    $script:logLines.Add($Message)
    Write-Output $Message
}
function Get-ChinaNow {
    return [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, 'China Standard Time')
}
function Save-Log {
    param([string]$Status)
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $stamp = (Get-ChinaNow).ToString('yyyy-MM-dd_HHmmss')
        $logPath = Join-Path $logDir ("feishu_upload_" + $stamp + "_" + $Status + ".md")
        [IO.File]::WriteAllLines($logPath, $script:logLines, [Text.UTF8Encoding]::new($false))
    } catch {
        Write-Output ('WARN: 无法写入上传日志: ' + $_.Exception.Message)
    }
}

# ---------- 配置与凭据 ----------
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Output "FEISHU_UPLOAD_ERROR: 缺少 $configPath"
    exit 1
}
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($config.group_name) -or [string]::IsNullOrWhiteSpace($config.semester_name)) {
    Write-Output 'FEISHU_UPLOAD_ERROR: 配置缺失 group_name 或 semester_name。'
    exit 1
}
if (-not (Test-Path -LiteralPath $credPath)) {
    Write-Output 'FEISHU_UPLOAD_SKIP: 未找到 feishu.local.json（尚未配置应用凭据）。创建应用、授权目录、保存凭据的步骤见 飞书接入指引.md。'
    exit 1
}
$cred = Get-Content -LiteralPath $credPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($cred.app_id) -or [string]::IsNullOrWhiteSpace($cred.app_secret) -or $cred.app_id -match 'App ID|在本机填写' -or $cred.app_secret -match 'App Secret|在本机填写') {
    Write-Output 'FEISHU_UPLOAD_ERROR: feishu.local.json 仍是占位符。请用真实 App ID / App Secret 替换（见 飞书接入指引.md 第4节），不要外发该文件。'
    exit 1
}

# ---------- HTTP 工具 ----------
function Invoke-Feishu {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        $BodyObj,
        [string]$Token,
        [int]$MaxRetries = 3
    )
    $headers = @{}
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $params = @{ Uri = $Url; Method = $Method; Headers = $headers; ContentType = 'application/json; charset=utf-8' }
            if ($null -ne $BodyObj) {
                $json = $BodyObj | ConvertTo-Json -Depth 30 -Compress
                $params['Body'] = [Text.Encoding]::UTF8.GetBytes($json)
            }
            $resp = Invoke-RestMethod @params
            if ($resp.code -ne 0) {
                if ($resp.code -in @(99991400, 99991401, 99991402)) { Start-Sleep -Seconds (2 * $attempt); continue }
                throw "Feishu API error (code=$($resp.code)): $($resp.msg)"
            }
            return $resp
        } catch [System.Net.WebException] {
            $errBody = ''
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) { $reader = New-Object IO.StreamReader($stream); $errBody = $reader.ReadToEnd() }
            } catch { }
            if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds (2 * $attempt); continue }
            throw "Feishu HTTP error: $($_.Exception.Message) | response: $errBody | $Method $Url"
        } catch {
            if ($attempt -lt $MaxRetries -and $_.Exception.Message -match 'timed out|Timeout|429') { Start-Sleep -Seconds (2 * $attempt); continue }
            throw
        }
    }
    throw 'Feishu API retry limit reached.'
}

# ---------- 接口封装 ----------
function Get-TenantAccessToken {
    param([string]$AppId, [string]$AppSecret)
    $body = @{ app_id = $AppId; app_secret = $AppSecret }
    $json = $body | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $resp = Invoke-RestMethod -Method Post -Uri 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal' -ContentType 'application/json; charset=utf-8' -Body $bytes -ErrorAction Stop
    if ($resp.code -ne 0) { throw "获取 tenant_access_token 失败 (code=$($resp.code)): $($resp.msg) — 请核对 feishu.local.json 中的 App ID / App Secret。" }
    if ([string]::IsNullOrWhiteSpace($resp.tenant_access_token)) { throw '获取 tenant_access_token 失败：响应缺少 token。' }
    return $resp.tenant_access_token
}

function Get-FolderChildren {
    param([string]$FolderToken, [string]$Token)
    $all = @()
    $pageToken = ''
    do {
        $url = 'https://open.feishu.cn/open-apis/drive/v1/files?folder_token=' + $FolderToken + '&page_size=200'
        if ($pageToken) { $url += '&page_token=' + [uri]::EscapeDataString($pageToken) }
        $resp = Invoke-Feishu -Method Get -Url $url -Token $Token
        $all += @($resp.data.files)
        $pageToken = $resp.data.next_page_token
        $hasMore = $resp.data.has_more
    } while ($hasMore -and $pageToken)
    return $all
}

function New-FeishuFolder {
    param([string]$Name, [string]$ParentToken, [string]$Token)
    $body = @{ name = $Name; folder_token = $ParentToken }
    $resp = Invoke-Feishu -Method Post -Url 'https://open.feishu.cn/open-apis/drive/v1/files/create_folder' -BodyObj $body -Token $Token
    if (-not $resp.data.folder -or [string]::IsNullOrWhiteSpace($resp.data.folder.token)) { throw '创建文件夹失败：响应缺少 folder.token。' }
    return $resp.data.folder
}

function Resolve-SemesterFolder {
    param([string]$Token)
    if (-not [string]::IsNullOrWhiteSpace($config.feishu.target_folder_token)) {
        # The user supplied the final semester folder; never create a duplicate child.
        $null = @(Get-FolderChildren -FolderToken $config.feishu.target_folder_token -Token $Token)
        return [pscustomobject]@{
            token = $config.feishu.target_folder_token
            name = $config.semester_name
            url = $config.feishu.target_folder_url
        }
    }
    if ($CheckOnly) { throw 'CheckOnly requires an explicit target_folder_token and never creates folders.' }
    $wsToken = $config.feishu.workspace_folder_token
    $groupName = $config.group_name
    $semesterName = $config.semester_name
    if ([string]::IsNullOrWhiteSpace($wsToken)) { throw '配置缺失：feishu.workspace_folder_token（工作区文件夹 token，来自共享文件夹链接）。' }
    $wsChildren = @(Get-FolderChildren -FolderToken $wsToken -Token $Token)
    $semester = $wsChildren | Where-Object { $_.type -eq 'folder' -and $_.name -eq $semesterName } | Select-Object -First 1
    if (-not $semester) {
        $group = $wsChildren | Where-Object { $_.type -eq 'folder' -and $_.name -eq $groupName } | Select-Object -First 1
        if ($group) {
            $groupChildren = @(Get-FolderChildren -FolderToken $group.token -Token $Token)
            $semester = $groupChildren | Where-Object { $_.type -eq 'folder' -and $_.name -eq $semesterName } | Select-Object -First 1
            if (-not $semester) {
                Write-Log ("FEISHU_FOLDER: 小组目录 {0} 下未找到 {1}，由应用创建…" -f $groupName, $semesterName)
                $semester = New-FeishuFolder -Name $semesterName -ParentToken $group.token -Token $Token
            }
        } else {
            Write-Log ("FEISHU_FOLDER: 工作区下未找到小组目录 {0}，将工作区视为小组目录，创建学期目录 {1}…" -f $groupName, $semesterName)
            $semester = New-FeishuFolder -Name $semesterName -ParentToken $wsToken -Token $Token
        }
    }
    return $semester
}

function Update-FeishuConfig {
    param([string]$TargetToken)
    if ($config.feishu.target_folder_token -eq $TargetToken) { return }
    $config.feishu.target_folder_token = $TargetToken
    $config.feishu.status = 'folder_resolved_and_verified'
    $json = $config | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($configPath, $json, [Text.UTF8Encoding]::new($false))
    Write-Log ("FEISHU_CONFIG: 已将学期目录 token 写入配置 feishu.target_folder_token={0}" -f $TargetToken)
}

function Convert-MarkdownToBlocks {
    param([string]$Content, [string]$Token)
    $body = @{ content_type = 'markdown'; content = $Content }
    $resp = Invoke-Feishu -Method Post -Url 'https://open.feishu.cn/open-apis/docx/v1/documents/blocks/convert' -BodyObj $body -Token $Token
    return $resp.data
}

function Get-SanitizedBlocks {
    param($Blocks)
    # 保留 block_id/block_type/children 与类型内容字段；移除 parent_id/revision_id；
    # 表格块必须去掉只读的 merge_info；表格单元格至少需要一个子块，为空则补空文本块。
    $clean = [System.Collections.Generic.List[object]]::new()
    $skipKeys = @('parent_id', 'revision_id', 'parent_id_version', 'space_id')
    foreach ($b in $Blocks) {
        $nb = [pscustomobject]@{ block_id = $b.block_id; block_type = $b.block_type }
        foreach ($p in $b.PSObject.Properties) {
            if ($p.Name -in @('block_id', 'block_type') -or $p.Name -in $skipKeys) { continue }
            $val = $p.Value
            if ($p.Name -eq 'table' -and $null -ne $val -and $val.PSObject.Properties['property']) {
                $val.property.PSObject.Properties.Remove('merge_info') | Out-Null
            }
            $nb | Add-Member -NotePropertyName $p.Name -NotePropertyValue $val
        }
        if ($nb.block_type -eq 32) {
            $kids = @()
            if ($nb.PSObject.Properties['children']) { $kids = @($nb.children) }
            if ($kids.Count -eq 0) {
                $fillId = 'fill_' + [guid]::NewGuid().ToString('N')
                $fill = [pscustomobject]@{
                    block_id  = $fillId
                    block_type = 2
                    children  = @()
                    text      = @{ elements = @(@{ text_run = @{ content = '' } }) }
                }
                $clean.Add($fill)
                if ($nb.PSObject.Properties['children']) { $nb.children = @($fillId) }
                else { $nb | Add-Member -NotePropertyName children -NotePropertyValue @($fillId) }
            }
        } elseif (-not $nb.PSObject.Properties['children']) {
            $nb | Add-Member -NotePropertyName children -NotePropertyValue @()
        }
        $clean.Add($nb)
    }
    return $clean.ToArray()
}

function New-FeishuDocx {
    param([string]$FolderToken, [string]$Title, [string]$Token)
    $body = @{ folder_token = $FolderToken; title = $Title }
    $resp = Invoke-Feishu -Method Post -Url 'https://open.feishu.cn/open-apis/docx/v1/documents' -BodyObj $body -Token $Token
    if (-not $resp.data.document -or [string]::IsNullOrWhiteSpace($resp.data.document.document_id)) { throw '创建文档失败：响应缺少 document_id。' }
    return $resp.data.document
}

function Add-DocumentContent {
    param([string]$DocumentId, [string]$Token, $ConvertData)
    $firstLevel = @($ConvertData.first_level_block_ids)
    $descendants = @(Get-SanitizedBlocks -Blocks $ConvertData.blocks)
    if ($firstLevel.Count -eq 0 -or $descendants.Count -eq 0) { throw 'Markdown 转换为文档块后内容为空。' }
    if ($descendants.Count -gt 1000) {
        throw ("转换后的文档块数量为 {0}，超过单次创建嵌套块上限 1000。当前周报不应这么大，请检查报告内容或联系维护者扩展分批逻辑。" -f $descendants.Count)
    }
    $body = @{ children_id = $firstLevel; descendants = $descendants; index = -1 }
    $url = 'https://open.feishu.cn/open-apis/docx/v1/documents/' + $DocumentId + '/blocks/' + $DocumentId + '/descendant'
    $resp = Invoke-Feishu -Method Post -Url $url -BodyObj $body -Token $Token
    return $resp.data
}

function Get-DocumentInfo {
    param([string]$DocumentId, [string]$Token)
    $resp = Invoke-Feishu -Method Get -Url ('https://open.feishu.cn/open-apis/docx/v1/documents/' + $DocumentId) -Token $Token
    return $resp.data.document
}

function Get-DocumentBlocks {
    param([string]$DocumentId, [string]$Token)
    $blocks = @()
    $pageToken = ''
    do {
        $url = 'https://open.feishu.cn/open-apis/docx/v1/documents/' + $DocumentId + '/blocks?page_size=500'
        if ($pageToken) { $url += '&page_token=' + [uri]::EscapeDataString($pageToken) }
        $resp = Invoke-Feishu -Method Get -Url $url -Token $Token
        $blocks += @($resp.data.items)
        $pageToken = $resp.data.page_token
        $hasMore = $resp.data.has_more
        if ($hasMore -and -not $pageToken) { throw 'Document pagination is incomplete.' }
    } while ($hasMore)
    return $blocks
}

function Get-ContentSignature {
    param($Blocks)
    $parts = @()
    foreach ($block in $Blocks) {
        if ($block.block_type -eq 1) { continue }
        if ($block.block_type -eq 31) {
            $parts += 'TABLE|' + $block.table.property.row_size + '|' + $block.table.property.column_size
        } elseif ($block.block_type -eq 32) { $parts += 'CELL' }
        foreach ($property in $block.PSObject.Properties) {
            $value = $property.Value
            if ($null -eq $value -or -not $value.PSObject.Properties['elements']) { continue }
            $textParts = @()
            foreach ($element in $value.elements) {
                if ($element.text_run) {
                    $textParts += $element.text_run.content
                    $link = $element.text_run.text_element_style.link.url
                    if ($link) { $parts += 'LINK|' + [uri]::UnescapeDataString($link) }
                }
            }
            $blockText = [regex]::Replace(($textParts -join ''), '\s+', ' ').Trim()
            if ($blockText) { $parts += ([string]$block.block_type + '|TEXT|' + $blockText) }
        }
    }
    return (($parts | Sort-Object -CaseSensitive) -join "`n")
}

function Assert-DocumentContent {
    param($ActualBlocks, $ExpectedBlocks)
    $expected = Get-ContentSignature -Blocks $ExpectedBlocks
    $actual = Get-ContentSignature -Blocks $ActualBlocks
    if (-not $expected -or $actual -cne $expected) {
        throw 'Document text, links or table structure differs from the local report. Existing content was not overwritten.'
    }
}

# ---------- 上传状态（运行记录/feishu_uploads.json） ----------
function Read-UploadState {
    if (-not (Test-Path -LiteralPath $statePath)) { return @() }
    try {
        $obj = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $obj) { return @() }
        return @($obj)
    } catch { return @() }
}
function Write-UploadState {
    param($Records)
    $json = $Records | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($statePath, $json, [Text.UTF8Encoding]::new($false))
}

# ---------- 主流程 ----------
try {
    Write-Log ('FEISHU_UPLOAD: 开始，模式={0}' -f $(if ($CheckOnly) { 'CheckOnly 连接验证' } else { '正常上传' }))
    $token = Get-TenantAccessToken -AppId $cred.app_id -AppSecret $cred.app_secret
    Write-Log 'FEISHU_UPLOAD: 已获取 tenant_access_token。'

    $semester = Resolve-SemesterFolder -Token $token
    Update-FeishuConfig -TargetToken $semester.token
    $semesterUrl = if ($semester.url) { $semester.url } else { '' }
    Write-Log ("FEISHU_FOLDER: 学期目录已就绪 name={0} token={1} url={2}" -f $semester.name, $semester.token, $semesterUrl)

    if ($CheckOnly) {
        $cloudDocs = @(Get-FolderChildren -FolderToken $semester.token -Token $token)
        $docCount = @($cloudDocs | Where-Object { $_.type -ne 'folder' }).Count
        Write-Log ("FEISHU_CHECK: 连接验证通过。目录可读，现有文件数={0}。未创建任何文档。" -f $docCount)
        Save-Log -Status 'check_ok'
        Write-Output ("FEISHU_CHECK_DONE: folder_token={0}" -f $semester.token)
        exit 0
    }

    # 本地学期目录（与 run-weekly.ps1 同一路径口径）
    $outputRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot $config.output_root))
    $localSemesterRoot = Join-Path (Join-Path $outputRoot $config.group_name) $config.semester_name

    $reports = @()
    if ($ReportPath) {
        if (-not (Test-Path -LiteralPath $ReportPath)) { throw "指定的周报不存在：$ReportPath" }
        $reports = @(Get-Item -LiteralPath $ReportPath)
    } elseif (Test-Path -LiteralPath $localSemesterRoot) {
        $reports = @(Get-ChildItem -LiteralPath $localSemesterRoot -File -Filter '第*周_*.md' | Sort-Object Name)
    }
    if ($reports.Count -eq 0) {
        Write-Log ('FEISHU_UPLOAD: 没有需要上传的本地周报' + $(if ($ReportPath) { "（指定文件不存在或未匹配：$ReportPath）" } else { "（$localSemesterRoot 下无 第*周_*.md）" }))
        Save-Log -Status 'nothing_to_upload'
        exit 0
    }

    $state = @(Read-UploadState)
    $cloudDocs = @(Get-FolderChildren -FolderToken $semester.token -Token $token)
    $successCount = 0
    foreach ($r in $reports) {
        $title = [IO.Path]::GetFileNameWithoutExtension($r.Name)
        $existing = $cloudDocs | Where-Object { $_.name -eq $title -and $_.type -ne 'folder' } | Select-Object -First 1
        try {
            # Convert before creating a document, and use it to verify all visible content.
            $content = [IO.File]::ReadAllText($r.FullName, [Text.Encoding]::UTF8)
            $conv = Convert-MarkdownToBlocks -Content $content -Token $token
            $docId = $null
            if ($existing) {
                Write-Log ("FEISHU_UPLOAD: 云端已有同名文档 {0}，检查内容完整性…" -f $existing.name)
                $existingBlocks = @(Get-DocumentBlocks -DocumentId $existing.token -Token $token)
                if ($existingBlocks.Count -gt 1) {
                    Assert-DocumentContent -ActualBlocks $existingBlocks -ExpectedBlocks $conv.blocks
                    Write-Log 'FEISHU_UPLOAD: 同名文档的文字、链接与表格均匹配，保留原内容。'
                    $docId = $existing.token
                } else {
                    Write-Log 'FEISHU_UPLOAD: 已有同名文档为空（可能上次写入失败），补写内容…'
                    $docId = $existing.token
                    Add-DocumentContent -DocumentId $docId -Token $token -ConvertData $conv | Out-Null
                }
            } else {
                Write-Log ("FEISHU_UPLOAD: 创建云文档 {0}…" -f $title)
                $doc = New-FeishuDocx -FolderToken $semester.token -Title $title -Token $token
                $docId = $doc.document_id
                Add-DocumentContent -DocumentId $docId -Token $token -ConvertData $conv | Out-Null
            }
            # 回读核验：标题一致、内容块存在（>1 即含 Page 之外的内容）
            $info = Get-DocumentInfo -DocumentId $docId -Token $token
            $actualBlocks = @(Get-DocumentBlocks -DocumentId $docId -Token $token)
            $blockCount = $actualBlocks.Count
            if ($info.title -ne $title -or $blockCount -le 1) {
                throw ("回读核验失败：title={0}, blockCount={1}" -f $info.title, $blockCount)
            }
            Assert-DocumentContent -ActualBlocks $actualBlocks -ExpectedBlocks $conv.blocks
            # 从目录清单回读父目录与链接
            $cloudDocs = @(Get-FolderChildren -FolderToken $semester.token -Token $token)
            $entry = $cloudDocs | Where-Object { $_.token -eq $docId } | Select-Object -First 1
            if (-not $entry) { throw 'The document was not found in the requested semester folder.' }
            $docUrl = if ($entry -and $entry.url) { $entry.url } else { '' }
            $state = @($state | Where-Object { $_.title -ne $title })
            $state += [pscustomobject]@{
                title      = $title
                report     = $r.Name
                doc_id     = $docId
                doc_url    = $docUrl
                status     = 'verified'
                updated_at = (Get-ChinaNow).ToString('yyyy-MM-dd HH:mm:ss')
            }
            Write-UploadState -Records $state
            Write-Log ("FEISHU_UPLOAD: 成功 {0} -> doc_id={1} url={2}（块数={3}）" -f $r.Name, $docId, $docUrl, $blockCount)
            $successCount++
        } catch {
            Write-Log ("FEISHU_UPLOAD_ERROR: {0} 上传失败：{1}" -f $r.Name, $_.Exception.Message)
        }
    }

    if ($successCount -lt $reports.Count) {
        Write-Log ("FEISHU_UPLOAD: 完成，成功 {0}/{1}，失败的周报保留本地并在下次运行重试。" -f $successCount, $reports.Count)
        Save-Log -Status 'partial_failure'
        exit 1
    }
    Write-Log ("FEISHU_UPLOAD: 全部完成（{0} 篇）。" -f $successCount)
    Save-Log -Status 'ok'
    exit 0
} catch {
    Write-Log ('FEISHU_UPLOAD_ERROR: ' + $_.Exception.Message)
    Save-Log -Status 'error'
    exit 1
}
