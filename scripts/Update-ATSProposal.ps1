param(
    [Parameter(Mandatory)]
    [ValidateSet('add', 'decide', 'list')]
    [string]$Action,

    [ValidateSet('add', 'update', 'close')]
    [string]$Kind,

    [string]$ProposalId,

    [ValidateSet('approved', 'rejected', 'applied', 'pending')]
    [string]$Decision,

    [string]$Direction,
    [string]$Stakeholder,
    [string]$Commitment,
    [string]$CommitmentDate,
    [string]$DueDate,
    [string]$ChangeSummary,
    [string]$NewDirection,
    [string]$NewStakeholder,
    [string]$NewCommitment,
    [string]$NewDueDate,
    [string]$NewStatus,
    [string]$SourceType,
    [string]$SourceDatetime,
    [string]$SourceLink,
    [string]$Evidence,
    [string]$TargetCommitmentId,
    [string]$Checkpoint,

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

function Save-Queue {
    param([Parameter(Mandatory)]$Queue)

    $directory = Split-Path -Parent $QueuePath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = "$QueuePath.tmp"
    $Queue | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $QueuePath -Force
}

if (Test-Path -LiteralPath $QueuePath -PathType Leaf) {
    $queue = Get-Content -LiteralPath $QueuePath -Raw | ConvertFrom-Json
}
else {
    $queue = [pscustomobject]@{ version = 1; proposals = @(); rejections = @() }
}

$queue.proposals = @($queue.proposals)
$queue.rejections = @($queue.rejections)
$now = [datetimeoffset]::Now
$rejectionCutoff = $now.AddDays(-30)
$queue.rejections = @($queue.rejections | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_.rejected_at) -and
    [datetimeoffset]::Parse(
        $_.rejected_at,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ) -ge $rejectionCutoff
})

switch ($Action) {
    'list' {
        $queue | ConvertTo-Json -Depth 8
        break
    }

    'add' {
        foreach ($required in @('Kind', 'Stakeholder', 'Commitment', 'Checkpoint')) {
            if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $required -ValueOnly))) {
                throw "$required is required for Action=add."
            }
        }

        $fingerprintInput = @(
            $Kind,
            $Direction.Trim().ToLowerInvariant(),
            $Stakeholder.Trim().ToLowerInvariant(),
            $Commitment.Trim().ToLowerInvariant(),
            $TargetCommitmentId.Trim().ToLowerInvariant(),
            $SourceType.Trim().ToLowerInvariant(),
            $SourceDatetime.Trim(),
            $SourceLink.Trim().ToLowerInvariant()
        ) -join '|'
        $hashBytes = [Text.Encoding]::UTF8.GetBytes($fingerprintInput)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($sha256.ComputeHash($hashBytes))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
        $prefix = switch ($Kind) { 'add' { 'A' }; 'update' { 'U' }; 'close' { 'C' } }
        $stableId = "$prefix-$($hash.Substring(0, 8))"

        $rejected = $queue.rejections | Where-Object fingerprint -eq $hash | Select-Object -First 1
        if ($null -ne $rejected) {
            [pscustomobject]@{ result = 'suppressed_rejection'; proposal_id = $stableId; fingerprint = $hash } |
                ConvertTo-Json -Depth 4
            break
        }

        $existing = $queue.proposals | Where-Object fingerprint -eq $hash | Select-Object -First 1
        if ($null -ne $existing) {
            [pscustomobject]@{ result = 'existing'; proposal = $existing } | ConvertTo-Json -Depth 8
            break
        }

        $proposal = [pscustomobject]@{
            proposal_id = $stableId
            fingerprint = $hash
            kind = $Kind
            status = 'pending'
            direction = $Direction
            stakeholder = $Stakeholder
            commitment = $Commitment
            commitment_date = $CommitmentDate
            due_date = $DueDate
            change_summary = $ChangeSummary
            new_direction = $NewDirection
            new_stakeholder = $NewStakeholder
            new_commitment = $NewCommitment
            new_due_date = $NewDueDate
            new_status = $NewStatus
            target_commitment_id = $TargetCommitmentId
            source_type = $SourceType
            source_datetime = $SourceDatetime
            source_link = $SourceLink
            evidence = $Evidence
            checkpoint = $Checkpoint
            created_at = $now.ToString('o')
            decided_at = $null
            applied_at = $null
        }
        $queue.proposals += $proposal
        Save-Queue -Queue $queue
        [pscustomobject]@{ result = 'added'; proposal = $proposal } | ConvertTo-Json -Depth 8
        break
    }

    'decide' {
        if ([string]::IsNullOrWhiteSpace($ProposalId) -or [string]::IsNullOrWhiteSpace($Decision)) {
            throw 'ProposalId and Decision are required for Action=decide.'
        }

        $proposal = $queue.proposals | Where-Object proposal_id -eq $ProposalId | Select-Object -First 1
        if ($null -eq $proposal) {
            throw "Unknown proposal: $ProposalId"
        }

        $proposal.status = $Decision
        if ($Decision -in @('approved', 'rejected')) {
            $proposal.decided_at = $now.ToString('o')
        }
        if ($Decision -eq 'applied') {
            $proposal.applied_at = $now.ToString('o')
        }
        if ($Decision -eq 'rejected') {
            $queue.rejections += [pscustomobject]@{
                fingerprint = $proposal.fingerprint
                proposal_id = $proposal.proposal_id
                rejected_at = $now.ToString('o')
            }
        }

        Save-Queue -Queue $queue
        [pscustomobject]@{ result = $Decision; proposal = $proposal } | ConvertTo-Json -Depth 8
        break
    }
}
