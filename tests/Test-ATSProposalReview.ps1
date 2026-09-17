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
$reviewScript = Join-Path $projectRoot 'scripts\Get-ATSPendingReview.ps1'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$temporaryRoot = Join-Path $temporaryBase ("ats-proposal-review-test-{0}" -f [guid]::NewGuid().ToString('N'))

try {
    [void][IO.Directory]::CreateDirectory($temporaryRoot)
    $queuePath = Join-Path $temporaryRoot 'pending-proposals.json'
    $sourceCases = @(
        [ordered]@{ id = 'A-00000001'; type = 'meeting_note'; link = 'C:\Meeting Notes\kickoff.md'; expected = 'Meeting note - kickoff.md' }
        [ordered]@{ id = 'A-00000002'; type = 'teams_chat'; link = 'https://teams.example/message'; expected = 'Teams chat' }
        [ordered]@{ id = 'A-00000003'; type = 'outlook_email'; link = 'https://outlook.example/message'; expected = 'Email' }
        [ordered]@{ id = 'A-00000004'; type = 'outlook_calendar'; link = ''; expected = 'Calendar' }
        [ordered]@{ id = 'A-00000005'; type = 'manual_entry'; link = ''; expected = 'Manual entry' }
    )
    $proposals = @($sourceCases | ForEach-Object {
        [ordered]@{
            proposal_id = $_.id
            kind = 'add'
            status = 'pending'
            direction = 'me_to_stakeholder'
            stakeholder = 'Test stakeholder'
            commitment = 'Test commitment'
            due_date = ''
            target_commitment_id = ''
            evidence = 'Test evidence.'
            source_type = $_.type
            source_datetime = '2026-09-17T00:00:00Z'
            source_link = $_.link
            created_at = '2026-09-17T00:00:00Z'
        }
    })
    $queue = [ordered]@{ version = 1; proposals = $proposals; rejections = @() }
    [IO.File]::WriteAllText($queuePath, ($queue | ConvertTo-Json -Depth 7))

    $json = & $reviewScript -Format Json -QueuePath $queuePath -RootPath $temporaryRoot | ConvertFrom-Json
    Assert-ATS ($json.proposal_count -eq $sourceCases.Count) 'Expected all pending proposals in JSON review.'
    foreach ($sourceCase in $sourceCases) {
        $proposal = $json.proposals | Where-Object proposal_id -eq $sourceCase.id | Select-Object -First 1
        Assert-ATS ($null -ne $proposal) "Missing proposal $($sourceCase.id)."
        Assert-ATS ($proposal.source_label -eq $sourceCase.expected) "Unexpected source label for $($sourceCase.type)."
        Assert-ATS ($proposal.source_link -eq $sourceCase.link) "Source link was not preserved for $($sourceCase.type)."
    }

    $markdown = @(& $reviewScript -Format Markdown -QueuePath $queuePath -RootPath $temporaryRoot) -join [Environment]::NewLine
    foreach ($sourceCase in $sourceCases) {
        Assert-ATS ($markdown.Contains("Source: $($sourceCase.expected)")) "Markdown omitted source $($sourceCase.expected)."
    }

    Write-Output 'ATS proposal-source review tests passed.'
}
finally {
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    $expectedPrefix = $temporaryBase + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $resolvedTemporaryRoot
    if ($resolvedTemporaryRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith('ats-proposal-review-test-')) {
        if (Test-Path -LiteralPath $resolvedTemporaryRoot) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
        }
    }
    else {
        throw "Refusing to remove unexpected test path: $resolvedTemporaryRoot"
    }
}
