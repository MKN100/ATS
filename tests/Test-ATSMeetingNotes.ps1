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
$collectorPath = Join-Path $projectRoot 'scripts\Get-ATSMeetingNotes.ps1'
$stateScriptPath = Join-Path $projectRoot 'scripts\Set-ATSScanState.ps1'
$planScriptPath = Join-Path $projectRoot 'scripts\Get-ATSScanPlan.ps1'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$temporaryRoot = Join-Path $temporaryBase ("ats-meeting-notes-test-{0}" -f [guid]::NewGuid().ToString('N'))

try {
    $notesRoot = Join-Path $temporaryRoot 'notes'
    $archiveRoot = Join-Path $notesRoot 'archive'
    $dataRoot = Join-Path $temporaryRoot 'data'
    $stateRoot = Join-Path $temporaryRoot 'state'
    foreach ($directory in @($notesRoot, $archiveRoot, $dataRoot, $stateRoot)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }

    $recentNotePath = Join-Path $notesRoot 'current.md'
    $excludedNotePath = Join-Path $archiveRoot 'old.md'
    $nonMarkdownPath = Join-Path $notesRoot 'ignore.txt'
    [IO.File]::WriteAllText($recentNotePath, '# Current meeting')
    [IO.File]::WriteAllText($excludedNotePath, '# Archived meeting')
    [IO.File]::WriteAllText($nonMarkdownPath, 'Not a meeting note')

    $scanTo = [datetimeoffset]::UtcNow
    $scanFrom = $scanTo.AddHours(-1)
    [IO.File]::SetLastWriteTimeUtc($recentNotePath, $scanTo.AddMinutes(-5).UtcDateTime)
    [IO.File]::SetLastWriteTimeUtc($excludedNotePath, $scanTo.AddMinutes(-5).UtcDateTime)
    [IO.File]::SetLastWriteTimeUtc($nonMarkdownPath, $scanTo.AddMinutes(-5).UtcDateTime)

    $configPath = Join-Path $dataRoot 'meeting-note-folders.json'
    $config = [ordered]@{
        format_version = 1
        description = 'Test configuration'
        folders = @(
            [ordered]@{
                id = 'test-notes'
                path = $notesRoot
                enabled = $true
                include = @('**/*.md')
                exclude = @('archive/**')
            }
        )
    }
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 6))

    $result = & $collectorPath -RootPath $temporaryRoot -ConfigPath $configPath -ScanFrom $scanFrom.ToString('o') -ScanTo $scanTo.ToString('o') | ConvertFrom-Json
    Assert-ATS ($result.status -eq 'success') 'Expected successful meeting-note discovery.'
    Assert-ATS ($result.note_count -eq 1) 'Expected exactly one included Markdown note.'
    Assert-ATS ($result.notes[0].relative_path -eq 'current.md') 'Expected root-level Markdown matching.'
    Assert-ATS (-not [string]::IsNullOrWhiteSpace($result.notes[0].content_sha256)) 'Expected a content hash.'

    $config.folders += [ordered]@{
        id = 'missing-notes'
        path = (Join-Path $temporaryRoot 'missing')
        enabled = $true
        include = @('**/*.md')
        exclude = @()
    }
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 6))
    $partial = & $collectorPath -RootPath $temporaryRoot -ConfigPath $configPath -ScanFrom $scanFrom.ToString('o') -ScanTo $scanTo.ToString('o') | ConvertFrom-Json
    Assert-ATS ($partial.status -eq 'partial') 'Expected a missing enrolled folder to make discovery partial.'
    Assert-ATS (@($partial.warnings).Count -eq 1) 'Expected one missing-folder warning.'

    $statePath = Join-Path $stateRoot 'scan-state.json'
    $legacyState = [ordered]@{
        version = 1
        timezone = 'Australia/Perth'
        last_attempt_at = $null
        last_successful_scan_at = $null
        last_completed_checkpoint_at = $null
        last_run_status = 'never_run'
        last_duration_seconds = $null
        last_stage_durations = [ordered]@{ collection_seconds = 0; classification_seconds = 0; review_seconds = 0 }
        last_proposal_count = 0
        last_error = $null
        sources = [ordered]@{
            teams = [ordered]@{ watermark = $null; status = 'not_run' }
            outlook = [ordered]@{ watermark = $null; status = 'not_run' }
            meetings = [ordered]@{ watermark = $null; status = 'not_run' }
        }
    }
    [IO.File]::WriteAllText($statePath, ($legacyState | ConvertTo-Json -Depth 6))
    & $stateScriptPath -Outcome success -RunScope source_recovery -CheckpointAt $scanTo -ScanThrough $scanTo -MeetingNotesStatus success -StatePath $statePath -RootPath $temporaryRoot | Out-Null
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-ATS ($state.version -eq 3) 'Expected scan-state schema version 3.'
    Assert-ATS ($state.sources.meeting_notes.status -eq 'success') 'Expected meeting_notes success state.'
    Assert-ATS (-not [string]::IsNullOrWhiteSpace($state.sources.meeting_notes.watermark)) 'Expected meeting_notes watermark.'

    $plan = & $planScriptPath -Now $scanTo.AddMinutes(30) -StatePath $statePath -RootPath $temporaryRoot | ConvertFrom-Json
    Assert-ATS ($plan.sources.meeting_notes.last_status -eq 'success') 'Expected scan plan to expose meeting_notes state.'

    Write-Output 'ATS meeting-note ingestion tests passed.'
}
finally {
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    $expectedPrefix = $temporaryBase + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $resolvedTemporaryRoot
    if ($resolvedTemporaryRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith('ats-meeting-notes-test-')) {
        if (Test-Path -LiteralPath $resolvedTemporaryRoot) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
        }
    }
    else {
        throw "Refusing to remove unexpected test path: $resolvedTemporaryRoot"
    }
}
