param(
    [ValidateSet('all', 'open', 'overdue', 'soon-due', 'deletion-candidates')]
    [string]$View = 'all',

    [datetime]$AsOf = (Get-Date),

    [ValidateRange(0, 365)]
    [int]$WithinDays = 7,

    [string]$RegisterPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RegisterPath)) {
    $skillRoot = Split-Path -Parent $PSScriptRoot
    $skillsRoot = Split-Path -Parent $skillRoot
    $agentsRoot = Split-Path -Parent $skillsRoot
    $projectRoot = Split-Path -Parent $agentsRoot
    $RegisterPath = Join-Path $projectRoot 'data\commitments.csv'
}

if (-not (Test-Path -LiteralPath $RegisterPath -PathType Leaf)) {
    throw "ATS register not found: $RegisterPath"
}

$asOfDate = $AsOf.Date
$soonThrough = $asOfDate.AddDays($WithinDays)
$rows = @(Import-Csv -LiteralPath $RegisterPath)

$items = foreach ($row in $rows) {
    $due = $null
    if (-not [string]::IsNullOrWhiteSpace($row.due_date)) {
        $due = [datetime]::ParseExact(
            $row.due_date,
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }

    $isOpen = $row.status -eq 'open'
    $isOverdue = $isOpen -and $null -ne $due -and $due -lt $asOfDate
    $isSoonDue = $isOpen -and $null -ne $due -and $due -ge $asOfDate -and $due -le $soonThrough

    $include = switch ($View) {
        'all' { $true }
        'open' { $isOpen }
        'overdue' { $isOverdue }
        'soon-due' { $isSoonDue }
        'deletion-candidates' { $row.status -eq 'deletion_candidate' }
    }

    if (-not $include) {
        continue
    }

    $timing = if (-not $isOpen) {
        $row.status
    }
    elseif ($null -eq $due) {
        'no_due_date'
    }
    elseif ($due -lt $asOfDate) {
        'overdue'
    }
    elseif ($due -eq $asOfDate) {
        'due_today'
    }
    elseif ($due -le $soonThrough) {
        'due_within_7_days'
    }
    else {
        'future'
    }

    [pscustomobject]@{
        commitment_id = $row.commitment_id
        direction = $row.direction
        stakeholder = $row.stakeholder
        commitment = $row.commitment
        due_date = $row.due_date
        status = $row.status
        timing = $timing
    }
}

[pscustomobject]@{
    view = $View
    as_of = $asOfDate.ToString('yyyy-MM-dd')
    count = @($items).Count
    commitments = @($items)
} | ConvertTo-Json -Depth 4
