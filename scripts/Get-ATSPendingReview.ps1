[CmdletBinding()]
param(
    [ValidateSet('Object', 'Json', 'Markdown')]
    [string]$Format = 'Markdown',

    [string]$QueuePath = '',

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
if ([string]::IsNullOrWhiteSpace($QueuePath)) { $QueuePath = Join-Path $RootPath 'state\pending-proposals.json' }

if (-not (Test-Path -LiteralPath $QueuePath -PathType Leaf)) {
    throw "Proposal queue not found: $QueuePath"
}

function Get-ATSPropertyValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return [string]$property.Value
}

function Get-ATSSourceLabel {
    param(
        [AllowEmptyString()][string]$SourceType,
        [AllowEmptyString()][string]$SourceLink
    )

    switch ($SourceType.Trim().ToLowerInvariant()) {
        'meeting_note' {
            $fileName = if ([string]::IsNullOrWhiteSpace($SourceLink)) { '' } else { Split-Path -Leaf $SourceLink }
            if ([string]::IsNullOrWhiteSpace($fileName)) { return 'Meeting note' }
            return "Meeting note - $fileName"
        }
        'teams_chat' { return 'Teams chat' }
        'teams_channel' { return 'Teams channel' }
        'teams_meeting_chat' { return 'Teams meeting chat' }
        'teams_transcript' { return 'Teams transcript' }
        'meeting_transcript' { return 'Meeting transcript' }
        'outlook_email' { return 'Email' }
        'outlook_calendar' { return 'Calendar' }
        'manual_entry' { return 'Manual entry' }
        '' { return 'Not specified' }
        default {
            $words = $SourceType.Replace('_', ' ').Trim()
            return (Get-Culture).TextInfo.ToTitleCase($words.ToLowerInvariant())
        }
    }
}

$queue = Get-Content -LiteralPath $QueuePath -Raw | ConvertFrom-Json
$pending = @($queue.proposals | Where-Object status -eq 'pending' | Sort-Object created_at, proposal_id)
$result = @($pending | ForEach-Object {
    $sourceType = Get-ATSPropertyValue -Object $_ -Name 'source_type'
    $sourceLink = Get-ATSPropertyValue -Object $_ -Name 'source_link'
    [pscustomobject][ordered]@{
        proposal_id = $_.proposal_id
        kind = $_.kind
        direction = $_.direction
        direction_label = if ($_.direction -eq 'me_to_stakeholder') { 'By you' } elseif ($_.direction -eq 'stakeholder_to_me') { 'To you' } else { 'Unresolved' }
        stakeholder = $_.stakeholder
        commitment = $_.commitment
        due_date = $_.due_date
        target_commitment_id = $_.target_commitment_id
        evidence = $_.evidence
        source_type = $sourceType
        source_label = Get-ATSSourceLabel -SourceType $sourceType -SourceLink $sourceLink
        source_datetime = Get-ATSPropertyValue -Object $_ -Name 'source_datetime'
        source_link = $sourceLink
    }
})

switch ($Format) {
    'Json' {
        [ordered]@{ proposal_count = $result.Count; proposals = $result } | ConvertTo-Json -Depth 6
    }
    'Markdown' {
        '# ATS pending review'
        ''
        "Pending proposals: $($result.Count)"
        ''
        if ($result.Count -eq 0) {
            'No pending proposals.'
            break
        }
        for ($index = 0; $index -lt $result.Count; $index += 1) {
            $item = $result[$index]
            $due = if ([string]::IsNullOrWhiteSpace($item.due_date)) { 'Not specified' } else { $item.due_date }
            $target = if ([string]::IsNullOrWhiteSpace($item.target_commitment_id)) { '' } else { " | Target: $($item.target_commitment_id)" }
            "$($index + 1). $($item.proposal_id) | $($item.kind.ToUpperInvariant()) | $($item.direction_label) | $($item.stakeholder) | Due: $due$target"
            "   $($item.commitment)"
            "   Source: $($item.source_label)"
            "   Evidence: $($item.evidence)"
            ''
        }
        'Decide with proposal IDs, for example:'
        '.\scripts\Invoke-ATS.ps1 decide -Approve <ID> -Reject <ID>'
    }
    default { $result }
}
