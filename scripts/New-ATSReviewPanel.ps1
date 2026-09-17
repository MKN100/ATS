param(
    [string]$QueuePath = '',

    [string]$OutputPath = '',

    [string]$ScanLabel = 'latest scan',

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

function Encode-Html {
    param([AllowEmptyString()][string]$Value)

    [Net.WebUtility]::HtmlEncode($Value)
}

if (-not (Test-Path -LiteralPath $QueuePath -PathType Leaf)) {
    throw "Proposal queue not found: $QueuePath"
}

$reviewScript = Join-Path $PSScriptRoot 'Get-ATSPendingReview.ps1'
$pending = @(& $reviewScript -Format Object -QueuePath $QueuePath -RootPath $RootPath)
if ($pending.Count -eq 0) {
    [ordered]@{ proposal_count = 0; path = $null } | ConvertTo-Json
    exit 0
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $visualizationDirectory = Join-Path $RootPath 'outputs\reviews'
    $runSuffix = (Get-Date).ToString('yyyyMMdd-HHmmssfff')
    $OutputPath = Join-Path $visualizationDirectory "ats-review-$runSuffix.html"
}

$sections = [System.Collections.Generic.List[string]]::new()
$payloadItems = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $pending.Count; $index += 1) {
    $proposal = $pending[$index]
    $proposalId = Get-Value -Object $proposal -Name 'proposal_id'
    $kind = Get-Value -Object $proposal -Name 'kind'
    $kindLabel = (Get-Culture).TextInfo.ToTitleCase($kind)
    $stakeholder = Get-Value -Object $proposal -Name 'stakeholder'
    $commitment = Get-Value -Object $proposal -Name 'commitment'
    $direction = Get-Value -Object $proposal -Name 'direction'
    $dueDate = Get-Value -Object $proposal -Name 'due_date'
    $evidence = Get-Value -Object $proposal -Name 'evidence'
    $target = Get-Value -Object $proposal -Name 'target_commitment_id'
    $sourceType = Get-Value -Object $proposal -Name 'source_type'
    $sourceLabel = Get-Value -Object $proposal -Name 'source_label'
    $sourceDatetime = Get-Value -Object $proposal -Name 'source_datetime'
    $directionLabel = switch ($direction) {
        'me_to_stakeholder' { 'By you -> ' + $stakeholder }
        'stakeholder_to_me' { 'To you <- ' + $stakeholder }
        default { $stakeholder }
    }
    $timing = if ([string]::IsNullOrWhiteSpace($dueDate)) { 'Due: not specified' } else { 'Due: ' + $dueDate }
    $targetLabel = if ([string]::IsNullOrWhiteSpace($target)) { '' } else { ' | ' + $target }
    $separator = if ($index -eq 0) { '' } else { "`n    <hr>`n" }
    $section = @"
$separator    <section aria-labelledby="proposal-$proposalId-title">
      <h3 id="proposal-$proposalId-title">$(Encode-Html "$kindLabel | $directionLabel")</h3>
      <p>$(Encode-Html $commitment)</p>
      <p class="text-small text-muted">$(Encode-Html ($timing + $targetLabel))</p>
      <p class="text-small text-muted">$(Encode-Html ('Source: ' + $sourceLabel))</p>
      <p class="text-small text-muted">$(Encode-Html ('Evidence: ' + $evidence))</p>
      <div class="viz-row" role="radiogroup" aria-label="Decision for proposal $proposalId">
        <label class="form-check"><input class="form-check-input" type="radio" name="$proposalId" value="APPROVE"><span class="form-check-label">Approve</span></label>
        <label class="form-check"><input class="form-check-input" type="radio" name="$proposalId" value="REJECT"><span class="form-check-label">Reject</span></label>
        <label class="form-check"><input class="form-check-input" type="radio" name="$proposalId" value="PENDING" checked><span class="form-check-label">Later</span></label>
      </div>
    </section>
"@
    $sections.Add($section)
    $payloadItems.Add([ordered]@{
        id = $proposalId
        description = "$($kind.ToUpperInvariant()) | $direction | $stakeholder | $commitment | due $dueDate | target $target | source $sourceLabel ($sourceType) $sourceDatetime"
    })
}

$payloadJson = ConvertTo-Json -InputObject @($payloadItems) -Compress -Depth 4
$payloadJson = $payloadJson.Replace('</', '<\/')
$fragment = @'
<div id="ats-generated-review" aria-labelledby="ats-generated-title">
  <h2 id="ats-generated-title">ATS review</h2>
  <p class="text-small text-muted">__SCAN_LABEL__ | __COUNT__ proposals | nothing changes until you submit</p>
  <form id="ats-generated-form">
__SECTIONS__
    <div class="viz-row ats-submit-row">
      <button class="btn btn-primary" type="submit">Submit decisions</button>
      <span id="ats-generated-status" class="text-small text-muted" aria-live="polite">All left for later</span>
    </div>
    <p id="ats-generated-error" class="text-small text-destructive" role="alert" hidden></p>
  </form>
</div>

<style>
  #ats-generated-review,
  #ats-generated-form,
  #ats-generated-review section {
    display: grid;
    gap: 8px;
  }

  #ats-generated-review h2,
  #ats-generated-review h3,
  #ats-generated-review p {
    margin: 0;
  }

  #ats-generated-review .ats-submit-row {
    margin-top: 4px;
  }
</style>

<script>
  (() => {
    const root = document.getElementById('ats-generated-review');
    const form = document.getElementById('ats-generated-form');
    const status = document.getElementById('ats-generated-status');
    const error = document.getElementById('ats-generated-error');
    const proposals = __PAYLOAD__;

    function selections() {
      return proposals.map((proposal) => ({
        ...proposal,
        decision: form.elements[proposal.id].value
      }));
    }

    function updateStatus() {
      const decided = selections().filter((item) => item.decision !== 'PENDING').length;
      status.textContent = decided === 0
        ? 'All left for later'
        : decided + ' decision' + (decided === 1 ? '' : 's') + ' ready';
    }

    form.addEventListener('change', updateStatus);
    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      error.hidden = true;
      const choices = selections();
      const decided = choices.filter((item) => item.decision !== 'PENDING');
      if (decided.length === 0) {
        error.textContent = 'Choose Approve or Reject for at least one proposal.';
        error.hidden = false;
        return;
      }
      const lines = choices.map((item) => item.id + ' | ' + item.decision + ' | ' + item.description);
      try {
        await window.openai.sendFollowUpMessage({
          title: 'Submit ' + decided.length + ' ATS decision' + (decided.length === 1 ? '' : 's') + '?',
          prompt: 'Process this ATS decision batch. Apply APPROVE items, reject and suppress REJECT items, and make no change to PENDING items. Do not ask for item-by-item confirmation.\n\n' + lines.join('\n')
        });
      } catch (submitError) {
        error.textContent = 'The decisions could not be sent. Please try again.';
        error.hidden = false;
      }
    });
  })();
</script>
'@

$fragment = $fragment.Replace('__SCAN_LABEL__', (Encode-Html $ScanLabel))
$fragment = $fragment.Replace('__COUNT__', [string]$pending.Count)
$fragment = $fragment.Replace('__SECTIONS__', ($sections -join "`n"))
$fragment = $fragment.Replace('__PAYLOAD__', $payloadJson)

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$temporaryPath = "$OutputPath.$([guid]::NewGuid().ToString('N')).tmp"
[IO.File]::WriteAllText($temporaryPath, $fragment, [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporaryPath -Destination $OutputPath -Force

[ordered]@{
    proposal_count = $pending.Count
    path = $OutputPath
} | ConvertTo-Json
