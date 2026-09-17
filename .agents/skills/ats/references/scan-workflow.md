# ATS scan workflow

Use this workflow only for a scheduled or explicitly requested manual scan.

## Plan and state

Run `<root>\scripts\Get-ATSScanPlan.ps1`.
A scheduled dispatcher exits quietly when `is_due` is false. A manual scan may
proceed even when no checkpoint is due. Before collection, record `started`
with `Set-ATSScanState.ps1`. On success or failure, update the state
again. Advance only sources that completed successfully.

The scan interval begins at the source watermark minus the overlap returned by
the planner. The configured routine overlap is 30 minutes. Never replace an
older watermark with a fixed 24-hour lookback.
For long gaps, page supported sources through bounded intervals until the
current scan boundary is reached. Teams follows the explicit 100-result
assumption policy below.

Review `plan.health.stale_sources` before collection and include stale sources
in the receipt. The planner marks a watermark stale after two checkpoint
intervals. A full successful run must give every source a terminal `success`,
`partial`, or `failed` status; `Set-ATSScanState.ps1` rejects checkpoint
completion while any source remains `not_run`.

## Fast collection without losing coverage

Start Teams, Outlook, meeting discovery, and local meeting-note discovery
independently and in parallel when the available tools permit it. For a routine
incremental interval, begin with these three connector calls and one local
command:

1. Teams `search` with an empty query, `sent_after` set to
   `plan.sources.teams.scan_from`, `include_channel_threads=true`, and
   `topn=100`.
2. Outlook `search_messages` once across the whole mailbox with date bounds and
   `size=500`, then discard items outside the exact timestamp interval locally.
   This global query includes received mail, sent mail, and custom folders; do
   not enumerate mail folders first. Follow `has_more` only when pagination is
   actually reported.
3. Outlook Calendar once for the exact interval to discover relevant meetings.
4. Run `<root>\scripts\Get-ATSMeetingNotes.ps1` with the `meeting_notes`
   `scan_from` and `scan_to` values from the scan plan.

The local command returns metadata for every changed Markdown file in enabled
folders from `data/meeting-note-folders.json`. Read and classify every returned
file; do not apply a keyword gate. Use `meeting_note` as the source type, the
file's `source_datetime`, and its absolute path as the source link. The file
hash and folder-relative path provide stable evidence identity across overlap.
If the command reports `partial` or `failed`, include its warnings and do not
advance the `meeting_notes` watermark. Do not inspect unenrolled folders.

Ignore meeting-recap links that are exposed only as unsupported Microsoft Loop
or SharePoint content. By explicit user decision on 17 September 2026, these
links are outside ATS coverage: do not retry them, do not report them as a
source warning, and do not hold back the meetings watermark solely because of
them. Mark meetings successful when all otherwise supported calendar, meeting
chat, and transcript evidence completes. Connector errors or incomplete
supported content still make meetings partial or failed.

Do not call profile, `list_chats`, `list_teams`, `list_channels`, or
`list_mail_folders` during a normal run. Use those only after an error, a result
with explicit incompleteness other than the configured Teams result limit, a
source warning, or an ambiguity that cannot be resolved from the primary
results. This keeps the Microsoft 365 common path to three connector calls.

Within the returned Teams results, keep all accessible direct messages, group
chats, channel messages, meeting chats, and transcripts eligible. Priority,
keywords, participant names, and channel importance may control ordering but
must not exclude returned content. Classify metadata and snippets in batches.
Fetch a full message, thread, email, or transcript only for a credible candidate
or when context is needed to decide whether a commitment exists. Batch full
email fetches and start independent context fetches together.

`topn=100` is an ATS request setting. By explicit user decision recorded on
17 September 2026, receiving all 100 requested Teams results is assumed to be
complete for operational purposes. Classify the returned results, mark Teams
successful, advance its watermark to `scan_to`, and include a concise receipt
note such as `Teams returned the configured 100-result limit; coverage assumed
complete by policy.` Do not use fallback enumeration solely because 100 results
were returned.

If the Teams connector reports an actual error or explicit incomplete condition
other than reaching the configured result count, mark the source partial or
failed without advancing its watermark.

On the terminal state update, pass `-TeamsScanFrom` using the planned Teams
interval, `-TeamsResultCount` using the returned count, and
`-TeamsCoverageAssumedAtLimit` when exactly 100 results were returned. For an
explicit Teams-only repair, also pass `-RunScope source_recovery`; this records
the evidence and advances only Teams without completing the scheduled
checkpoint. A successful source advances independently even when another
source or the overall full run fails.

Report any connector limitation that prevents complete interval enumeration.
Do not silently treat a partial source as successful. The configured Teams
100-result assumption is the documented exception and must remain visible in
the receipt.

## Classify and propose

Apply the commitment rules in the authoritative design. Compare candidates with
the local register and with pending proposals. Use
`<root>\scripts\Update-ATSProposal.ps1 -Action add` to generate stable IDs, deduplicate,
and suppress recently rejected fingerprints. Store only proposals supported by
specific source evidence.

Use kinds `add`, `update`, and `close`. A close proposal means changing an
existing row to `completed`, not deleting it.

## Review interface

Keep the visible report short. Show proposal ID, direction, stakeholder, action,
due date if known, human-readable source, and one evidence line. Plain text is canonical. Render the
stored queue with `<root>\scripts\Invoke-ATS.ps1 review`; do not rescan
communications merely to display pending proposals.

An optional UI adapter may generate an HTML panel, but it is never required and
must not edit the register. A scheduled run stores proposals in the local queue
and returns a compact text receipt. The same proposals can be reviewed later
from Codex CLI or another compatible agent surface.

If no proposals exist, send one short checkpoint-complete receipt. Include a
compact source warning only when a source was partial or failed.

## Apply decisions

Pass approved and rejected proposal IDs once to
`<root>\scripts\Invoke-ATS.ps1 decide`.
It records rejections, applies the accepted batch, validates the CSV, creates
timestamped local backups and an immutable decision-audit record, and updates
the queue as one transaction. Do not repeat those steps manually unless the
script reports an actionable error.
