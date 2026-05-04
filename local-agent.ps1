param(
  [string]$CloudBaseUrl = $env:WECHAT_QUEUE_URL,
  [string]$AgentSecret = $env:WECHAT_AGENT_SECRET,
  [string]$CommandsFile = "$PSScriptRoot\commands.json",
  [int]$IntervalSeconds = 3
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\wechat-command-runner.ps1"

if ([string]::IsNullOrWhiteSpace($CloudBaseUrl)) {
  Write-Error "Set WECHAT_QUEUE_URL first, for example https://your-cloud-app.example.com"
}

if ([string]::IsNullOrWhiteSpace($AgentSecret)) {
  Write-Error "Set WECHAT_AGENT_SECRET first."
}

$CloudBaseUrl = $CloudBaseUrl.TrimEnd("/")
Write-Host "Polling $CloudBaseUrl"
Write-Host "Commands: $CommandsFile"

while ($true) {
  try {
    $pollUrl = "$CloudBaseUrl/api/poll?secret=$([System.Uri]::EscapeDataString($AgentSecret))"
    $task = Invoke-RestMethod -Method Get -Uri $pollUrl -TimeoutSec 30

    if ($task -and $task.id) {
      Write-Host "Task $($task.id): $($task.message)"
      $result = Invoke-BridgeCommand -Message ([string]$task.message) -CommandsFile $CommandsFile

      $payload = @{
        id = [string]$task.id
        result = [string]$result
      } | ConvertTo-Json -Depth 5

      Invoke-RestMethod `
        -Method Post `
        -Uri "$CloudBaseUrl/api/result" `
        -Headers @{ "Authorization" = "Bearer $AgentSecret" } `
        -ContentType "application/json; charset=utf-8" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) `
        -TimeoutSec 30 | Out-Null
    }
  }
  catch {
    Write-Warning $_.Exception.Message
  }

  Start-Sleep -Seconds $IntervalSeconds
}
