[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('all', 'open', 'overdue', 'soon-due', 'deletion-candidates', 'review', 'status', 'scan-plan', 'decide')]
    [string]$Command = 'open',

    [string[]]$Approve = @(),

    [string[]]$Reject = @(),

    [switch]$Json,

    [switch]$DryRun,

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
$format = if ($Json) { 'Json' } else { 'Markdown' }

switch ($Command) {
    { $_ -in @('all', 'open', 'overdue', 'soon-due', 'deletion-candidates') } {
        & (Join-Path $PSScriptRoot 'Get-ATSCommitments.ps1') -View $Command -Format $format -RootPath $RootPath
        break
    }
    'review' {
        & (Join-Path $PSScriptRoot 'Get-ATSPendingReview.ps1') -Format $format -RootPath $RootPath
        break
    }
    'scan-plan' {
        & (Join-Path $PSScriptRoot 'Get-ATSScanPlan.ps1') -RootPath $RootPath
        break
    }
    'status' {
        $plan = & (Join-Path $PSScriptRoot 'Get-ATSScanPlan.ps1') -RootPath $RootPath | ConvertFrom-Json
        $statePath = Join-Path $RootPath 'state\scan-state.json'
        $state = if (Test-Path -LiteralPath $statePath -PathType Leaf) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
        [ordered]@{ root = $RootPath; plan = $plan; state = $state } | ConvertTo-Json -Depth 8
        break
    }
    'decide' {
        if ($Approve.Count -eq 0 -and $Reject.Count -eq 0) {
            throw 'decide requires at least one proposal ID in -Approve or -Reject.'
        }
        & (Join-Path $PSScriptRoot 'Apply-ATSDecisionBatch.ps1') -Approve $Approve -Reject $Reject -DryRun:$DryRun -RootPath $RootPath
        break
    }
}
