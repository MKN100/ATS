[CmdletBinding()]
param(
    [string]$RootPath = '',

    [switch]$HealthCheck
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

$script:RootPath = [IO.Path]::GetFullPath($RootPath)
$script:CliPath = Join-Path $PSScriptRoot 'Invoke-ATS.ps1'
$script:ProposalPath = Join-Path $PSScriptRoot 'Update-ATSProposal.ps1'
$script:PerthOffset = [timespan]::FromHours(8)

foreach ($requiredPath in @($script:CliPath, $script:ProposalPath, (Join-Path $script:RootPath 'data\commitments.csv'))) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required ATS file not found: $requiredPath"
    }
}

function Get-ATSJson {
    param([Parameter(Mandatory)][string]$Command)

    $output = @(& $script:CliPath $Command -Json -RootPath $script:RootPath) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($output)) {
        throw "ATS returned no data for '$Command'."
    }
    return $output | ConvertFrom-Json
}

function Clear-Tui {
    if (-not [Console]::IsOutputRedirected) {
        Clear-Host
    }
}

function Write-Title {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host 'ATS' -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor White
    Write-Host ('-' * 72) -ForegroundColor DarkGray
}

function Write-Label {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host ("{0,-14}" -f ($Name + ':')) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $Color
}

function Format-ATSTuiTimestamp {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $timestamp = [datetimeoffset]::Parse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    return $timestamp.ToOffset($script:PerthOffset).ToString('yyyy-MM-dd HH:mm') + ' AWST'
}

function Get-WatermarkAlarmText {
    param([Parameter(Mandatory)]$Status)

    $staleSources = @($Status.plan.health.stale_sources)
    if ($staleSources.Count -eq 0) { return '' }

    $displayNames = @{
        teams = 'Teams'
        outlook = 'Outlook email'
        meetings = 'Teams meetings'
        meeting_notes = 'Meeting notes'
    }
    $details = @($staleSources | ForEach-Object {
        $name = [string]$_
        $source = $Status.plan.sources.PSObject.Properties[$name].Value
        $displayName = if ($displayNames.ContainsKey($name)) { $displayNames[$name] } else { $name }
        $statusText = [string]$source.last_status
        $watermarkText = if ([string]::IsNullOrWhiteSpace([string]$source.watermark)) {
            'never advanced'
        }
        else {
            $age = if ($null -eq $source.watermark_age_hours) { '' } else { ' ({0:N1}h old)' -f [double]$source.watermark_age_hours }
            "last success $(Format-ATSTuiTimestamp -Value ([string]$source.watermark))$age"
        }

        $attemptText = ''
        if ($statusText -in @('partial', 'failed') -and $null -ne $Status.state -and $null -ne $Status.state.sources) {
            $stateSourceProperty = $Status.state.sources.PSObject.Properties[$name]
            if ($null -ne $stateSourceProperty) {
                $attemptProperty = $stateSourceProperty.Value.PSObject.Properties['last_attempt_at']
                if ($null -ne $attemptProperty -and -not [string]::IsNullOrWhiteSpace([string]$attemptProperty.Value)) {
                    $attemptText = "; last $statusText attempt $(Format-ATSTuiTimestamp -Value ([string]$attemptProperty.Value))"
                }
            }
        }
        "$displayName [$statusText]: $watermarkText$attemptText"
    })

    return 'WATERMARK ALARM - ' + ($details -join ' | ')
}

function Write-WatermarkAlarm {
    param([Parameter(Mandatory)]$Status)

    $text = Get-WatermarkAlarmText -Status $Status
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $hasFailedSource = @($Status.plan.health.stale_sources | Where-Object {
        [string]$Status.plan.sources.PSObject.Properties[[string]$_].Value.last_status -eq 'failed'
    }).Count -gt 0
    Write-Host $text -ForegroundColor $(if ($hasFailedSource) { [ConsoleColor]::Red } else { [ConsoleColor]::Yellow })
    Write-Host ''
}

function Wait-Tui {
    param([string]$Message = 'Press any key to return')

    Write-Host ''
    Write-Host $Message -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}

function Read-TuiChoice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][char[]]$Allowed
    )

    Write-Host $Prompt -NoNewline -ForegroundColor Yellow
    while ($true) {
        $key = [char]::ToLowerInvariant([Console]::ReadKey($true).KeyChar)
        if ($key -in $Allowed) {
            Write-Host $key
            return $key
        }
    }
}

function Read-DateValue {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [switch]$AllowBlank
    )

    while ($true) {
        $suffix = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
        $value = (Read-Host "$Prompt$suffix").Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            if (-not [string]::IsNullOrWhiteSpace($Default)) { return $Default }
            if ($AllowBlank) { return '' }
        }

        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact(
            $value,
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )) {
            return $value
        }
        Write-Host 'Use YYYY-MM-DD, or leave it blank when allowed.' -ForegroundColor Red
    }
}

function Invoke-DecisionBatch {
    param(
        [string[]]$Approve = @(),
        [string[]]$Reject = @()
    )

    $arguments = @{ RootPath = $script:RootPath }
    if ($Approve.Count -gt 0) { $arguments.Approve = $Approve }
    if ($Reject.Count -gt 0) { $arguments.Reject = $Reject }
    $output = @(& $script:CliPath decide @arguments) -join [Environment]::NewLine
    return $output | ConvertFrom-Json
}

function Show-Commitments {
    param(
        [Parameter(Mandatory)][string]$View,
        [Parameter(Mandatory)][string]$Title,
        [ValidateRange(1, 100)][int]$PageSize = 10
    )

    $result = Get-ATSJson -Command $View
    $items = @($result.commitments)
    $page = 0
    $pageCount = [Math]::Max(1, [Math]::Ceiling($items.Count / [double]$PageSize))

    while ($true) {
        Clear-Tui
        Write-Title -Text "$Title ($($items.Count))"
        if ($items.Count -eq 0) {
            Write-Host 'No commitments.' -ForegroundColor Green
            Wait-Tui
            return
        }

        $start = $page * $PageSize
        $end = [Math]::Min($start + $PageSize - 1, $items.Count - 1)
        for ($index = $start; $index -le $end; $index += 1) {
            $item = $items[$index]
            $due = if ([string]::IsNullOrWhiteSpace($item.due_date)) { 'Not specified' } else { $item.due_date }
            Write-Host ("{0}. {1} | {2} | Due {3}" -f ($index + 1), $item.direction_label, $item.stakeholder, $due) -ForegroundColor Cyan
            Write-Host ("   {0}" -f $item.commitment)
            Write-Host ("   {0}" -f $item.commitment_id) -ForegroundColor DarkGray
            Write-Host ''
        }

        Write-Host ("Page {0} of {1}  [N] Next  [P] Previous  [Q] Menu" -f ($page + 1), $pageCount) -ForegroundColor DarkGray
        $key = [char]::ToLowerInvariant([Console]::ReadKey($true).KeyChar)
        switch ($key) {
            'n' { if ($page -lt $pageCount - 1) { $page += 1 } }
            'p' { if ($page -gt 0) { $page -= 1 } }
            'q' { return }
        }
    }
}

function Show-ReviewSummary {
    param(
        [Parameter(Mandatory)][object[]]$Proposals,
        [Parameter(Mandatory)][hashtable]$Decisions
    )

    Clear-Tui
    Write-Title -Text 'Pending review - decision summary'
    foreach ($proposal in $Proposals) {
        $decision = $Decisions[$proposal.proposal_id]
        $color = switch ($decision) {
            'APPROVE' { [ConsoleColor]::Green }
            'REJECT' { [ConsoleColor]::Red }
            default { [ConsoleColor]::DarkGray }
        }
        Write-Host ("{0,-8} {1} | {2}" -f $decision, $proposal.proposal_id, $proposal.commitment) -ForegroundColor $color
    }
}

function Show-PendingReview {
    $result = Get-ATSJson -Command 'review'
    $proposals = @($result.proposals)
    if ($proposals.Count -eq 0) {
        Clear-Tui
        Write-Title -Text 'Pending review'
        Write-Host 'No pending proposals.' -ForegroundColor Green
        Wait-Tui
        return
    }

    $decisions = @{}
    foreach ($proposal in $proposals) {
        $decisions[$proposal.proposal_id] = 'LATER'
    }
    $index = 0

    while ($true) {
        $proposal = $proposals[$index]
        $due = if ([string]::IsNullOrWhiteSpace($proposal.due_date)) { 'Not specified' } else { $proposal.due_date }
        Clear-Tui
        Write-Title -Text ("Review {0} of {1}" -f ($index + 1), $proposals.Count)
        Write-Label -Name 'Proposal' -Value $proposal.proposal_id -Color Cyan
        Write-Label -Name 'Change' -Value $proposal.kind.ToUpperInvariant()
        Write-Label -Name 'Direction' -Value $proposal.direction_label
        Write-Label -Name 'Stakeholder' -Value $proposal.stakeholder
        Write-Label -Name 'Due' -Value $due
        Write-Label -Name 'Source' -Value $proposal.source_label
        if (-not [string]::IsNullOrWhiteSpace($proposal.target_commitment_id)) {
            Write-Label -Name 'Target' -Value $proposal.target_commitment_id
        }
        Write-Host ''
        Write-Host $proposal.commitment -ForegroundColor White
        Write-Host ''
        Write-Host 'Evidence' -ForegroundColor DarkGray
        Write-Host $proposal.evidence
        Write-Host ''
        Write-Host ("Current choice: {0}" -f $decisions[$proposal.proposal_id]) -ForegroundColor Yellow
        Write-Host '[A] Approve  [R] Reject  [L] Later  [<-] Previous  [->] Next  [S] Submit  [Q] Menu' -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'A' {
                $decisions[$proposal.proposal_id] = 'APPROVE'
                if ($index -lt $proposals.Count - 1) { $index += 1 }
            }
            'R' {
                $decisions[$proposal.proposal_id] = 'REJECT'
                if ($index -lt $proposals.Count - 1) { $index += 1 }
            }
            'L' {
                $decisions[$proposal.proposal_id] = 'LATER'
                if ($index -lt $proposals.Count - 1) { $index += 1 }
            }
            'LeftArrow' { if ($index -gt 0) { $index -= 1 } }
            'RightArrow' { if ($index -lt $proposals.Count - 1) { $index += 1 } }
            'Q' { return }
            'S' {
                $approved = @($proposals | Where-Object { $decisions[$_.proposal_id] -eq 'APPROVE' } | ForEach-Object proposal_id)
                $rejected = @($proposals | Where-Object { $decisions[$_.proposal_id] -eq 'REJECT' } | ForEach-Object proposal_id)
                Show-ReviewSummary -Proposals $proposals -Decisions $decisions
                if ($approved.Count -eq 0 -and $rejected.Count -eq 0) {
                    Wait-Tui -Message 'Nothing selected. Press any key to continue reviewing'
                    continue
                }
                $choice = Read-TuiChoice -Prompt ("Apply {0} approval(s) and {1} rejection(s)? [Y/N] " -f $approved.Count, $rejected.Count) -Allowed @('y', 'n')
                if ($choice -eq 'y') {
                    $applied = Invoke-DecisionBatch -Approve $approved -Reject $rejected
                    Write-Host ''
                    Write-Host ("Applied {0}; rejected {1}." -f @($applied.applied).Count, @($applied.rejected).Count) -ForegroundColor Green
                    Write-Host ("Audit: {0}" -f $applied.audit_id) -ForegroundColor DarkGray
                    Wait-Tui
                    return
                }
            }
        }
    }
}

function Add-ManualCommitment {
    while ($true) {
        Clear-Tui
        Write-Title -Text 'Add a commitment'
        Write-Host '[1] By you -> stakeholder'
        Write-Host '[2] To you <- stakeholder'
        Write-Host '[Q] Main menu'
        $directionChoice = Read-TuiChoice -Prompt 'Direction: ' -Allowed @('1', '2', 'q')
        if ($directionChoice -eq 'q') { return }

        $direction = if ($directionChoice -eq '1') { 'me_to_stakeholder' } else { 'stakeholder_to_me' }
        $stakeholder = (Read-Host 'Stakeholder').Trim()
        if ([string]::IsNullOrWhiteSpace($stakeholder)) {
            Write-Host 'Stakeholder is required.' -ForegroundColor Red
            Wait-Tui -Message 'Press any key to try again'
            continue
        }
        $commitment = (Read-Host 'Commitment').Trim()
        if ([string]::IsNullOrWhiteSpace($commitment)) {
            Write-Host 'Commitment is required.' -ForegroundColor Red
            Wait-Tui -Message 'Press any key to try again'
            continue
        }

        $now = [datetimeoffset]::Now.ToOffset($script:PerthOffset)
        $commitmentDate = Read-DateValue -Prompt 'Commitment date' -Default $now.ToString('yyyy-MM-dd')
        $dueDate = Read-DateValue -Prompt 'Due date' -AllowBlank

        Clear-Tui
        Write-Title -Text 'Confirm new commitment'
        Write-Label -Name 'Direction' -Value $(if ($direction -eq 'me_to_stakeholder') { 'By you' } else { 'To you' })
        Write-Label -Name 'Stakeholder' -Value $stakeholder
        Write-Label -Name 'Committed' -Value $commitmentDate
        Write-Label -Name 'Due' -Value $(if ($dueDate) { $dueDate } else { 'Not specified' })
        Write-Host ''
        Write-Host $commitment
        Write-Host ''
        $choice = Read-TuiChoice -Prompt 'Add this commitment? [Y/N] ' -Allowed @('y', 'n')
        if ($choice -ne 'y') { continue }

        $timestamp = $now.ToString('o')
        $proposalArguments = @{
            Action = 'add'
            Kind = 'add'
            Direction = $direction
            Stakeholder = $stakeholder
            Commitment = $commitment
            CommitmentDate = $commitmentDate
            DueDate = $dueDate
            SourceType = 'manual_entry'
            SourceDatetime = $timestamp
            Evidence = 'Entered and confirmed manually in the ATS TUI.'
            Checkpoint = $timestamp
            RootPath = $script:RootPath
        }
        $proposalOutput = @(& $script:ProposalPath @proposalArguments) -join [Environment]::NewLine
        $proposalResult = $proposalOutput | ConvertFrom-Json
        if ($proposalResult.result -eq 'suppressed_rejection') {
            Write-Host 'This exact commitment was recently rejected and was not re-added.' -ForegroundColor Yellow
            Wait-Tui -Message 'Press any key to add another commitment'
            continue
        }

        $proposal = $proposalResult.proposal
        if ($proposal.status -eq 'applied') {
            Write-Host 'This commitment is already in the register.' -ForegroundColor Yellow
            Wait-Tui -Message 'Press any key to add another commitment'
            continue
        }
        if ($proposal.status -ne 'pending') {
            throw "The matching proposal is '$($proposal.status)' and cannot be applied."
        }

        $applied = Invoke-DecisionBatch -Approve @($proposal.proposal_id)
        Write-Host ("Added. Audit: {0}" -f $applied.audit_id) -ForegroundColor Green
        $nextChoice = Read-TuiChoice -Prompt '[A] Add another  [Q] Main menu: ' -Allowed @('a', 'q')
        if ($nextChoice -eq 'q') { return }
    }
}

function Complete-ManualCommitment {
    while ($true) {
        $result = Get-ATSJson -Command 'open'
        $items = @($result.commitments)
        Clear-Tui
        Write-Title -Text 'Mark a commitment completed'
        if ($items.Count -eq 0) {
            Write-Host 'No open commitments.' -ForegroundColor Green
            Wait-Tui
            return
        }

        for ($index = 0; $index -lt $items.Count; $index += 1) {
            $item = $items[$index]
            Write-Host ("{0,2}. {1} | {2}" -f ($index + 1), $item.stakeholder, $item.commitment)
        }
        Write-Host ''
        $selection = (Read-Host 'Number to complete, or Q for main menu').Trim()
        if ($selection -eq 'q') { return }
        $number = 0
        if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $items.Count) {
            Write-Host 'Invalid selection.' -ForegroundColor Red
            Wait-Tui -Message 'Press any key to try again'
            continue
        }

        $selected = $items[$number - 1]
        Write-Host ''
        Write-Host $selected.commitment -ForegroundColor White
        $choice = Read-TuiChoice -Prompt 'Mark this completed? [Y/N] ' -Allowed @('y', 'n')
        if ($choice -ne 'y') { continue }

        $queue = Get-Content -LiteralPath (Join-Path $script:RootPath 'state\pending-proposals.json') -Raw | ConvertFrom-Json
        $existingClose = $queue.proposals | Where-Object {
            $_.status -eq 'pending' -and $_.kind -eq 'close' -and $_.target_commitment_id -eq $selected.commitment_id
        } | Select-Object -First 1

        if ($null -ne $existingClose) {
            $proposalId = $existingClose.proposal_id
        }
        else {
            $now = [datetimeoffset]::Now.ToOffset($script:PerthOffset)
            $timestamp = $now.ToString('o')
            $proposalArguments = @{
                Action = 'add'
                Kind = 'close'
                Direction = $selected.direction
                Stakeholder = $selected.stakeholder
                Commitment = "Mark $($selected.commitment) as completed"
                CommitmentDate = $now.ToString('yyyy-MM-dd')
                DueDate = $selected.due_date
                TargetCommitmentId = $selected.commitment_id
                SourceType = 'manual_entry'
                SourceDatetime = $timestamp
                Evidence = 'Marked completed and confirmed manually in the ATS TUI.'
                Checkpoint = $timestamp
                RootPath = $script:RootPath
            }
            $proposalOutput = @(& $script:ProposalPath @proposalArguments) -join [Environment]::NewLine
            $proposalResult = $proposalOutput | ConvertFrom-Json
            if ($proposalResult.result -eq 'suppressed_rejection') {
                Write-Host 'This completion was recently rejected and was not applied.' -ForegroundColor Yellow
                Wait-Tui -Message 'Press any key to choose another commitment'
                continue
            }
            $proposalId = $proposalResult.proposal.proposal_id
        }

        $applied = Invoke-DecisionBatch -Approve @($proposalId)
        Write-Host ("Completed. Audit: {0}" -f $applied.audit_id) -ForegroundColor Green
        $nextChoice = Read-TuiChoice -Prompt '[C] Complete another  [Q] Main menu: ' -Allowed @('c', 'q')
        if ($nextChoice -eq 'q') { return }
    }
}

function Show-ScanStatus {
    $status = Get-ATSJson -Command 'status'
    Clear-Tui
    Write-Title -Text 'Scan status'
    Write-WatermarkAlarm -Status $status
    Write-Label -Name 'Last scan' -Value ([string]$status.plan.last_successful_scan)
    Write-Label -Name 'Result' -Value ([string]$status.plan.last_run_status)
    Write-Label -Name 'Duration' -Value ("{0} seconds" -f $status.plan.last_duration_seconds)
    Write-Label -Name 'Next check' -Value ([string]$status.plan.next_checkpoint)
    Write-Label -Name 'Due now' -Value ([string]$status.plan.is_due)
    Write-Host ''
    Write-Host 'Sources' -ForegroundColor DarkGray
    foreach ($name in @('teams', 'outlook', 'meetings', 'meeting_notes')) {
        $source = $status.plan.sources.$name
        Write-Host ("  {0,-10} {1}" -f $name, $source.last_status)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$status.plan.last_error)) {
        Write-Host ''
        Write-Host 'Note' -ForegroundColor DarkGray
        Write-Host $status.plan.last_error -ForegroundColor Yellow
    }
    Wait-Tui
}

function Show-MainMenu {
    while ($true) {
        $open = Get-ATSJson -Command 'open'
        $overdue = Get-ATSJson -Command 'overdue'
        $soonDue = Get-ATSJson -Command 'soon-due'
        $review = Get-ATSJson -Command 'review'
        $status = Get-ATSJson -Command 'status'

        Clear-Tui
        Write-Title -Text 'Personal commitment dashboard'
        Write-WatermarkAlarm -Status $status
        Write-Host ("Open {0}   Overdue {1}   Due soon {2}   Review {3}" -f $open.count, $overdue.count, $soonDue.count, $review.proposal_count) -ForegroundColor Cyan
        Write-Host ''
        Write-Host '[1] Open commitments'
        Write-Host '[2] Overdue commitments'
        Write-Host '[3] Due in the next 7 days'
        Write-Host '[4] Review proposals'
        Write-Host '[5] Add a commitment'
        Write-Host '[6] Mark completed'
        Write-Host '[7] Scan status'
        Write-Host '[8] Full history'
        Write-Host '[Q] Quit'
        Write-Host ''
        $choice = Read-TuiChoice -Prompt 'Choose: ' -Allowed @('1', '2', '3', '4', '5', '6', '7', '8', 'q')

        try {
            switch ($choice) {
                '1' { Show-Commitments -View 'open' -Title 'Open commitments' }
                '2' { Show-Commitments -View 'overdue' -Title 'Overdue commitments' }
                '3' { Show-Commitments -View 'soon-due' -Title 'Due in the next 7 days' }
                '4' { Show-PendingReview }
                '5' { Add-ManualCommitment }
                '6' { Complete-ManualCommitment }
                '7' { Show-ScanStatus }
                '8' { Show-Commitments -View 'all' -Title 'Full commitment history' }
                'q' { return }
            }
        }
        catch {
            Write-Host ''
            Write-Host $_.Exception.Message -ForegroundColor Red
            Wait-Tui
        }
    }
}

if ($HealthCheck) {
    $open = Get-ATSJson -Command 'open'
    $overdue = Get-ATSJson -Command 'overdue'
    $soonDue = Get-ATSJson -Command 'soon-due'
    $review = Get-ATSJson -Command 'review'
    $scanStatus = Get-ATSJson -Command 'status'
    $watermarkAlarm = Get-WatermarkAlarmText -Status $scanStatus
    [ordered]@{
        status = 'ok'
        root = $script:RootPath
        open = $open.count
        overdue = $overdue.count
        soon_due = $soonDue.count
        pending_review = $review.proposal_count
        watermark_alarm_active = -not [string]::IsNullOrWhiteSpace($watermarkAlarm)
        watermark_alarm = $watermarkAlarm
        stale_sources = @($scanStatus.plan.health.stale_sources)
    } | ConvertTo-Json
    return
}

Show-MainMenu
