# ============================================================
# 微信桥接 —— 本地轮询代理
# 持续轮询云队列，取出任务 → 调用命令执行器 → 回传结果
# ============================================================

param(
  [string]$CloudBaseUrl = $env:WECHAT_QUEUE_URL,    # 云队列地址
  [string]$AgentSecret = $env:WECHAT_AGENT_SECRET,   # 代理密钥
  [string]$CommandsFile = "$PSScriptRoot\commands.json",
  [string]$ProjectsFile = "$PSScriptRoot\projects.json",
  [int]$IntervalSeconds = 3                           # 轮询间隔（秒）
)

$ErrorActionPreference = "Continue"

# 加载命令执行器
. "$PSScriptRoot\wechat-command-runner.ps1"

# ==================== 配置检查 ====================

if ([string]::IsNullOrWhiteSpace($CloudBaseUrl)) {
  Write-Host "错误: 未设置 WECHAT_QUEUE_URL 环境变量" -ForegroundColor Red
  Write-Host "请先设置: `$env:WECHAT_QUEUE_URL = 'https://你的云服务地址'" -ForegroundColor Yellow
  exit 1
}

if ([string]::IsNullOrWhiteSpace($AgentSecret)) {
  Write-Host "错误: 未设置 WECHAT_AGENT_SECRET 环境变量" -ForegroundColor Red
  Write-Host "请先设置: `$env:WECHAT_AGENT_SECRET = '你的代理密钥'" -ForegroundColor Yellow
  exit 1
}

$CloudBaseUrl = $CloudBaseUrl.TrimEnd("/")

# ==================== 日志 ====================

$LogFile = Join-Path (Get-BridgeRoot) "agent-log.txt"

function Write-Log {
  param([string]$Level, [string]$Message)
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $line = "[$ts] [$Level] $Message"
  Write-Host $line
  try {
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
  }
  catch {
    # 日志写入失败不影响主流程
  }
  # 控制日志文件大小（保留最近 500 行）
  try {
    $lines = Get-Content -LiteralPath $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($lines.Count -gt 500) {
      $lines[-200..-1] | Set-Content -LiteralPath $LogFile -Encoding UTF8
    }
  }
  catch { }
}

# ==================== 启动信息 ====================

Write-Log "INFO" "==========================================="
Write-Log "INFO" "微信桥接代理启动"
Write-Log "INFO" "云队列地址: $CloudBaseUrl"
Write-Log "INFO" "命令配置: $CommandsFile"
Write-Log "INFO" "项目配置: $ProjectsFile"
Write-Log "INFO" "轮询间隔: ${IntervalSeconds}秒"
Write-Log "INFO" "计算机: $env:COMPUTERNAME"
Write-Log "INFO" "==========================================="

# ==================== 主循环 ====================

while ($true) {
  try {
    # 轮询取任务
    $pollUrl = "$CloudBaseUrl/api/poll?secret=$([System.Uri]::EscapeDataString($AgentSecret))"
    $task = Invoke-RestMethod -Method Get -Uri $pollUrl -TimeoutSec 30

    if ($task -and $task.id) {
      Write-Log "INFO" "收到任务 #$($task.id): $($task.message)"

      # 识别任务类型以确定超时
      $msg = [string]$task.message
      $isAiTask = $msg -match "^(ask|问答|dev|需求|review|审查)\b"

      # 执行命令（带错误保护，防止单任务异常导致代理崩溃）
      $startTime = Get-Date
      try {
        $result = Invoke-BridgeCommand -Message $msg -CommandsFile $CommandsFile -ProjectsFile $ProjectsFile
      }
      catch {
        $result = "命令执行异常: $($_.Exception.Message)"
        Write-Log "ERROR" "任务执行异常: $($_.Exception.Message)"
      }
      $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

      Write-Log "INFO" "任务 #$($task.id) 完成 (${elapsed}秒)"

      # 回传结果（限制大小，防止超大结果导致POST失败）
      $resultText = "[${elapsed}秒]`n$result"
      if ($resultText.Length -gt 5000) {
        $resultText = $resultText.Substring(0, 5000) + "`n...输出过长已截断"
      }

      $payload = @{
        id     = [string]$task.id
        result = $resultText
      } | ConvertTo-Json -Depth 3

      $retryCount = 0
      $maxRetries = 3
      $posted = $false
      while (-not $posted -and $retryCount -lt $maxRetries) {
        try {
          Invoke-RestMethod `
            -Method Post `
            -Uri "$CloudBaseUrl/api/result" `
            -Headers @{ "Authorization" = "Bearer $AgentSecret" } `
            -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) `
            -TimeoutSec 30 | Out-Null
          $posted = $true
        }
        catch {
          $retryCount++
          Write-Log "WARN" "回传结果失败 (第${retryCount}次重试): $($_.Exception.Message)"
          Start-Sleep -Seconds 5
        }
      }

      if (-not $posted) {
        Write-Log "ERROR" "回传结果彻底失败，任务结果丢失: #$($task.id)"
      }
    }
  }
  catch {
    # 网络错误不退出，等待后重试
    $errMsg = $_.Exception.Message
    if ($errMsg -match "Unable to connect|timed out|Name or service not known|connection refused") {
      Write-Log "WARN" "网络连接失败，${IntervalSeconds}秒后重试: $errMsg"
    }
    else {
      Write-Log "ERROR" "未知错误: $errMsg"
    }
  }

  Start-Sleep -Seconds $IntervalSeconds
}
