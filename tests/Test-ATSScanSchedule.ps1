[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ATS {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$plannerPath = Join-Path $projectRoot 'scripts\Get-ATSScanPlan.ps1'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$temporaryRoot = Join-Path $temporaryBase ("ats-scan-schedule-test-{0}" -f [guid]::NewGuid().ToString('N'))

try {
    $dataRoot = Join-Path $temporaryRoot 'data'
    $stateRoot = Join-Path $temporaryRoot 'state'
    [void][IO.Directory]::CreateDirectory($dataRoot)
    [void][IO.Directory]::CreateDirectory($stateRoot)

    $schedulePath = Join-Path $dataRoot 'scan-schedule.json'
    $schedule = [ordered]@{
        format_version = 1
        timezone = 'Australia/Perth'
        checkpoint_interval_minutes = 120
        checkpoint_anchor_local = '00:30'
        overlap_minutes = 30
    }
    [IO.File]::WriteAllText($schedulePath, ($schedule | ConvertTo-Json -Depth 4))

    $now = [datetimeoffset]'2026-09-17T11:41:00+08:00'
    $initial = & $plannerPath -Now $now -RootPath $temporaryRoot | ConvertFrom-Json
    Assert-ATS ($initial.is_due -eq $true) 'A workspace with no state should be due.'
    Assert-ATS ($initial.checkpoint -eq '2026-09-17T10:30:00.0000000+08:00') 'Expected the latest two-hour checkpoint.'
    Assert-ATS ($initial.next_checkpoint -eq '2026-09-17T12:30:00.0000000+08:00') 'Expected the next two-hour checkpoint.'
    Assert-ATS ($initial.schedule.overlap_minutes -eq 30) 'Expected configured 30-minute overlap.'
    Assert-ATS ($initial.health.stale_sources.Count -eq 4) 'Sources without watermarks should be stale.'

    $statePath = Join-Path $stateRoot 'scan-state.json'
    $state = [ordered]@{
        version = 2
        timezone = 'Australia/Perth'
        last_attempt_at = '2026-09-17T10:31:00+08:00'
        last_successful_scan_at = '2026-09-17T10:30:00+08:00'
        last_completed_checkpoint_at = '2026-09-17T10:30:00+08:00'
        last_run_status = 'success'
        last_duration_seconds = 10
        last_stage_durations = [ordered]@{ collection_seconds = 3; classification_seconds = 6; review_seconds = 1 }
        last_proposal_count = 0
        last_error = $null
        sources = [ordered]@{
            teams = [ordered]@{ watermark = '2026-09-17T10:30:00+08:00'; status = 'success' }
            outlook = [ordered]@{ watermark = '2026-09-17T10:30:00+08:00'; status = 'success' }
            meetings = [ordered]@{ watermark = '2026-09-17T10:30:00+08:00'; status = 'success' }
            meeting_notes = [ordered]@{ watermark = '2026-09-17T10:30:00+08:00'; status = 'success' }
        }
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 7))

    $current = & $plannerPath -Now $now -StatePath $statePath -RootPath $temporaryRoot | ConvertFrom-Json
    Assert-ATS ($current.is_due -eq $false) 'The completed 10:30 checkpoint should not be due at 11:41.'
    Assert-ATS ($current.sources.teams.scan_from -eq '2026-09-17T10:00:00.0000000+08:00') 'Expected 30-minute Teams overlap.'
    Assert-ATS ($current.sources.teams.watermark_stale -eq $false) 'A recent Teams watermark should be healthy.'
    Assert-ATS ($current.health.stale_sources.Count -eq 0) 'No source should be stale within two checkpoints.'

    $boundary = & $plannerPath -Now '2026-09-17T12:30:00+08:00' -StatePath $statePath -RootPath $temporaryRoot | ConvertFrom-Json
    Assert-ATS ($boundary.is_due -eq $true) 'The 12:30 checkpoint should become due at its boundary.'
    Assert-ATS ($boundary.checkpoint -eq '2026-09-17T12:30:00.0000000+08:00') 'Expected exact boundary checkpoint.'

    $override = & $plannerPath -Now $now -StatePath $statePath -RootPath $temporaryRoot -OverlapMinutes 45 | ConvertFrom-Json
    Assert-ATS ($override.schedule.overlap_minutes -eq 45) 'Expected explicit overlap override.'
    Assert-ATS ($override.sources.teams.scan_from -eq '2026-09-17T09:45:00.0000000+08:00') 'Expected overridden Teams overlap.'

    $stale = & $plannerPath -Now '2026-09-17T15:00:00+08:00' -StatePath $statePath -RootPath $temporaryRoot | ConvertFrom-Json
    Assert-ATS ($stale.sources.teams.watermark_stale -eq $true) 'A watermark older than two checkpoints should be stale.'
    Assert-ATS ($stale.health.stale_sources.Count -eq 4) 'Expected all four old watermarks in the stale-source list.'

    Write-Output 'ATS scan-schedule tests passed.'
}
finally {
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    $expectedPrefix = $temporaryBase + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $resolvedTemporaryRoot
    if ($resolvedTemporaryRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith('ats-scan-schedule-test-')) {
        if (Test-Path -LiteralPath $resolvedTemporaryRoot) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
        }
    }
    else {
        throw "Refusing to remove unexpected test path: $resolvedTemporaryRoot"
    }
}
