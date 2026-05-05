# ============================================================
# 微信命令执行器
# 负责解析微信发来的命令，执行本地操作，包括调用 Claude AI
# ============================================================

param()

# ==================== 辅助函数 ====================

# 获取桥接项目根目录
function Get-BridgeRoot {
  if ($PSScriptRoot) {
    return $PSScriptRoot
  }
  return (Get-Location).Path
}

# 读取命令配置文件 (commands.json)
function Get-CommandConfig {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return @{}
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @{}
  }

  $json = $raw | ConvertFrom-Json
  $commands = @{}
  foreach ($property in $json.commands.PSObject.Properties) {
    $commands[$property.Name] = $property.Value
  }
  return $commands
}

# 读取项目配置文件 (projects.json)
function Get-ProjectConfig {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return @{
      defaultProject = "bridge"
      projects        = @{
        bridge = @{
          path = (Get-BridgeRoot)
        }
      }
    }
  }

  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

# 根据项目别名解析实际路径
function Resolve-ProjectPath {
  param(
    [string]$ProjectName,
    [string]$ProjectsFile
  )

  $config = Get-ProjectConfig $ProjectsFile
  $name = if ([string]::IsNullOrWhiteSpace($ProjectName)) { [string]$config.defaultProject } else { $ProjectName }
  $property = $config.projects.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
  if (-not $property) {
    throw "未知项目 '$name'。请先在 projects.json 中添加此项目。"
  }

  $path = [string]$property.Value.path
  if (-not (Test-Path -LiteralPath $path)) {
    throw "项目路径不存在: $path"
  }
  return (Resolve-Path -LiteralPath $path).Path
}

# 执行 PowerShell 命令并捕获输出
function Invoke-CapturedPowerShell {
  param(
    [string]$Command,
    [string]$WorkingDirectory,
    [int]$TimeoutSeconds = 60
  )

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = "powershell.exe"
  $wrappedCommand = "`$ProgressPreference = 'SilentlyContinue'; $Command"
  $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrappedCommand))
  $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $process = [System.Diagnostics.Process]::Start($psi)
  $finished = $process.WaitForExit($TimeoutSeconds * 1000)
  if (-not $finished) {
    try { $process.Kill($true) } catch { }
    return "命令超时 ($TimeoutSeconds 秒)。"
  }

  $stdout = $process.StandardOutput.ReadToEnd().Trim()
  $stderr = $process.StandardError.ReadToEnd().Trim()
  $output = @()
  $output += "ExitCode: $($process.ExitCode)"
  if ($stdout) { $output += "stdout:`n$stdout" }
  if ($stderr) { $output += "stderr:`n$stderr" }
  return ($output -join "`n")
}

# 将输入文本拆分为"项目名"和"剩余文本"
function Split-ProjectAndText {
  param([string]$Text)

  $trimmed = $Text.Trim()
  $space = $trimmed.IndexOf(" ")
  if ($space -lt 0) {
    return @{
      Project = $trimmed
      Text    = ""
    }
  }

  return @{
    Project = $trimmed.Substring(0, $space)
    Text    = $trimmed.Substring($space + 1).Trim()
  }
}

# 截断文本到指定长度，超出部分用省略号替代
function Limit-Text {
  param(
    [string]$Text,
    [int]$MaxLength = 1800
  )
  if ($Text.Length -gt $MaxLength) {
    return $Text.Substring(0, $MaxLength) + "`n...输出过长已截断"
  }
  return $Text
}

# ==================== AI 核心函数 ====================

# 调用 Claude CLI 的底层函数
# 通过 stdin 传入提示词，避免命令行参数编码问题
function Invoke-ClaudeCLI {
  param(
    [string]$Prompt,            # 提示词
    [string]$WorkingDirectory,  # 工作目录
    [int]$TimeoutSeconds = 120, # 超时时间（秒）
    [bool]$AllowEdit = $false,  # 是否允许修改文件
    [bool]$IsReview = $false    # 是否为代码审查模式
  )

  # 构建参数列表
  $cliArgs = @(
    "-p",
    "--print",
    "--output-format", "text",
    "--no-session-persistence"
  )

  if ($AllowEdit) {
    # 开发模式：允许修改文件
    $cliArgs += @(
      "--permission-mode", "bypassPermissions",
      "--add-dir", $WorkingDirectory,
      "--allowed-tools", "Read,Grep,Glob,Edit,Write,Bash(git:*)"
    )
  }
  elseif ($IsReview) {
    # 审查模式：只读访问
    $cliArgs += @(
      "--permission-mode", "bypassPermissions",
      "--add-dir", $WorkingDirectory,
      "--allowed-tools", "Read,Grep,Glob"
    )
  }
  else {
    # 问答模式：禁止所有工具
    $cliArgs += @("--tools", '""')
  }

  # 将提示词写入临时文件（UTF-8 编码，避免中文字符问题）
  $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "claude-wechat-$([System.Guid]::NewGuid().ToString("N")).txt"
  [System.IO.File]::WriteAllText($tempFile, $Prompt, [System.Text.UTF8Encoding]::new($false))

  try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "claude"
    $psi.Arguments = ($cliArgs -join " ")
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)

    # 通过 stdin 传入 UTF-8 编码的提示词
    $stdinWriter = New-Object System.IO.StreamWriter($process.StandardInput.BaseStream, [System.Text.Encoding]::UTF8)
    $stdinWriter.Write($Prompt)
    $stdinWriter.Close()

    # 等待任务完成
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
      try { $process.Kill($true) } catch { }
      return "AI 任务超时 (${TimeoutSeconds}秒)。复杂任务可能需要更长时间，请尝试拆分为更小的需求。"
    }

    $stdout = $process.StandardOutput.ReadToEnd().Trim()
    $stderr = $process.StandardError.ReadToEnd().Trim()

    if ($process.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($stdout)) {
      return "AI 执行出错 (ExitCode: $($process.ExitCode))`n$stderr"
    }

    return $stdout
  }
  catch {
    return "AI 调用异常: $($_.Exception.Message)"
  }
  finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
  }
}

# AI 问答 —— 纯粹问答，不修改文件
function Invoke-ClaudeAsk {
  param(
    [string]$Question,
    [string]$WorkingDirectory
  )

  if ([string]::IsNullOrWhiteSpace($Question)) {
    return "用法: ask <问题>  或  问答 <问题>`n示例: ask 如何在Python中读取JSON文件？"
  }

  $prompt = @"
请用中文回答以下问题。回答要简洁、准确、分点说明。
如果涉及代码示例，请给出清晰可用的代码。

问题: $Question
"@

  $result = Invoke-ClaudeCLI -Prompt $prompt -WorkingDirectory $WorkingDirectory -TimeoutSeconds 120 -AllowEdit $false
  return Limit-Text -Text $result -MaxLength 1800
}

# AI 开发任务 —— 修改代码、修复Bug、添加功能
function Invoke-ClaudeDev {
  param(
    [string]$ProjectName,
    [string]$TaskDescription,
    [string]$WorkingDirectory
  )

  if ([string]::IsNullOrWhiteSpace($TaskDescription)) {
    return "用法: dev <项目名> <任务描述>  或  需求 <项目名> <任务描述>`n示例: dev bridge 修复登录验证逻辑的bug"
  }

  $prompt = @"
你是一位资深软件工程师。请根据以下需求修改代码。

## 需求描述
$TaskDescription

## 要求
1. 先阅读相关文件，理解现有代码结构
2. 精准地修改代码，只改必要的部分
3. 不要引入新的依赖，除非绝对必要
4. 修改完成后，用中文简洁地总结你做了什么（修改了哪些文件、做了什么改动）
5. 如果需求不明确，说明你的假设

现在开始执行。
"@

  $result = Invoke-ClaudeCLI -Prompt $prompt -WorkingDirectory $WorkingDirectory -TimeoutSeconds 300 -AllowEdit $true
  return Limit-Text -Text $result -MaxLength 1800
}

# AI 代码审查 —— 审查项目代码质量和安全性
function Invoke-ClaudeReview {
  param(
    [string]$ProjectName,
    [string]$WorkingDirectory
  )

  $prompt = @"
请审查这个项目的代码质量和安全性。

## 审查要点
1. 代码结构和组织是否合理
2. 是否存在潜在的Bug或逻辑错误
3. 安全漏洞（SQL注入、XSS、命令注入等）
4. 性能瓶颈
5. 错误处理是否完善
6. 依赖是否合理

请用中文给出简洁的审查报告，列出发现的问题和对应的改进建议。按严重程度排序（严重 > 中等 > 轻微）。

如果没有发现严重问题，也请说明代码的整体质量水平。
"@

  $result = Invoke-ClaudeCLI -Prompt $prompt -WorkingDirectory $WorkingDirectory -TimeoutSeconds 180 -AllowEdit $false -IsReview $true
  return Limit-Text -Text $result -MaxLength 1800
}

# ==================== 系统状态函数 ====================

# 获取系统运行状态
function Get-SystemStatus {
  $computer = $env:COMPUTERNAME

  # CPU 使用率
  $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
  $cpuText = if ($cpu) { "$cpu%" } else { "N/A" }

  # 内存使用
  $os = Get-CimInstance Win32_OperatingSystem
  $totalMem = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
  $freeMem = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
  $usedMem = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)

  # 磁盘使用
  $disk = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 } |
  Select-Object -First 3 |
  ForEach-Object {
    $usedGB = [math]::Round($_.Used / 1GB, 1)
    $freeGB = [math]::Round($_.Free / 1GB, 1)
    "$($_.Name): 已用 ${usedGB}G / 可用 ${freeGB}G"
  }
  $diskText = ($disk -join " | ")

  # 当前时间
  $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

  # 运行时长
  $uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  $uptimeText = "$($uptime.Days)天 $($uptime.Hours)小时 $($uptime.Minutes)分钟"

  return @"
计算机: $computer
时间: $now
运行时长: $uptimeText
CPU: $cpuText
内存: 已用 ${usedMem}G / 共 ${totalMem}G
磁盘: $diskText
"@
}

# 获取最近的执行日志
function Get-RecentLog {
  param([string]$BridgeRoot)

  $logFile = Join-Path $BridgeRoot "agent-log.txt"
  if (-not (Test-Path -LiteralPath $logFile)) {
    return "暂无日志记录。"
  }

  $lines = Get-Content -LiteralPath $logFile -Tail 20 -Encoding UTF8
  return ($lines -join "`n")
}

# ==================== Git 操作函数 ====================

# 查看 Git 状态
function Invoke-GitStatus {
  param(
    [string]$ProjectName,
    [string]$ProjectsFile
  )

  $projectPath = Resolve-ProjectPath -ProjectName $ProjectName -ProjectsFile $ProjectsFile
  $result = Invoke-CapturedPowerShell -Command "git status --short --branch" -WorkingDirectory $projectPath -TimeoutSeconds 20
  return Limit-Text -Text $result -MaxLength 1800
}

# 查看 Git 差异
function Invoke-GitDiff {
  param(
    [string]$ProjectName,
    [string]$ProjectsFile
  )

  $projectPath = Resolve-ProjectPath -ProjectName $ProjectName -ProjectsFile $ProjectsFile
  $result = Invoke-CapturedPowerShell -Command "git diff --stat; git diff -- . ':!package-lock.json' ':!pnpm-lock.yaml' ':!yarn.lock' | Select-Object -First 220" -WorkingDirectory $projectPath -TimeoutSeconds 30
  return Limit-Text -Text $result -MaxLength 1800
}

# 准备 Git 提交（不立即执行，需要 confirm 确认）
function Invoke-GitCommit {
  param(
    [string]$ProjectName,
    [string]$Message,
    [string]$ProjectsFile
  )

  if ([string]::IsNullOrWhiteSpace($Message)) {
    return "用法: git commit <项目名> <提交说明>  或  git提交 <项目名> <提交说明>"
  }

  $projectPath = Resolve-ProjectPath -ProjectName $ProjectName -ProjectsFile $ProjectsFile
  $status = Invoke-CapturedPowerShell -Command "git status --short" -WorkingDirectory $projectPath -TimeoutSeconds 20
  if ($status -match "ExitCode: 0\s*$") {
    return "没有需要提交的修改。"
  }

  $pendingDir = Join-Path $projectPath ".codex-wechat\pending"
  New-Item -ItemType Directory -Force -Path $pendingDir | Out-Null
  $id = "commit-" + (Get-Date -Format "yyyyMMdd-HHmmss")
  $pendingFile = Join-Path $pendingDir "$id.json"
  @{
    id          = $id
    type        = "git-commit"
    project     = $ProjectName
    projectPath = $projectPath
    message     = $Message
    createdAt   = (Get-Date -Format o)
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pendingFile -Encoding UTF8

  $summary = Limit-Text -Text $status -MaxLength 1200
  return "待确认提交 $id`n提交说明: $Message`n确认: confirm $id`n`n$summary"
}

# 确认执行待处理操作
function Confirm-PendingAction {
  param(
    [string]$Id,
    [string]$ProjectsFile
  )

  if ([string]::IsNullOrWhiteSpace($Id)) {
    return "用法: confirm <操作ID>"
  }

  $config = Get-ProjectConfig $ProjectsFile
  foreach ($project in $config.projects.PSObject.Properties) {
    $projectPath = [string]$project.Value.path
    $pendingFile = Join-Path $projectPath ".codex-wechat\pending\$Id.json"
    if (Test-Path -LiteralPath $pendingFile) {
      $pending = Get-Content -LiteralPath $pendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ([string]$pending.type -ne "git-commit") {
        return "未知的待处理操作类型: $($pending.type)"
      }

      $safeMessage = ([string]$pending.message).Replace("'", "''")
      $command = "git status --short; git add -A; git commit -m '$safeMessage'"
      $result = Invoke-CapturedPowerShell -Command $command -WorkingDirectory ([string]$pending.projectPath) -TimeoutSeconds 60
      Remove-Item -LiteralPath $pendingFile -Force
      return Limit-Text -Text $result -MaxLength 1800
    }
  }

  return "未找到待处理操作: $Id"
}

# ==================== 主命令路由 ====================

# 根据微信消息内容路由到对应的处理函数
function Invoke-BridgeCommand {
  param(
    [string]$Message,           # 微信发来的消息文本
    [string]$CommandsFile,      # commands.json 路径
    [string]$ProjectsFile = "$(Get-BridgeRoot)\projects.json"
  )

  $trimmed = $Message.Trim()
  $bridgeRoot = Get-BridgeRoot

  # ---- 帮助 ----
  if ($trimmed -eq "help" -or $trimmed -eq "帮助") {
    return @"
=== 可用命令 ===

【AI 功能】
ask <问题> / 问答 <问题>
  → AI 问答，不修改代码

dev <项目> <需求> / 需求 <项目> <需求>
  → AI 执行开发任务，修改代码

review <项目> / 审查 <项目>
  → AI 代码审查

【Git 操作】
git status <项目> / git状态 <项目>
git diff <项目> / git差异 <项目>
git commit <项目> <说明> / git提交 <项目> <说明>
confirm <操作ID>

【其他】
status / 状态 → 系统状态
log / 日志 → 最近日志
result / 结果 → 查看执行结果
time / 时间 → 当前时间
ls / 目录 → 列出文件

【项目别名】
在 projects.json 中配置
"@
  }

  # ---- 结果查询 ----
  if ($trimmed -eq "result" -or $trimmed -eq "结果") {
    return '请从微信发送"结果"到公众号查询。'
  }

  # ---- 系统状态 ----
  if ($trimmed -eq "status" -or $trimmed -eq "状态") {
    return Get-SystemStatus
  }

  # ---- 查看日志 ----
  if ($trimmed -eq "log" -or $trimmed -eq "日志") {
    return Get-RecentLog -BridgeRoot $bridgeRoot
  }

  # ---- AI 问答 (ask / 问答) ----
  if ($trimmed -match "^ask (.+)$" -or $trimmed -match "^问答 (.+)$") {
    $question = if ($Matches[1]) { $Matches[1] } else { $trimmed.Substring($trimmed.IndexOf(" ") + 1).Trim() }
    $result = Invoke-ClaudeAsk -Question $question -WorkingDirectory $bridgeRoot
    return $result
  }

  # ---- AI 开发 (dev / 需求) ----
  if ($trimmed -match "^dev (.+)$" -or $trimmed -match "^需求 (.+)$") {
    $rest = $Matches[1]
    $parts = Split-ProjectAndText $rest
    try {
      $projectPath = Resolve-ProjectPath -ProjectName $parts.Project -ProjectsFile $ProjectsFile
    }
    catch {
      return $_.Exception.Message
    }

    # 同时保存 inbox 记录
    if ($parts.Text) {
      $inbox = Join-Path $projectPath ".codex-wechat\inbox"
      New-Item -ItemType Directory -Force -Path $inbox | Out-Null
      $reqId = Get-Date -Format "yyyyMMdd-HHmmss"
      $file = Join-Path $inbox "$reqId.md"
      $body = @"
# 微信开发需求 $reqId
项目: $($parts.Project)
路径: $projectPath
时间: $(Get-Date -Format o)

$($parts.Text)
"@
      Set-Content -LiteralPath $file -Value $body -Encoding UTF8
    }

    $result = Invoke-ClaudeDev -ProjectName $parts.Project -TaskDescription $parts.Text -WorkingDirectory $projectPath
    return $result
  }

  # ---- AI 代码审查 (review / 审查) ----
  if ($trimmed -match "^review (.+)$" -or $trimmed -match "^审查 (.+)$") {
    $projectNameWithRest = $Matches[1]
    # 可能后面还有其他文字，取第一个词作为项目名
    $spaceIdx = $projectNameWithRest.IndexOf(" ")
    $projectName = if ($spaceIdx -gt 0) { $projectNameWithRest.Substring(0, $spaceIdx) } else { $projectNameWithRest }
    try {
      $projectPath = Resolve-ProjectPath -ProjectName $projectName -ProjectsFile $ProjectsFile
    }
    catch {
      return $_.Exception.Message
    }
    return Invoke-ClaudeReview -ProjectName $projectName -WorkingDirectory $projectPath
  }

  # ---- Git 状态 (git status / git状态) ----
  if ($trimmed -match "^git status (.+)$" -or $trimmed -match "^git状态 (.+)$") {
    $projectName = $Matches[1].Trim()
    try {
      return Invoke-GitStatus -ProjectName $projectName -ProjectsFile $ProjectsFile
    }
    catch {
      return $_.Exception.Message
    }
  }

  # ---- Git 差异 (git diff / git差异) ----
  if ($trimmed -match "^git diff (.+)$" -or $trimmed -match "^git差异 (.+)$") {
    $projectName = $Matches[1].Trim()
    try {
      return Invoke-GitDiff -ProjectName $projectName -ProjectsFile $ProjectsFile
    }
    catch {
      return $_.Exception.Message
    }
  }

  # ---- Git 提交 (git commit / git提交) ----
  if ($trimmed -match "^git commit (.+)$" -or $trimmed -match "^git提交 (.+)$") {
    $rest = $Matches[1]
    $parts = Split-ProjectAndText $rest
    try {
      return Invoke-GitCommit -ProjectName $parts.Project -Message $parts.Text -ProjectsFile $ProjectsFile
    }
    catch {
      return $_.Exception.Message
    }
  }

  # ---- 确认操作 ----
  if ($trimmed -match "^confirm (.+)$") {
    return Confirm-PendingAction -Id $Matches[1].Trim() -ProjectsFile $ProjectsFile
  }

  # ---- 白名单命令 (commands.json) ----
  $commands = Get-CommandConfig $CommandsFile
  if ($commands.ContainsKey($trimmed)) {
    $config = $commands[$trimmed]
    $command = [string]$config.command
    $workingDirectory = if ($config.workingDirectory) { [string]$config.workingDirectory } else { Split-Path -Parent $CommandsFile }
    $timeoutSeconds = if ($config.timeoutSeconds) { [int]$config.timeoutSeconds } else { 60 }

    if (-not (Test-Path -LiteralPath $workingDirectory)) {
      return "工作目录不存在: $workingDirectory"
    }

    $text = Invoke-CapturedPowerShell -Command $command -WorkingDirectory $workingDirectory -TimeoutSeconds $timeoutSeconds
    return Limit-Text -Text $text -MaxLength 1800
  }

  # ---- 未知命令：自动转为 AI 问答 ----
  # 如果消息不匹配任何已知命令，当作自然语言问题交给 Claude AI 回答
  return Invoke-ClaudeAsk -Question $trimmed -WorkingDirectory $bridgeRoot
}
