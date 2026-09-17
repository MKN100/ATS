param(
    [datetimeoffset]$Now = [datetimeoffset]::Now,

    [ValidateRange(-1, 180)]
    [int]$OverlapMinutes = -1,

    [string]$SchedulePath = '',

    [string]$StatePath = '',

    [string]$RootPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = if ([string]::IsNullOrWhiteSpace($env:ATS_ROOT)) {
        Split-Path -Parent $PSScriptRoot
    }
    else {
        $env:ATS_ROOT
    }
}
$RootPath = [IO.Path]::GetFullPath($RootPath)
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Join-Path $RootPath 'state\scan-state.json' }
if ([string]::IsNullOrWhiteSpace($SchedulePath)) { $SchedulePath = Join-Path $RootPath 'data\scan-schedule.json' }

function ConvertFrom-ATSTimestamp {
    param([Parameter(Mandatory)][string]$Value)

    [datetimeoffset]::Parse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
}

$perthOffset = [timespan]::FromHours(8)
$localNow = $Now.ToOffset($perthOffset)
$today = $localNow.Date
$schedule = [ordered]@{
    format_version = 1
    timezone = 'Australia/Perth'
    checkpoint_interval_minutes = 120
    checkpoint_anchor_local = '00:30'
    overlap_minutes = 30
}
if (Test-Path -LiteralPath $SchedulePath -PathType Leaf) {
    $configuredSchedule = Get-Content -LiteralPath $SchedulePath -Raw | ConvertFrom-Json
    foreach ($name in @('format_version', 'timezone', 'checkpoint_interval_minutes', 'checkpoint_anchor_local', 'overlap_minutes')) {
        if ($null -eq $configuredSchedule.PSObject.Properties[$name]) {
            throw "Scan schedule is missing '$name': $SchedulePath"
        }
        $schedule[$name] = $configuredSchedule.$name
    }
}
if ([int]$schedule.format_version -ne 1) {
    throw "Unsupported scan-schedule format_version: $($schedule.format_version)"
}
if ([string]$schedule.timezone -ne 'Australia/Perth') {
    throw "Unsupported scan-schedule timezone: $($schedule.timezone)"
}
$intervalMinutes = [int]$schedule.checkpoint_interval_minutes
if ($intervalMinutes -lt 30 -or $intervalMinutes -gt 1440 -or (1440 % $intervalMinutes) -ne 0) {
    throw 'checkpoint_interval_minutes must be from 30 to 1440 and divide evenly into one day.'
}
$configuredOverlap = [int]$schedule.overlap_minutes
if ($configuredOverlap -lt 0 -or $configuredOverlap -gt 180) {
    throw 'overlap_minutes must be from 0 to 180.'
}
$effectiveOverlapMinutes = if ($OverlapMinutes -ge 0) { $OverlapMinutes } else { $configuredOverlap }
$anchorMatch = [regex]::Match([string]$schedule.checkpoint_anchor_local, '^(?<hour>[01]\d|2[0-3]):(?<minute>[0-5]\d)$')
if (-not $anchorMatch.Success) {
    throw 'checkpoint_anchor_local must use 24-hour HH:mm format.'
}
$anchorToday = [datetimeoffset]::new(
    $today.Year,
    $today.Month,
    $today.Day,
    [int]$anchorMatch.Groups['hour'].Value,
    [int]$anchorMatch.Groups['minute'].Value,
    0,
    $perthOffset
)
$elapsedMinutes = ($localNow - $anchorToday).TotalMinutes
$completedIntervals = [math]::Floor($elapsedMinutes / $intervalMinutes)
$latestCheckpoint = $anchorToday.AddMinutes($completedIntervals * $intervalMinutes)
$nextCheckpoint = $latestCheckpoint.AddMinutes($intervalMinutes)

$state = $null
if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
}

$lastCheckpoint = $null
if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.last_completed_checkpoint_at)) {
    $lastCheckpoint = ConvertFrom-ATSTimestamp $state.last_completed_checkpoint_at
}

$lastSuccess = $null
if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.last_successful_scan_at)) {
    $lastSuccess = ConvertFrom-ATSTimestamp $state.last_successful_scan_at
}

$isDue = $null -eq $lastCheckpoint -or $lastCheckpoint -lt $latestCheckpoint
$scanFrom = if ($null -eq $lastSuccess) {
    $localNow.AddHours(-24)
}
else {
    $lastSuccess.ToOffset($perthOffset).AddMinutes(-$effectiveOverlapMinutes)
}

$sourcePlans = [ordered]@{}
$staleAfterHours = ($intervalMinutes * 2) / 60
$staleSources = [Collections.Generic.List[string]]::new()
foreach ($sourceName in @('teams', 'outlook', 'meetings', 'meeting_notes')) {
    $sourceWatermark = $null
    $sourceProperty = $null
    if ($null -ne $state -and $null -ne $state.sources) {
        $sourceProperty = $state.sources.PSObject.Properties[$sourceName]
        if ($null -ne $sourceProperty) {
            $watermarkValue = $sourceProperty.Value.watermark
            if (-not [string]::IsNullOrWhiteSpace($watermarkValue)) {
                $sourceWatermark = ConvertFrom-ATSTimestamp $watermarkValue
            }
        }
    }

    $sourceFrom = if ($null -eq $sourceWatermark) {
        $localNow.AddHours(-24)
    }
    else {
        $sourceWatermark.ToOffset($perthOffset).AddMinutes(-$effectiveOverlapMinutes)
    }

    $watermarkAgeHours = if ($null -eq $sourceWatermark) {
        $null
    }
    else {
        [math]::Round(($localNow - $sourceWatermark.ToOffset($perthOffset)).TotalHours, 2)
    }
    $watermarkStale = $null -eq $sourceWatermark -or $watermarkAgeHours -gt $staleAfterHours
    if ($watermarkStale) { $staleSources.Add($sourceName) }

    $sourcePlans[$sourceName] = [ordered]@{
        scan_from = $sourceFrom.ToString('o')
        scan_to = $localNow.ToString('o')
        last_status = if ($null -eq $sourceProperty) { 'not_run' } else { $sourceProperty.Value.status }
        watermark = if ($null -eq $sourceWatermark) { $null } else { $sourceWatermark.ToOffset($perthOffset).ToString('o') }
        watermark_age_hours = $watermarkAgeHours
        watermark_stale = $watermarkStale
    }
}

[ordered]@{
    is_due = $isDue
    now = $localNow.ToString('o')
    checkpoint = $latestCheckpoint.ToString('o')
    next_checkpoint = $nextCheckpoint.ToString('o')
    last_completed_checkpoint = if ($null -eq $lastCheckpoint) { $null } else { $lastCheckpoint.ToOffset($perthOffset).ToString('o') }
    last_successful_scan = if ($null -eq $lastSuccess) { $null } else { $lastSuccess.ToOffset($perthOffset).ToString('o') }
    last_run_status = if ($null -eq $state) { 'never_run' } else { $state.last_run_status }
    last_duration_seconds = if ($null -eq $state) { $null } else { $state.last_duration_seconds }
    last_stage_durations = if ($null -eq $state -or $null -eq $state.PSObject.Properties['last_stage_durations']) { $null } else { $state.last_stage_durations }
    last_proposal_count = if ($null -eq $state) { 0 } else { $state.last_proposal_count }
    last_error = if ($null -eq $state) { $null } else { $state.last_error }
    scan_from = $scanFrom.ToString('o')
    scan_to = $localNow.ToString('o')
    catch_up_hours = [math]::Round(($localNow - $scanFrom).TotalHours, 2)
    schedule = [ordered]@{
        timezone = [string]$schedule.timezone
        checkpoint_interval_minutes = $intervalMinutes
        checkpoint_anchor_local = [string]$schedule.checkpoint_anchor_local
        overlap_minutes = $effectiveOverlapMinutes
    }
    health = [ordered]@{
        stale_after_hours = $staleAfterHours
        stale_sources = @($staleSources)
    }
    sources = $sourcePlans
} | ConvertTo-Json -Depth 5
