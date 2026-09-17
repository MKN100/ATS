[CmdletBinding()]
param(
    [string]$ScanFrom = '',

    [string]$ScanTo = '',

    [string]$ConfigPath = '',

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
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $RootPath 'data\meeting-note-folders.json'
}

function ConvertFrom-ATSTimestamp {
    param([Parameter(Mandatory)][string]$Value)

    [datetimeoffset]::Parse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
}

function Test-ATSGlob {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Pattern
    )

    $candidate = $RelativePath.Replace('\', '/')
    $normalizedPattern = $Pattern.Replace('\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedPattern)) { return $false }

    $patterns = @($normalizedPattern)
    if ($normalizedPattern.StartsWith('**/')) {
        $patterns += $normalizedPattern.Substring(3)
    }

    foreach ($item in $patterns) {
        $wildcard = [Management.Automation.WildcardPattern]::new(
            $item,
            [Management.Automation.WildcardOptions]::IgnoreCase
        )
        if ($wildcard.IsMatch($candidate)) { return $true }
    }
    return $false
}

function Test-ATSAnyGlob {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [AllowEmptyCollection()][object[]]$Patterns
    )

    foreach ($pattern in @($Patterns)) {
        if (Test-ATSGlob -RelativePath $RelativePath -Pattern ([string]$pattern)) {
            return $true
        }
    }
    return $false
}

function Get-ATSFileHash {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

$plan = $null
if ([string]::IsNullOrWhiteSpace($ScanFrom) -or [string]::IsNullOrWhiteSpace($ScanTo)) {
    $plan = & (Join-Path $PSScriptRoot 'Get-ATSScanPlan.ps1') -RootPath $RootPath | ConvertFrom-Json
}

$scanFromValue = if ([string]::IsNullOrWhiteSpace($ScanFrom)) {
    ConvertFrom-ATSTimestamp ([string]$plan.sources.meeting_notes.scan_from)
}
else {
    ConvertFrom-ATSTimestamp $ScanFrom
}
$scanToValue = if ([string]::IsNullOrWhiteSpace($ScanTo)) {
    ConvertFrom-ATSTimestamp ([string]$plan.sources.meeting_notes.scan_to)
}
else {
    ConvertFrom-ATSTimestamp $ScanTo
}
if ($scanFromValue -gt $scanToValue) {
    throw 'ScanFrom must be earlier than or equal to ScanTo.'
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Meeting-note folder register not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($config.format_version -ne 1) {
    throw "Unsupported meeting-note folder register format_version: $($config.format_version)"
}
if ($null -eq $config.PSObject.Properties['folders']) {
    throw "Meeting-note folder register has no 'folders' array: $ConfigPath"
}

$enabledFolders = @($config.folders | Where-Object { $_.enabled -eq $true })
$folderIds = @{}
$notes = @()
$warnings = @()
$successfulFolderCount = 0

foreach ($folder in $enabledFolders) {
    $folderId = ([string]$folder.id).Trim()
    $folderPathValue = ([string]$folder.path).Trim()
    if ([string]::IsNullOrWhiteSpace($folderId)) {
        throw 'Every enabled meeting-note folder requires a non-empty id.'
    }
    if ($folderIds.ContainsKey($folderId)) {
        throw "Duplicate enabled meeting-note folder id: $folderId"
    }
    $folderIds[$folderId] = $true
    if ([string]::IsNullOrWhiteSpace($folderPathValue) -or -not [IO.Path]::IsPathRooted($folderPathValue)) {
        throw "Meeting-note folder '$folderId' requires an absolute path."
    }

    $folderPath = [IO.Path]::GetFullPath($folderPathValue).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
        $warnings += "Folder '$folderId' is unavailable: $folderPath"
        continue
    }

    $includePatterns = if ($null -eq $folder.PSObject.Properties['include'] -or @($folder.include).Count -eq 0) {
        @('**/*.md')
    }
    else {
        @($folder.include)
    }
    $excludePatterns = if ($null -eq $folder.PSObject.Properties['exclude']) { @() } else { @($folder.exclude) }

    try {
        $files = @(Get-ChildItem -LiteralPath $folderPath -File -Recurse -ErrorAction Stop)
        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($folderPath.Length).TrimStart('\', '/').Replace('\', '/')
            if (-not (Test-ATSAnyGlob -RelativePath $relativePath -Patterns $includePatterns)) { continue }
            if (Test-ATSAnyGlob -RelativePath $relativePath -Patterns $excludePatterns) { continue }

            $lastWrite = [datetimeoffset]::new($file.LastWriteTimeUtc, [timespan]::Zero)
            if ($lastWrite -lt $scanFromValue.ToUniversalTime() -or $lastWrite -gt $scanToValue.ToUniversalTime()) {
                continue
            }

            $notes += [pscustomobject][ordered]@{
                folder_id = $folderId
                relative_path = $relativePath
                path = $file.FullName
                source_type = 'meeting_note'
                source_datetime = $lastWrite.ToString('o')
                source_link = $file.FullName
                size_bytes = $file.Length
                content_sha256 = Get-ATSFileHash -Path $file.FullName
            }
        }
        $successfulFolderCount += 1
    }
    catch {
        $warnings += "Folder '$folderId' could not be fully enumerated: $($_.Exception.Message)"
    }
}

$status = if ($enabledFolders.Count -eq 0 -or $successfulFolderCount -eq $enabledFolders.Count) {
    'success'
}
elseif ($successfulFolderCount -eq 0) {
    'failed'
}
else {
    'partial'
}

[ordered]@{
    source = 'meeting_notes'
    status = $status
    scan_from = $scanFromValue.ToString('o')
    scan_to = $scanToValue.ToString('o')
    configured_folder_count = @($config.folders).Count
    enabled_folder_count = $enabledFolders.Count
    successful_folder_count = $successfulFolderCount
    note_count = $notes.Count
    notes = @($notes | Sort-Object source_datetime, folder_id, relative_path)
    warnings = $warnings
} | ConvertTo-Json -Depth 6
