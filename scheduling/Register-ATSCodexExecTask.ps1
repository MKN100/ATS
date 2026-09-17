[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$TaskName = 'ATS-CodexExec'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = [IO.Path]::GetFullPath($RootPath)
$launcherPath = Join-Path $RootPath 'scripts\Start-ATSScheduledScan.ps1'
$schedulePath = Join-Path $RootPath 'data\scan-schedule.json'
foreach ($requiredPath in @($launcherPath, $schedulePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Scheduled-scan file was not found: $requiredPath"
    }
}
$schedule = Get-Content -LiteralPath $schedulePath -Raw | ConvertFrom-Json
if ($schedule.format_version -ne 1 -or [string]$schedule.timezone -ne 'Australia/Perth') {
    throw 'Unsupported ATS scan schedule configuration.'
}
$intervalMinutes = [int]$schedule.checkpoint_interval_minutes
if ($intervalMinutes -lt 30 -or $intervalMinutes -gt 1440 -or (1440 % $intervalMinutes) -ne 0) {
    throw 'checkpoint_interval_minutes must be from 30 to 1440 and divide evenly into one day.'
}
$anchor = [datetime]::ParseExact(
    [string]$schedule.checkpoint_anchor_local,
    'HH:mm',
    [Globalization.CultureInfo]::InvariantCulture
)
$triggerStart = [datetime]::Today.Add($anchor.TimeOfDay)

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`" -RootPath `"$RootPath`""
)
$trigger = New-ScheduledTaskTrigger -Once -At $triggerStart -RepetitionInterval (New-TimeSpan -Minutes $intervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

if ($PSCmdlet.ShouldProcess("Scheduled Task '$TaskName'", 'register or update')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Runs ATS at each configured $intervalMinutes-minute scan checkpoint." -Force | Out-Null
    Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, TaskPath, State
}
