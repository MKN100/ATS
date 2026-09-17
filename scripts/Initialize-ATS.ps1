[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = [IO.Path]::GetFullPath($RootPath)
$exampleRoot = Join-Path $RootPath 'config\examples'
$dataRoot = Join-Path $RootPath 'data'
$stateRoot = Join-Path $RootPath 'state'
$created = [Collections.Generic.List[string]]::new()
$preserved = [Collections.Generic.List[string]]::new()

foreach ($requiredExample in @('commitments.csv', 'meeting-note-folders.json', 'scan-schedule.json')) {
    $examplePath = Join-Path $exampleRoot $requiredExample
    if (-not (Test-Path -LiteralPath $examplePath -PathType Leaf)) {
        throw "ATS example configuration was not found: $examplePath"
    }
}

foreach ($directory in @($dataRoot, $stateRoot, (Join-Path $stateRoot 'decision-audit'), (Join-Path $RootPath 'backups'))) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($directory, 'create directory')) {
            [void][IO.Directory]::CreateDirectory($directory)
            $created.Add($directory)
        }
    }
}

$seedFiles = [ordered]@{
    (Join-Path $dataRoot 'commitments.csv') = Join-Path $exampleRoot 'commitments.csv'
    (Join-Path $dataRoot 'meeting-note-folders.json') = Join-Path $exampleRoot 'meeting-note-folders.json'
    (Join-Path $dataRoot 'scan-schedule.json') = Join-Path $exampleRoot 'scan-schedule.json'
}
foreach ($targetPath in $seedFiles.Keys) {
    if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
        $preserved.Add($targetPath)
        continue
    }
    if ($PSCmdlet.ShouldProcess($targetPath, 'create from example')) {
        Copy-Item -LiteralPath $seedFiles[$targetPath] -Destination $targetPath
        $created.Add($targetPath)
    }
}

$queuePath = Join-Path $stateRoot 'pending-proposals.json'
if (Test-Path -LiteralPath $queuePath -PathType Leaf) {
    $preserved.Add($queuePath)
}
elseif ($PSCmdlet.ShouldProcess($queuePath, 'create empty proposal queue')) {
    $queueJson = [ordered]@{ version = 1; proposals = @(); rejections = @() } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($queuePath, $queueJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $created.Add($queuePath)
}

[pscustomobject]@{
    root = $RootPath
    created = @($created)
    preserved = @($preserved)
}
