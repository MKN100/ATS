param(
    [string[]]$Approve = @(),

    [string[]]$Reject = @(),

    [switch]$DryRun,

    [string]$QueuePath = '',

    [string]$RegisterPath = '',

    [string]$BackupDirectory = '',

    [string]$AuditDirectory = '',

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
if ([string]::IsNullOrWhiteSpace($RegisterPath)) { $RegisterPath = Join-Path $RootPath 'data\commitments.csv' }
if ([string]::IsNullOrWhiteSpace($BackupDirectory)) { $BackupDirectory = Join-Path $RootPath 'backups' }
if ([string]::IsNullOrWhiteSpace($AuditDirectory)) { $AuditDirectory = Join-Path $RootPath 'state\decision-audit' }

$startedAt = [datetimeoffset]::Now
$perthOffset = [timespan]::FromHours(8)
$columns = @(
    'commitment_id',
    'direction',
    'stakeholder',
    'commitment',
    'commitment_date',
    'due_date',
    'status',
    'source_type',
    'source_datetime',
    'source_link',
    'evidence',
    'first_seen_at',
    'last_updated_at',
    'notes'
)
$quotedColumns = @('stakeholder', 'commitment', 'source_link', 'evidence', 'notes')

function Get-Value {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    if ($property.Value -is [datetimeoffset]) {
        return $property.Value.ToString('o')
    }
    if ($property.Value -is [datetime]) {
        return ([datetimeoffset]$property.Value).ToString('o')
    }
    return [string]$property.Value
}

function ConvertFrom-ATSTimestamp {
    param([Parameter(Mandatory)][string]$Value)

    [datetimeoffset]::Parse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
}

function Get-SourceDate {
    param([Parameter(Mandatory)]$Proposal)

    foreach ($name in @('commitment_date', 'source_datetime', 'checkpoint')) {
        $value = Get-Value -Object $Proposal -Name $name
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        if ($name -eq 'commitment_date') {
            return $value
        }
        return (ConvertFrom-ATSTimestamp -Value $value).ToOffset($perthOffset).ToString('yyyy-MM-dd')
    }
    return [datetimeoffset]::Now.ToOffset($perthOffset).ToString('yyyy-MM-dd')
}

function Add-Note {
    param(
        [AllowEmptyString()][string]$Existing,
        [Parameter(Mandatory)][string]$Note
    )

    $trimmedNote = $Note.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedNote)) {
        return $Existing
    }
    if (-not [string]::IsNullOrWhiteSpace($Existing) -and $Existing.Contains($trimmedNote)) {
        return $Existing
    }
    if ([string]::IsNullOrWhiteSpace($Existing)) {
        return $trimmedNote
    }
    return "$($Existing.Trim()) $trimmedNote"
}

function Format-CsvField {
    param(
        [AllowNull()][object]$Value,
        [switch]$AlwaysQuote
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($AlwaysQuote -or $text.IndexOfAny([char[]]@(',', '"', "`r", "`n")) -ge 0) {
        return '"' + $text.Replace('"', '""') + '"'
    }
    return $text
}

function ConvertTo-RegisterLines {
    param([Parameter(Mandatory)][object[]]$Rows)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(($columns -join ','))
    foreach ($row in $Rows) {
        $fields = foreach ($column in $columns) {
            $value = Get-Value -Object $row -Name $column
            Format-CsvField -Value $value -AlwaysQuote:($column -in $quotedColumns)
        }
        $lines.Add(($fields -join ','))
    }
    return $lines.ToArray()
}

function Assert-Register {
    param([Parameter(Mandatory)][string]$Path)

    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) {
        throw 'The commitment register has no rows.'
    }
    $actualColumns = @($rows[0].PSObject.Properties.Name)
    if (($actualColumns -join '|') -ne ($columns -join '|')) {
        throw 'The commitment register header does not match the fixed schema.'
    }
    if (($rows.commitment_id | Sort-Object -Unique).Count -ne $rows.Count) {
        throw 'The commitment register contains duplicate IDs.'
    }
    if (@($rows | Where-Object direction -notin @('me_to_stakeholder', 'stakeholder_to_me')).Count -gt 0) {
        throw 'The commitment register contains an invalid direction.'
    }
    if (@($rows | Where-Object status -notin @('open', 'completed')).Count -gt 0) {
        throw 'The commitment register contains an invalid status.'
    }
    return $rows
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

$approveIds = @($Approve | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$rejectIds = @($Reject | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
if ($approveIds.Count -eq 0 -and $rejectIds.Count -eq 0) {
    throw 'Specify at least one proposal ID in -Approve or -Reject.'
}
if (@($approveIds | Where-Object { $_ -in $rejectIds }).Count -gt 0) {
    throw 'The same proposal cannot be both approved and rejected.'
}
if (-not (Test-Path -LiteralPath $QueuePath -PathType Leaf)) {
    throw "Proposal queue not found: $QueuePath"
}

$queue = Get-Content -LiteralPath $QueuePath -Raw | ConvertFrom-Json
$queue.proposals = @($queue.proposals)
$queue.rejections = @($queue.rejections)
$requestedIds = @($approveIds + $rejectIds)
$unknownIds = @($requestedIds | Where-Object { $_ -notin $queue.proposals.proposal_id })
if ($unknownIds.Count -gt 0) {
    throw "Unknown proposal ID(s): $($unknownIds -join ', ')"
}

$toApply = @()
$alreadyApplied = @()
foreach ($proposalId in $approveIds) {
    $proposal = $queue.proposals | Where-Object proposal_id -eq $proposalId | Select-Object -First 1
    if ($proposal.status -eq 'rejected') {
        throw "Proposal $proposalId was already rejected."
    }
    if ($proposal.status -eq 'applied') {
        $alreadyApplied += $proposalId
        continue
    }
    $toApply += $proposal
}

foreach ($proposalId in $rejectIds) {
    $proposal = $queue.proposals | Where-Object proposal_id -eq $proposalId | Select-Object -First 1
    if ($proposal.status -eq 'applied') {
        throw "Proposal $proposalId was already applied and cannot be rejected."
    }
}

$auditId = $null
$changedRows = 0
$now = [datetimeoffset]::Now.ToOffset($perthOffset)
$registerLines = $null

if ($toApply.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $RegisterPath -PathType Leaf)) {
        throw "Commitment register not found: $RegisterPath"
    }

    $rows = [System.Collections.ArrayList]@(Assert-Register -Path $RegisterPath)
    foreach ($proposal in $toApply) {
        switch ($proposal.kind) {
            'add' {
                $commitmentDate = Get-SourceDate -Proposal $proposal
                $commitmentId = "COM-$($commitmentDate.Replace('-', ''))-$($proposal.fingerprint.Substring(0, 8))"
                $existing = $rows | Where-Object commitment_id -eq $commitmentId | Select-Object -First 1
                if ($null -ne $existing) {
                    if ($existing.commitment -ne $proposal.commitment -or $existing.stakeholder -ne $proposal.stakeholder) {
                        throw "Commitment ID collision: $commitmentId"
                    }
                    continue
                }
                $rows.Add([pscustomobject][ordered]@{
                    commitment_id = $commitmentId
                    direction = Get-Value -Object $proposal -Name 'direction'
                    stakeholder = Get-Value -Object $proposal -Name 'stakeholder'
                    commitment = Get-Value -Object $proposal -Name 'commitment'
                    commitment_date = $commitmentDate
                    due_date = Get-Value -Object $proposal -Name 'due_date'
                    status = 'open'
                    source_type = Get-Value -Object $proposal -Name 'source_type'
                    source_datetime = Get-Value -Object $proposal -Name 'source_datetime'
                    source_link = Get-Value -Object $proposal -Name 'source_link'
                    evidence = Get-Value -Object $proposal -Name 'evidence'
                    first_seen_at = $now.ToString('o')
                    last_updated_at = $now.ToString('o')
                    notes = "Added after explicit approval of ATS proposal $($proposal.proposal_id)."
                }) | Out-Null
                $changedRows += 1
            }

            'close' {
                $target = $rows | Where-Object commitment_id -eq $proposal.target_commitment_id | Select-Object -First 1
                if ($null -eq $target) {
                    throw "Target commitment not found: $($proposal.target_commitment_id)"
                }
                $completionDate = Get-SourceDate -Proposal $proposal
                $sourceReference = "$(Get-Value -Object $proposal -Name 'source_type') $(Get-Value -Object $proposal -Name 'source_datetime')".Trim()
                $completionNote = "Completed on ${completionDate}: $(Get-Value -Object $proposal -Name 'evidence')"
                if (-not [string]::IsNullOrWhiteSpace($sourceReference)) {
                    $completionNote += " Source: $sourceReference."
                }
                if ($target.status -ne 'completed') {
                    $target.status = 'completed'
                    $changedRows += 1
                }
                $newNotes = Add-Note -Existing $target.notes -Note $completionNote
                if ($newNotes -ne $target.notes) {
                    $target.notes = $newNotes
                    $changedRows += 1
                }
                $target.last_updated_at = $now.ToString('o')
            }

            'update' {
                $target = $rows | Where-Object commitment_id -eq $proposal.target_commitment_id | Select-Object -First 1
                if ($null -eq $target) {
                    throw "Target commitment not found: $($proposal.target_commitment_id)"
                }
                $targetChanged = $false
                $newDirection = Get-Value -Object $proposal -Name 'new_direction'
                $newStakeholder = Get-Value -Object $proposal -Name 'new_stakeholder'
                $newCommitment = Get-Value -Object $proposal -Name 'new_commitment'
                $newDueDate = Get-Value -Object $proposal -Name 'new_due_date'
                $newStatus = Get-Value -Object $proposal -Name 'new_status'
                if (-not [string]::IsNullOrWhiteSpace($newDirection) -and $target.direction -ne $newDirection) { $target.direction = $newDirection; $targetChanged = $true }
                if (-not [string]::IsNullOrWhiteSpace($newStakeholder) -and $target.stakeholder -ne $newStakeholder) { $target.stakeholder = $newStakeholder; $targetChanged = $true }
                if (-not [string]::IsNullOrWhiteSpace($newCommitment) -and $target.commitment -ne $newCommitment) { $target.commitment = $newCommitment; $targetChanged = $true }
                if (-not [string]::IsNullOrWhiteSpace($newDueDate) -and $target.due_date -ne $newDueDate) { $target.due_date = $newDueDate; $targetChanged = $true }
                if (-not [string]::IsNullOrWhiteSpace($newStatus) -and $target.status -ne $newStatus) { $target.status = $newStatus; $targetChanged = $true }
                $changeSummary = Get-Value -Object $proposal -Name 'change_summary'
                if ([string]::IsNullOrWhiteSpace($changeSummary)) {
                    $changeSummary = Get-Value -Object $proposal -Name 'commitment'
                }
                $sourceReference = "$(Get-Value -Object $proposal -Name 'source_type') $(Get-Value -Object $proposal -Name 'source_datetime')".Trim()
                $progressNote = "Progress on $($now.ToString('yyyy-MM-dd')): $($changeSummary.Trim().TrimEnd('.'))."
                if (-not [string]::IsNullOrWhiteSpace($sourceReference)) {
                    $progressNote += " Source: $sourceReference."
                }
                $newNotes = Add-Note -Existing $target.notes -Note $progressNote
                if ($newNotes -ne $target.notes) {
                    $target.notes = $newNotes
                    $targetChanged = $true
                }
                if ($targetChanged) {
                    $target.last_updated_at = $now.ToString('o')
                    $changedRows += 1
                }
            }

            default {
                throw "Unsupported proposal kind: $($proposal.kind)"
            }
        }
    }

    $registerLines = @(ConvertTo-RegisterLines -Rows @($rows))
    $validationPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), "ats-$([guid]::NewGuid().ToString('N')).csv")
    try {
        [IO.File]::WriteAllLines($validationPath, $registerLines, [Text.UTF8Encoding]::new($false))
        Assert-Register -Path $validationPath | Out-Null
    }
    finally {
        if (Test-Path -LiteralPath $validationPath -PathType Leaf) {
            Remove-Item -LiteralPath $validationPath -Force
        }
    }
}

if (-not $DryRun) {
    foreach ($proposal in $toApply) {
        $proposal.status = 'applied'
        if ($null -eq $proposal.decided_at) {
            $proposal.decided_at = $now.ToString('o')
        }
        $proposal.applied_at = $now.ToString('o')
    }
    foreach ($proposalId in $rejectIds) {
        $proposal = $queue.proposals | Where-Object proposal_id -eq $proposalId | Select-Object -First 1
        if ($proposal.status -ne 'rejected') {
            $proposal.status = 'rejected'
            $proposal.decided_at = $now.ToString('o')
            $queue.rejections += [pscustomobject]@{
                fingerprint = $proposal.fingerprint
                proposal_id = $proposal.proposal_id
                rejected_at = $now.ToString('o')
            }
        }
    }
    [IO.Directory]::CreateDirectory($BackupDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($AuditDirectory) | Out-Null

    $auditId = "DEC-$($now.ToString('yyyyMMdd-HHmmssfff'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $registerBackupPath = if ($toApply.Count -gt 0) { Join-Path $BackupDirectory "$auditId-register.csv" } else { $null }
    $queueBackupPath = Join-Path $BackupDirectory "$auditId-proposals.json"
    $auditPath = Join-Path $AuditDirectory "$auditId.json"
    $temporaryRegister = if ($toApply.Count -gt 0) { "$RegisterPath.$auditId.tmp" } else { $null }
    $temporaryQueue = "$QueuePath.$auditId.tmp"
    $temporaryAudit = "$auditPath.tmp"

    if ($toApply.Count -gt 0) {
        Copy-Item -LiteralPath $RegisterPath -Destination $registerBackupPath
        [IO.File]::WriteAllLines($temporaryRegister, $registerLines, [Text.UTF8Encoding]::new($false))
        Assert-Register -Path $temporaryRegister | Out-Null
    }
    Copy-Item -LiteralPath $QueuePath -Destination $queueBackupPath
    Write-Utf8NoBom -Path $temporaryQueue -Content ($queue | ConvertTo-Json -Depth 10)

    $auditRecord = [ordered]@{
        audit_id = $auditId
        decided_at = $now.ToString('o')
        approved = @($toApply | ForEach-Object { $_.proposal_id })
        already_applied = $alreadyApplied
        rejected = $rejectIds
        changed_rows = $changedRows
        register_backup = $registerBackupPath
        queue_backup = $queueBackupPath
    }
    Write-Utf8NoBom -Path $temporaryAudit -Content ($auditRecord | ConvertTo-Json -Depth 5)

    try {
        if ($toApply.Count -gt 0) {
            Move-Item -LiteralPath $temporaryRegister -Destination $RegisterPath -Force
        }
        Move-Item -LiteralPath $temporaryQueue -Destination $QueuePath -Force
        Move-Item -LiteralPath $temporaryAudit -Destination $auditPath
    }
    catch {
        if ($toApply.Count -gt 0 -and (Test-Path -LiteralPath $registerBackupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $registerBackupPath -Destination $RegisterPath -Force
        }
        if (Test-Path -LiteralPath $queueBackupPath -PathType Leaf) {
            Copy-Item -LiteralPath $queueBackupPath -Destination $QueuePath -Force
        }
        if (Test-Path -LiteralPath $auditPath -PathType Leaf) {
            Remove-Item -LiteralPath $auditPath -Force
        }
        throw
    }
    finally {
        foreach ($temporaryPath in @($temporaryRegister, $temporaryQueue, $temporaryAudit)) {
            if (-not [string]::IsNullOrWhiteSpace($temporaryPath) -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
    }
}

[ordered]@{
    result = if ($DryRun) { 'dry_run' } else { 'success' }
    applied = @($toApply | ForEach-Object { $_.proposal_id })
    already_applied = $alreadyApplied
    rejected = $rejectIds
    changed_rows = $changedRows
    audit_id = $auditId
    duration_seconds = [math]::Round(([datetimeoffset]::Now - $startedAt).TotalSeconds, 2)
} | ConvertTo-Json -Depth 4
