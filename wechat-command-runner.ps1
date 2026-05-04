param()

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

function Invoke-BridgeCommand {
  param(
    [string]$Message,
    [string]$CommandsFile
  )

  $trimmed = $Message.Trim()
  $helpText = -join ([char]0x5e2e, [char]0x52a9)
  if ($trimmed -eq $helpText -or $trimmed -ieq "help") {
    $commands = Get-CommandConfig $CommandsFile
    if ($commands.Count -eq 0) {
      return "No commands configured. Edit commands.json and retry."
    }
    return "Commands: " + (($commands.Keys | Sort-Object) -join ", ")
  }

  $commands = Get-CommandConfig $CommandsFile
  if (-not $commands.ContainsKey($trimmed)) {
    return "Unauthorized command: $trimmed`nSend help to list commands."
  }

  $config = $commands[$trimmed]
  $command = [string]$config.command
  $workingDirectory = if ($config.workingDirectory) { [string]$config.workingDirectory } else { Split-Path -Parent $CommandsFile }
  $timeoutSeconds = if ($config.timeoutSeconds) { [int]$config.timeoutSeconds } else { 60 }

  if (-not (Test-Path -LiteralPath $workingDirectory)) {
    return "Working directory does not exist: $workingDirectory"
  }

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = "powershell.exe"
  $wrappedCommand = "`$ProgressPreference = 'SilentlyContinue'; $command"
  $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrappedCommand))
  $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
  $psi.WorkingDirectory = $workingDirectory
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $process = [System.Diagnostics.Process]::Start($psi)
  $finished = $process.WaitForExit($timeoutSeconds * 1000)
  if (-not $finished) {
    try { $process.Kill($true) } catch {}
    return "Command timed out: $trimmed"
  }

  $stdout = $process.StandardOutput.ReadToEnd().Trim()
  $stderr = $process.StandardError.ReadToEnd().Trim()
  $output = @()
  $output += "ExitCode: $($process.ExitCode)"
  if ($stdout) { $output += "stdout:`n$stdout" }
  if ($stderr) { $output += "stderr:`n$stderr" }
  $text = ($output -join "`n")

  if ($text.Length -gt 1800) {
    return $text.Substring(0, 1800) + "`n...output truncated"
  }
  return $text
}
