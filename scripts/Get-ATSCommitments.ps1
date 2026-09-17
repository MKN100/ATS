[CmdletBinding()]
param(
    [ValidateSet('all', 'open', 'overdue', 'soon-due', 'deletion-candidates')]
    [string]$View = 'open',

    [ValidateSet('Object', 'Json', 'Markdown')]
    [string]$Format = 'Object',

    [ValidateRange(1, 365)]
    [int]$SoonDueDays = 7,

    [datetimeoffset]$Now = [datetimeoffset]::Now,

    [string]$RegisterPath = '',

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
if ([string]::IsNullOrWhiteSpace($RegisterPath)) { $RegisterPath = Join-Path $RootPath 'data\commitments.csv' }

if (-not (Test-Path -LiteralPath $RegisterPath -PathType Leaf)) {
    throw "Commitment register not found: $RegisterPath"
}

$perthToday = $Now.ToOffset([timespan]::FromHours(8)).Date
$soonDueThrough = $perthToday.AddDays($SoonDueDays)
$rows = @(Import-Csv -LiteralPath $RegisterPath)
$selected = @($rows | Where-Object {
    $row = $_
    $dueDate = if ([string]::IsNullOrWhiteSpace($row.due_date)) { $null } else { [datetime]::ParseExact($row.due_date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    switch ($View) {
        'all' { $true }
        'open' { $row.status -eq 'open' }
        'overdue' { $row.status -eq 'open' -and $null -ne $dueDate -and $dueDate.Date -lt $perthToday }
        'soon-due' { $row.status -eq 'open' -and $null -ne $dueDate -and $dueDate.Date -ge $perthToday -and $dueDate.Date -le $soonDueThrough }
        'deletion-candidates' { $row.status -eq 'deletion_candidate' }
    }
})

$result = @($selected | Sort-Object due_date, commitment_id | ForEach-Object {
    [pscustomobject][ordered]@{
        commitment_id = $_.commitment_id
        direction = $_.direction
        direction_label = if ($_.direction -eq 'me_to_stakeholder') { 'By you' } else { 'To you' }
        stakeholder = $_.stakeholder
        commitment = $_.commitment
        due_date = $_.due_date
        status = $_.status
    }
})

switch ($Format) {
    'Json' {
        [ordered]@{ view = $View; count = $result.Count; commitments = $result } | ConvertTo-Json -Depth 5
    }
    'Markdown' {
        "# ATS commitments"
        ""
        "View: $View | Count: $($result.Count)"
        ""
        if ($result.Count -eq 0) {
            'No commitments.'
            break
        }
        '| ID | Direction | Stakeholder | Commitment | Due | Status |'
        '|---|---|---|---|---|---|'
        foreach ($item in $result) {
            $values = @($item.commitment_id, $item.direction_label, $item.stakeholder, $item.commitment, $(if ($item.due_date) { $item.due_date } else { 'Not specified' }), $item.status)
            $escaped = @($values | ForEach-Object { ([string]$_).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ') })
            '| ' + ($escaped -join ' | ') + ' |'
        }
    }
    default { $result }
}
