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
$temporaryRoot = Join-Path $temporaryBase ("ats-tui-repeat-test-{0}" -f [guid]::NewGuid().ToString('N'))

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

    . $tuiPath -RootPath $temporaryRoot -HealthCheck | Out-Null

    function Clear-Tui {}
    function Write-Title { param([string]$Text) }
    function Write-Label { param([string]$Name, [string]$Value, [ConsoleColor]$Color) }
    function Wait-Tui { param([string]$Message) }
    function Read-DateValue {
        param([string]$Prompt, [string]$Default = '', [switch]$AllowBlank)
        if ($AllowBlank) { return '' }
        return $Default
    }
    function Read-TuiChoice {
        param([string]$Prompt, [char[]]$Allowed)
        if ($script:tuiChoices.Count -eq 0) { throw "No test choice remains for '$Prompt'." }
        $choice = [char]$script:tuiChoices.Dequeue()
        if ($choice -notin $Allowed) { throw "Test choice '$choice' is not allowed for '$Prompt'." }
        return $choice
    }
    function Read-Host {
        param([string]$Prompt)
        if ($script:tuiInputs.Count -eq 0) { throw "No test input remains for '$Prompt'." }
        return [string]$script:tuiInputs.Dequeue()
    }

    $script:tuiChoices = [Collections.Queue]::new()
    foreach ($choice in @('1', 'y', 'a', '2', 'y', 'q')) { $script:tuiChoices.Enqueue($choice) }
    $script:tuiInputs = [Collections.Queue]::new()
    foreach ($value in @('Alex', 'Prepare the draft', 'Jordan', 'Review the draft')) { $script:tuiInputs.Enqueue($value) }

    Add-ManualCommitment

    $rows = @(Import-Csv -LiteralPath (Join-Path $dataRoot 'commitments.csv'))
    Assert-ATS ($rows.Count -eq 2) 'The add submenu should accept two commitments in one session.'
    Assert-ATS (@($rows | Where-Object status -eq 'open').Count -eq 2) 'Both added commitments should be open.'
    Assert-ATS ($script:tuiChoices.Count -eq 0) 'The add submenu did not consume the expected repeat choices.'

    $script:tuiChoices = [Collections.Queue]::new()
    foreach ($choice in @('y', 'c', 'y', 'q')) { $script:tuiChoices.Enqueue($choice) }
    $script:tuiInputs = [Collections.Queue]::new()
    foreach ($value in @('1', '1')) { $script:tuiInputs.Enqueue($value) }

    Complete-ManualCommitment

    $rows = @(Import-Csv -LiteralPath (Join-Path $dataRoot 'commitments.csv'))
    Assert-ATS (@($rows | Where-Object status -eq 'completed').Count -eq 2) 'The completion submenu should complete two commitments in one session.'
    Assert-ATS ($script:tuiChoices.Count -eq 0) 'The completion submenu did not consume the expected repeat choices.'

    Write-Output 'ATS TUI repeat-action tests passed.'
}
finally {
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    $expectedPrefix = $temporaryBase + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $resolvedTemporaryRoot
    if ($resolvedTemporaryRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and $leaf.StartsWith('ats-tui-repeat-test-')) {
        if (Test-Path -LiteralPath $resolvedTemporaryRoot) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
        }
    }
    else {
        throw "Refusing to remove unexpected test path: $resolvedTemporaryRoot"
    }
}
