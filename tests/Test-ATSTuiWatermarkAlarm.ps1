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
$tuiPath = Join-Path $projectRoot 'scripts\Start-ATSTui.ps1'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$temporaryRoot = Join-Path $temporaryBase ("ats-tui-watermark-test-{0}" -f [guid]::NewGuid().ToString('N'))

try {
    $dataRoot = Join-Path $temporaryRoot 'data'
    $stateRoot = Join-Path $temporaryRoot 'state'
    [void][IO.Directory]::CreateDirectory($dataRoot)
    [void][IO.Directory]::CreateDirectory($stateRoot)
    Copy-Item -LiteralPath (Join-Path $projectRoot 'config\examples\commitments.csv') -Destination (Join-Path $dataRoot 'commitments.csv')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'config\examples\scan-schedule.json') -Destination (Join-Path $dataRoot 'scan-schedule.json')
    [IO.File]::WriteAllText(
        (Join-Path $stateRoot 'pending-proposals.json'),
        ([ordered]@{ version = 1; proposals = @(); rejections = @() } | ConvertTo-Json -Depth 4)
    )

    $now = [datetimeoffset]::Now.ToOffset([timespan]::FromHours(8))
    $recent = $now.AddHours(-1).ToString('o')
    $stale = $now.AddHours(-5).ToString('o')
    $failedAttempt = $now.AddMinutes(-20).ToString('o')
    $state = [ordered]@{
        version = 3
        timezone = 'Australia/Perth'
        last_attempt_at = $failedAttempt
        last_successful_scan_at = $recent
        last_completed_checkpoint_at = $recent
        last_run_status = 'failure'
        last_duration_seconds = 30
        last_stage_durations = [ordered]@{ collection_seconds = 10; classification_seconds = 15; review_seconds = 5 }
        last_proposal_count = 0
        last_error = 'Outlook connector failed.'
        sources = [ordered]@{
            teams = [ordered]@{ watermark = $recent; status = 'success'; last_attempt_at = $recent }
            outlook = [ordered]@{ watermark = $stale; status = 'failed'; last_attempt_at = $failedAttempt }
            meetings = [ordered]@{ watermark = $recent; status = 'success'; last_attempt_at = $recent }
            meeting_notes = [ordered]@{ watermark = $null; status = 'not_run' }
        }
    }
    $statePath = Join-Path $stateRoot 'scan-state.json'
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 7))

    $alarm = & $tuiPath -RootPath $temporaryRoot -HealthCheck | ConvertFrom-Json
    Assert-ATS ($alarm.watermark_alarm_active -eq $true) 'Expected an active watermark alarm.'
    Assert-ATS ($alarm.watermark_alarm.Contains('Outlook email [failed]:')) 'The alarm should identify the failed Outlook source.'
    Assert-ATS ($alarm.watermark_alarm -like '*last success*') 'The alarm should show the last successful watermark.'
    Assert-ATS ($alarm.watermark_alarm -like '*last failed attempt*') 'The alarm should show when the connector last failed.'
    Assert-ATS ($alarm.watermark_alarm.Contains('Meeting notes [not_run]: never advanced')) 'The alarm should identify an uninitialised source.'

    $state.last_run_status = 'success'
    $state.last_error = $null
    foreach ($name in @('teams', 'outlook', 'meetings', 'meeting_notes')) {
        $state.sources[$name].watermark = $recent
        $state.sources[$name].status = 'success'
        $state.sources[$name].last_attempt_at = $recent
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 7))

    $healthy = & $tuiPath -RootPath $temporaryRoot -HealthCheck | ConvertFrom-Json
    Assert-ATS ($healthy.watermark_alarm_active -eq $false) 'The alarm should disappear when all watermarks are healthy.'
    Assert-ATS ([string]::IsNullOrWhiteSpace([string]$healthy.watermark_alarm)) 'A healthy dashboard should not render alarm text.'

    Write-Output 'ATS TUI watermark-alarm tests passed.'
}
finally {
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    $expectedPrefix = $temporaryBase + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $resolvedTemporaryRoot
    if ($resolvedTemporaryRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith('ats-tui-watermark-test-')) {
        if (Test-Path -LiteralPath $resolvedTemporaryRoot) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
        }
    }
    else {
        throw "Refusing to remove unexpected test path: $resolvedTemporaryRoot"
    }
}
