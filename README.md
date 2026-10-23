# 飞书文献

智能设计小组每周文献整理与飞书自动归档。

负责人王力，学期2026秋，第1教学周从2026-09-14开始。研究方向为“基于深度强化学习的桁架结构设计”和“土木工程图纸理解与识别”；中英文关键词、研究问题与检索式已写入 weekly_literature.config.json。研究问题的细化是本次根据方向作的检索工作定义，可随课题进展调整。

已按用户更正的开学日期重排周次：2026-10-12至2026-10-18为第5教学周，2026-10-19至2026-10-25为第6教学周。此前9月7日起算的周次已作废，历史运行日志与修订前备份保留原貌；后续任务每次读取配置计算教学周。

## 当前状态

- 已归档第5周和第6周周报，保留预印本状态、中文摘要及实际阅读范围。第6周实际纳入土木工程相关1篇、跨领域方法1篇；未核实的候选不用于补足篇数，覆盖缺口见本地运行记录。
- 已注册Windows计划任务 Codex-Weekly-Literature-ZhinengSheji，每周五09:00，北京时间。下次运行：2026-10-30 09:00。
- 2026-10-23早间任务因候选来源访问失败没有生成本周报告，但旧脚本把核验上周文档误记为成功。现已增加本周产物检查、指定本周文件上传和失败自动重试；三项隔离回归测试通过。修复后通过原计划任务完成实际生成与上传，返回码0，上周文件哈希保持不变。
- 飞书已接通并启用（feishu.enabled=true）。用户确认工作区链接本身就是最终“2026秋”目录，没有额外创建同名子目录。[第5周可编辑云文档](https://ocn1qaau41u6.feishu.cn/docx/GSyVdmz2EoQPpSxsaRJcHLTEnne)已上传并按用户要求修订；三篇均已补充中文摘要，回读123个块，逐项核对文字、链接、2张表格及目标目录。计划任务实际启动上传阶段、重跑保留同名文档均已验证，返回码0。
- [第6周可编辑云文档](https://ocn1qaau41u6.feishu.cn/docx/QRHbddIEYozHD1xl71jcq2c0nbF)已于2026-10-23补跑归档，回读98个块，文字、链接、表格及归档目录核验通过。

## 定时执行的条件

任务通过Windows计划任务启动Codex CLI，运行时电脑需开机、唤醒且Windows用户已登录，网络可用、Codex登录有效。无需保持当前聊天或Codex桌面应用打开。任务使用普通用户权限和Codex的工作区写入／自动审批审查模式。

错过执行时间后，计划任务设置为可用时补跑；按实际执行日归档，不自动补造历史多周文献。学期结束日期尚未提供，semester_end_date 为空；学期结束时需暂停任务或填写结束日期并维护新学期配置。

失败任务每隔30分钟自动重试，最多2次。生成阶段必须实际产出本教学周的非空周报才会进入上传；模型进程退出码为0不代表周报已完成。上传明确指定本周文件，不能通过核验上周文档将本周任务记为成功。飞书归档已启用但凭据文件缺失时也会报错。

个别候选的出版社页面无法访问时，尝试可核验的作者公开稿、预印本或机构库；仍无法核实的候选排除并记录原因，其他已核验论文按实际篇数归档。核心检索未完成或拟纳入论文的必要信息无法核实时停止，不凭空补足篇数。

## 文件与规则

|文件|用途|
|---|---|
|00｜智能设计｜前沿论文整理模板.md|以原模板为基础，按用户要求增加每篇中文摘要字段|
|weekly_literature.config.json|课题、小组、学期、负责人、时间和飞书接入状态|
|每周文献整理任务.md|每次重新读取的提示词，规定检索、核验、去重和归档|
|scripts/run-weekly.ps1|校验配置、计算教学周、保护同周已有文件，再启动Codex整理|
|scripts/register-weekly-task.ps1|注册前预览及首次注册；已有同名任务时停止，避免覆盖|
|scripts/feishu-upload.ps1|飞书写入：核验指定学期目录、Markdown转换、创建云文档、比较文字/链接/表格并确认父目录、记录文档ID与链接；支持只读 -CheckOnly 连接验证|
|运行记录/feishu_uploads.json|云文档上传状态（按周报标题记录文档ID/链接/核验状态），供去重与重试|
|运行记录/|检索与调度验证记录；feishu_upload_*.md 为每次上传的运行日志|
|task-logs/|未来Codex运行的JSONL、错误日志和最终回复；发生失败时从此排查|

每次优先检索近7天的论文，目标为土木工程2篇、跨领域1篇；两个课题分别检索并说明覆盖情况。达不到篇数时如实说明，检索故障不能写成没有新论文。不会自动修改已存在的同周周报或覆盖人工内容。

正式周报的阅读／分享人按用户指定统一展示为“王力（已复核）”，保留真实阅读范围。试运行、检索窗口、归档过程、方向覆盖缺口等说明只写入运行记录，不附加到正式文档；后续执行规则已同步至“每周文献整理任务.md”。

每篇论文在基本信息之后、具体分析之前增加约150—250字的“摘要（中文概述）”，基于原文摘要概括研究问题、方法及主要结果或贡献，附原文摘要链接。默认采用忠实概述，不混入组内迁移设想或未经核实的数据。

## 手动运行、查看与暂停

在项目目录的PowerShell中执行：

```powershell
# 仅检查配置与路径
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\run-weekly.ps1 -CheckOnly

# 隔离回归测试：模拟生成失败、成功及同周重跑，不调用模型或飞书
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\test-weekly-runner.ps1

# 执行一次；本周已有周报则保留本地文件，并核验或补传飞书归档
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\run-weekly.ps1

# 查看计划任务及最近返回码
Get-ScheduledTask -TaskName 'Codex-Weekly-Literature-ZhinengSheji'
Get-ScheduledTaskInfo -TaskName 'Codex-Weekly-Literature-ZhinengSheji'

# 需要暂停时执行
Disable-ScheduledTask -TaskName 'Codex-Weekly-Literature-ZhinengSheji'
```

直接更改JSON中的执行时间不会同步修改已注册的Windows日程，修改时间后需要同步更新计划任务。

## 飞书写入阶段（已启用并验证）

写入实现为 `scripts/feishu-upload.ps1`，周五任务仅在同时满足以下条件时执行上传：

1. `feishu.local.json` 存在且填入真实 App ID / App Secret；
2. `weekly_literature.config.json` 中 `feishu.enabled` 为 `true`（当前已开启）。

后台一次性配置已完成，操作备忘见 [飞书接入指引](飞书接入指引.md)。凭据已从用户填写的示例迁移到被Git忽略的 feishu.local.json，示例已恢复占位符。需要重新验证时可执行：

```powershell
# 1) 连接验证：取 token、解析并核验学期目录、只读检查（不创建文档）
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\feishu-upload.ps1 -CheckOnly
# 2) 完整上传：补传本地学期目录下所有未上传的 第*周_*.md，并回读核验
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\feishu-upload.ps1
# 3) 指定单篇上传
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\feishu-upload.ps1 -ReportPath ".\智能设计小组\2026秋\第05周_2026-10-17_前沿论文整理.md"
```

行为约定：

- 失败保留本地周报并记录原因（运行记录/feishu_upload_*.md），下次运行只补传未完成的上传；
- 同名文档每次都会比较文字、链接与表格；匹配时保留，不重复创建；非空内容不一致时报错并保留人工内容；同名空文档可补写；
- 同周本地周报已存在时，保护分支仍会触发补传，不会因跳过本地生成而漏传；
- 上传失败时 run-weekly.ps1 以非零码退出，便于从计划任务 LastTaskResult 观察。

本方案使用 [OpenAI官方文档支持的Codex非交互执行方式](https://learn.chatgpt.com/docs/non-interactive-mode)。Windows计划任务是外部调度器，本项目的任务不显示在Codex应用自带的Scheduled列表中。
