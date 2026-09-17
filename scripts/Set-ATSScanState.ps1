param(
    [Parameter(Mandatory)]
    [ValidateSet('started', 'success', 'failure')]
    [string]$Outcome,

    [Parameter(Mandatory)]
    [datetimeoffset]$CheckpointAt,

    [ValidateSet('full', 'source_recovery')]
    [string]$RunScope = 'full',

    [datetimeoffset]$ScanThrough = [datetimeoffset]::Now,

    [datetimeoffset]$AttemptAt = [datetimeoffset]::Now,

    [ValidateRange(0, 86400)]
    [int]$DurationSeconds = 0,

    [ValidateRange(0, 86400)]
    [int]$CollectionSeconds = 0,

    [ValidateRange(0, 86400)]
    [int]$ClassificationSeconds = 0,

    [ValidateRange(0, 86400)]
    [int]$ReviewSeconds = 0,

    [ValidateRange(0, 10000)]
    [int]$ProposalCount = 0,

    [ValidateSet('not_run', 'success', 'partial', 'failed')]
    [string]$TeamsStatus = 'not_run',

    [ValidateSet('not_run', 'success', 'partial', 'failed')]
    [string]$OutlookStatus = 'not_run',

    [ValidateSet('not_run', 'success', 'partial', 'failed')]
    [string]$MeetingsStatus = 'not_run',

    [ValidateSet('not_run', 'success', 'partial', 'failed')]
    [string]$MeetingNotesStatus = 'not_run',

    [string]$TeamsScanFrom,

    [ValidateRange(-1, 10000)]
    [int]$TeamsResultCount = -1,

    [switch]$TeamsCoverageAssumedAtLimit,

    [string]$ErrorSummary,

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

$stateDirectory = Split-Path -Parent $StatePath
if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
}

if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
}
else {
    $state = [pscustomobject]@{
        version = 3
        timezone = 'Australia/Perth'
        last_attempt_at = $null
        last_successful_scan_at = $null
        last_completed_checkpoint_at = $null
        last_run_status = 'never_run'
        last_duration_seconds = $null
        last_stage_durations = [pscustomobject]@{
            collection_seconds = 0
            classification_seconds = 0
            review_seconds = 0
        }
        last_proposal_count = 0
        last_error = $null
        sources = [pscustomobject]@{
            teams = [pscustomobject]@{ watermark = $null; status = 'not_run' }
            outlook = [pscustomobject]@{ watermark = $null; status = 'not_run' }
            meetings = [pscustomobject]@{ watermark = $null; status = 'not_run' }
            meeting_notes = [pscustomobject]@{ watermark = $null; status = 'not_run' }
        }
    }
}

$sourceStatuses = [ordered]@{
    teams = $TeamsStatus
    outlook = $OutlookStatus
    meetings = $MeetingsStatus
    meeting_notes = $MeetingNotesStatus
}

if ($RunScope -eq 'source_recovery') {
    $recoveredSources = @($sourceStatuses.GetEnumerator() | Where-Object Value -ne 'not_run')
    if ($recoveredSources.Count -eq 0) {
        throw 'RunScope=source_recovery requires at least one source status.'
    }
}
elseif ($Outcome -eq 'success') {
    $notRunSources = @($sourceStatuses.GetEnumerator() | Where-Object Value -eq 'not_run' | ForEach-Object Key)
    if ($notRunSources.Count -gt 0) {
        throw "A successful full scan must record a terminal status for every source. Not run: $($notRunSources -join ', ')."
    }
}

$state.version = 3
if ($null -eq $state.PSObject.Properties['sources']) {
    $state | Add-Member -NotePropertyName sources -NotePropertyValue ([pscustomobject]@{})
}
foreach ($sourceName in @('teams', 'outlook', 'meetings', 'meeting_notes')) {
    if ($null -eq $state.sources.PSObject.Properties[$sourceName]) {
        $state.sources | Add-Member -NotePropertyName $sourceName -NotePropertyValue ([pscustomobject]@{
            watermark = $null
            status = 'not_run'
        })
    }
}

$state.last_attempt_at = $AttemptAt.ToString('o')
$stageDurations = [pscustomobject]@{
    collection_seconds = $CollectionSeconds
    classification_seconds = $ClassificationSeconds
    review_seconds = $ReviewSeconds
}
if ($RunScope -eq 'full') {
    $state.last_run_status = $Outcome
    $state.last_duration_seconds = $DurationSeconds
    if ($null -eq $state.PSObject.Properties['last_stage_durations']) {
        $state | Add-Member -NotePropertyName last_stage_durations -NotePropertyValue $stageDurations
    }
    else {
        $state.last_stage_durations = $stageDurations
    }
    $state.last_error = if ([string]::IsNullOrWhiteSpace($ErrorSummary)) { $null } else { $ErrorSummary }
}
else {
    $sourceRecovery = [pscustomobject]@{
        attempted_at = $AttemptAt.ToString('o')
        outcome = $Outcome
        duration_seconds = $DurationSeconds
        stage_durations = $stageDurations
        proposal_count = $ProposalCount
        error = if ([string]::IsNullOrWhiteSpace($ErrorSummary)) { $null } else { $ErrorSummary }
    }
    if ($null -eq $state.PSObject.Properties['last_source_recovery']) {
        $state | Add-Member -NotePropertyName last_source_recovery -NotePropertyValue $sourceRecovery
    }
    else {
        $state.last_source_recovery = $sourceRecovery
    }
}

foreach ($entry in $sourceStatuses.GetEnumerator()) {
    if ($entry.Value -eq 'not_run') { continue }

    $source = $state.sources.PSObject.Properties[$entry.Key].Value
    $previousWatermark = if ([string]::IsNullOrWhiteSpace($source.watermark)) { $null } else { [string]$source.watermark }
    $source.status = $entry.Value
    foreach ($property in @{
        last_attempt_at = $AttemptAt.ToString('o')
        last_scan_to = $ScanThrough.ToString('o')
        previous_watermark = $previousWatermark
        watermark_advanced = ($entry.Value -eq 'success')
    }.GetEnumerator()) {
        if ($null -eq $source.PSObject.Properties[$property.Key]) {
            $source | Add-Member -NotePropertyName $property.Key -NotePropertyValue $property.Value
        }
        else {
            $source.($property.Key) = $property.Value
        }
    }
    if ($entry.Value -eq 'success') {
        $source.watermark = $ScanThrough.ToString('o')
        if ($null -eq $source.PSObject.Properties['watermark_advanced_at']) {
            $source | Add-Member -NotePropertyName watermark_advanced_at -NotePropertyValue $AttemptAt.ToString('o')
        }
        else {
            $source.watermark_advanced_at = $AttemptAt.ToString('o')
        }
    }
}

if ($TeamsStatus -ne 'not_run') {
    $teams = $state.sources.teams
    $teamsScanFromValue = if ([string]::IsNullOrWhiteSpace($TeamsScanFrom)) { $null } else {
        [datetimeoffset]::Parse(
            $TeamsScanFrom,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToString('o')
    }
    $teamsMetadata = [ordered]@{
        last_scan_from = $teamsScanFromValue
        last_result_count = if ($TeamsResultCount -lt 0) { $null } else { $TeamsResultCount }
        coverage_assumption = if ($TeamsCoverageAssumedAtLimit) { 'configured_result_limit' } else { $null }
    }
    foreach ($property in $teamsMetadata.GetEnumerator()) {
        if ($null -eq $teams.PSObject.Properties[$property.Key]) {
            $teams | Add-Member -NotePropertyName $property.Key -NotePropertyValue $property.Value
        }
        else {
            $teams.($property.Key) = $property.Value
        }
    }
}

if ($RunScope -eq 'full' -and $Outcome -eq 'success') {
    $state.last_successful_scan_at = $ScanThrough.ToString('o')
    $state.last_completed_checkpoint_at = $CheckpointAt.ToString('o')
    $state.last_proposal_count = $ProposalCount
}

$temporaryPath = "$StatePath.tmp"
$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
Move-Item -LiteralPath $temporaryPath -Destination $StatePath -Force
$state | ConvertTo-Json -Depth 6
