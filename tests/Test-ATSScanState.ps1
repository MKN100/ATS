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
$stateScript = Join-Path $projectRoot 'scripts\Set-ATSScanState.ps1'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$temporaryRoot = Join-Path $temporaryBase ("ats-scan-state-test-{0}" -f [guid]::NewGuid().ToString('N'))

try {
    $stateRoot = Join-Path $temporaryRoot 'state'
    [void][IO.Directory]::CreateDirectory($stateRoot)
    $statePath = Join-Path $stateRoot 'scan-state.json'
    $initialState = [ordered]@{
        version = 2
        timezone = 'Australia/Perth'
        last_attempt_at = '2026-09-17T07:36:00+08:00'
        last_successful_scan_at = '2026-09-17T07:31:00+08:00'
        last_completed_checkpoint_at = '2026-09-17T06:30:00+08:00'
        last_run_status = 'success'
        last_duration_seconds = 20
        last_stage_durations = [ordered]@{ collection_seconds = 5; classification_seconds = 10; review_seconds = 5 }
        last_proposal_count = 1
        last_error = $null
        sources = [ordered]@{
            teams = [ordered]@{ watermark = '2026-09-07T14:01:35+08:00'; status = 'partial' }
            outlook = [ordered]@{ watermark = '2026-09-17T07:31:00+08:00'; status = 'success' }
            meetings = [ordered]@{ watermark = '2026-09-15T14:01:00+08:00'; status = 'partial' }
            meeting_notes = [ordered]@{ watermark = '2026-09-17T07:31:00+08:00'; status = 'success' }
        }
    }
    [IO.File]::WriteAllText($statePath, ($initialState | ConvertTo-Json -Depth 7))

    & $stateScript `
        -Outcome success `
        -RunScope source_recovery `
        -CheckpointAt '2026-09-17T10:30:00+08:00' `
        -ScanThrough '2026-09-17T12:11:08+08:00' `
        -AttemptAt '2026-09-17T12:15:00+08:00' `
        -TeamsStatus success `
        -TeamsScanFrom '2026-09-07T13:31:35+08:00' `
        -TeamsResultCount 100 `
        -TeamsCoverageAssumedAtLimit `
        -ProposalCount 3 `
        -StatePath $statePath `
        -RootPath $temporaryRoot | Out-Null

    $recovered = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-ATS ($recovered.version -eq 3) 'Expected state format version 3.'
    Assert-ATS ($recovered.last_completed_checkpoint_at -eq '2026-09-17T06:30:00+08:00') 'Source recovery must not complete a checkpoint.'
    Assert-ATS ($recovered.last_successful_scan_at -eq '2026-09-17T07:31:00+08:00') 'Source recovery must not replace the last full successful scan.'
    Assert-ATS ($recovered.sources.teams.watermark -eq '2026-09-17T12:11:08.0000000+08:00') 'Teams recovery should advance to the fixed scan boundary.'
    Assert-ATS ($recovered.sources.teams.previous_watermark -eq '2026-09-07T14:01:35+08:00') 'Expected the prior Teams watermark to be retained.'
    Assert-ATS ($recovered.sources.teams.last_result_count -eq 100) 'Expected the Teams result count in state.'
    Assert-ATS ($recovered.sources.teams.coverage_assumption -eq 'configured_result_limit') 'Expected the limit assumption in state.'
    Assert-ATS ($recovered.sources.outlook.watermark -eq '2026-09-17T07:31:00+08:00') 'Source recovery must not move Outlook.'
    Assert-ATS ($recovered.last_source_recovery.proposal_count -eq 3) 'Expected source-recovery proposal telemetry.'

    $fullSuccessRejected = $false
    try {
        & $stateScript `
            -Outcome success `
            -CheckpointAt '2026-09-17T12:30:00+08:00' `
            -ScanThrough '2026-09-17T12:31:00+08:00' `
            -TeamsStatus success `
            -OutlookStatus success `
            -MeetingsStatus partial `
            -MeetingNotesStatus not_run `
            -StatePath $statePath `
            -RootPath $temporaryRoot | Out-Null
    }
    catch {
        $fullSuccessRejected = $_.Exception.Message -like '*terminal status for every source*'
    }
    Assert-ATS $fullSuccessRejected 'A full successful scan with a not-run source should be rejected.'

    & $stateScript `
        -Outcome failure `
        -CheckpointAt '2026-09-17T12:30:00+08:00' `
        -ScanThrough '2026-09-17T13:00:00+08:00' `
        -AttemptAt '2026-09-17T13:01:00+08:00' `
        -TeamsStatus success `
        -OutlookStatus failed `
        -MeetingsStatus partial `
        -MeetingNotesStatus failed `
        -TeamsScanFrom '2026-09-17T11:41:08+08:00' `
        -TeamsResultCount 25 `
        -StatePath $statePath `
        -RootPath $temporaryRoot | Out-Null

    $partialRun = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-ATS ($partialRun.sources.teams.watermark -eq '2026-09-17T13:00:00.0000000+08:00') 'A successful source should advance even when the full run fails.'
    Assert-ATS ($partialRun.sources.outlook.watermark -eq '2026-09-17T07:31:00+08:00') 'A failed source must not advance.'
    Assert-ATS ($partialRun.last_completed_checkpoint_at -eq '2026-09-17T06:30:00+08:00') 'A failed full run must not complete a checkpoint.'

    Write-Output 'ATS scan-state tests passed.'
}
finally {
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    $expectedPrefix = $temporaryBase + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $resolvedTemporaryRoot
    if ($resolvedTemporaryRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith('ats-scan-state-test-')) {
        if (Test-Path -LiteralPath $resolvedTemporaryRoot) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
        }
    }
    else {
        throw "Refusing to remove unexpected test path: $resolvedTemporaryRoot"
    }
}
