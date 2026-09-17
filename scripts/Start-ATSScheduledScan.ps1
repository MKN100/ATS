[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = [IO.Path]::GetFullPath($RootPath)
$designPath = Join-Path $RootPath 'docs\ATS_DESIGN.md'
$skillPath = Join-Path $RootPath '.agents\skills\ats\SKILL.md'
if (-not (Test-Path -LiteralPath $designPath -PathType Leaf) -or -not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
    throw "'$RootPath' is not an ATS workspace."
}

# The named mutex prevents overlapping runs. It is released automatically if a
# task process exits unexpectedly, unlike a lock file.
$mutex = [Threading.Mutex]::new($false, 'ATS-CodexExec-Scan')
if (-not $mutex.WaitOne(0)) {
    Write-Output 'ATS scheduled scan skipped: another scan is already running.'
    exit 0
}

try {
    $receiptPath = Join-Path $RootPath 'state\last-scheduled-receipt.md'
    $scanPlanScript = Join-Path $RootPath 'scripts\Get-ATSScanPlan.ps1'
    $plan = & $scanPlanScript -RootPath $RootPath | ConvertFrom-Json
    if (-not $plan.is_due) {
        $receipt = "ATS checkpoint not due. Next checkpoint: $($plan.next_checkpoint)."
        Set-Content -LiteralPath $receiptPath -Value $receipt -NoNewline
        Write-Output $receipt
        return
    }

    $codexPath = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'
    if (-not (Test-Path -LiteralPath $codexPath -PathType Leaf)) {
        $command = Get-Command codex -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            throw 'Codex CLI was not found. Install or repair the Codex desktop app before running this task.'
        }
        $codexPath = $command.Source
    }

    $prompt = @"
Use the ATS skill at '$skillPath' and the authoritative design at '$designPath'.
This is an unattended scheduled dispatcher for '$RootPath'. The PowerShell
launcher already established that a checkpoint is due. Perform the scheduled
    scan exactly as the local skill defines. Use the configured read-only Microsoft Teams, Outlook Email,
    and Outlook Calendar integrations, and run scripts/Get-ATSMeetingNotes.ps1
    for the enrolled local Markdown folders. Read and classify every note it
    returns for the planned interval. A scan may update only scan state and the
    pending-proposal queue; never edit data/commitments.csv or apply proposals.
Return the compact checkpoint receipt and pending review, if any.
"@

    & $codexPath exec --sandbox workspace-write --skip-git-repo-check --ephemeral --cd $RootPath --output-last-message $receiptPath $prompt
    if ($LASTEXITCODE -ne 0) {
        throw "codex exec exited with code $LASTEXITCODE."
    }
}
finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
