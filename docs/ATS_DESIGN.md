# ATS design

## Purpose

ATS is a local-first, interface-agnostic personal commitment-tracking
assistant. Its core is a private CSV register, a proposal queue, deterministic
PowerShell helpers, and an immutable decision audit. Codex CLI, the Codex app,
or another compatible agent surface may orchestrate Microsoft 365 scans, but no
particular GUI is the system of record.

It tracks both directions of accountability:

- commitments made by the user to stakeholders; and
- commitments made by stakeholders to the user.

The register is intended to be a trustworthy record of explicit commitments,
not a generic collection of requests or possible actions.

## Sources

Each successful run advances a per-source high-water mark. The next run reviews
all accessible material since that mark, with a short overlap to protect against
late indexing and timestamp-boundary errors. A first run uses a 24-hour
lookback. A catch-up run may cover more than 24 hours and processes long gaps in
bounded time windows rather than silently skipping material.

The reviewed sources are:

- Microsoft Teams chats and channel messages;
- accessible Teams meeting chats and recording transcripts;
- received and sent Outlook email;
- Outlook Calendar when useful for locating relevant meetings;
- phone-call or meeting commitments manually entered through an ATS control interface; and
- Markdown meeting notes from workstream folders explicitly enrolled in
  `data/meeting-note-folders.json`.

Meeting-note enrolment is local and opt-in; ATS does not inspect other folders
below Meeting Notes. The `meeting_notes` source is incremental and uses file
last-write timestamps with the standard overlap. Every changed Markdown file
in the interval is eligible for classification regardless of keywords. Folder
or file access failures make the source partial or failed and prevent its
watermark from advancing.

A calendar invitation by itself is not a commitment. Transcript access depends
on the connected account and whether Teams exposes the meeting recap or
transcript to the connector.

On 17 September 2026, the user explicitly excluded unsupported Microsoft Loop
or SharePoint meeting-recap links from ATS coverage. ATS does not retry or
diagnose those links, and their presence alone does not make the meetings
source partial. When all otherwise supported meeting, calendar, chat, and
transcript material is collected successfully, ATS marks meetings successful
and advances its watermark. This policy accepts that commitments available
only inside an unsupported Loop recap may be missed.

Teams collection requests up to 100 results per routine search. Direct messages,
group chats, channel messages, meeting chats, and accessible transcripts in the
returned set remain eligible regardless of keyword or perceived importance.
Prioritization controls processing order only. ATS may classify search snippets
first and fetch full conversation context only for credible or ambiguous
candidates; it must not use a keyword-only gate that excludes a returned message
from consideration.

On 17 September 2026, the user explicitly decided that a Teams response reaching
the configured 100-result request limit is operationally assumed complete. ATS
therefore advances the Teams watermark after classifying those results and adds
a visible receipt note that coverage was assumed at the limit. This policy
accepts that additional messages may exist beyond the returned set. An actual
connector error or another explicit incomplete condition remains partial or
failed and does not advance the watermark.

## Commitment rules

Record only a clear promise, accepted action, agreed deliverable, or explicit
ownership of follow-up work. Do not record an unaccepted request, suggestion,
aspiration, FYI, invitation, joke, or decision without an owner.

For each commitment, capture when reliably available:

- direction (`me_to_stakeholder` or `stakeholder_to_me`);
- stakeholder;
- concise commitment description;
- commitment date and committed due date;
- current status;
- source type, timestamp, link, and minimal supporting evidence; and
- first-seen and last-updated timestamps.

Leave dates blank rather than guessing. Resolve relative dates only when the
source timestamp makes them unambiguous. Deduplicate using direction,
stakeholder, normalized meaning, and source identity.

Every scheduled or manual scan is register-read-only. It proposes additions,
updates, and closures but does not change the commitment register until the
user explicitly accepts the specific proposal through an ATS control
interface. Runtime
watermarks and the proposal queue may be updated independently of the register.
Rejected proposal fingerprints are retained for 30 days outside the register
so the same source evidence is not repeatedly proposed.

## Completion and deletion control

New commitments default to `open`. Later communications may update wording,
dates, ownership, or status.

When an email reply or Teams message provides clear evidence that a commitment
has been completed, propose its closure with minimal completion evidence and a
source reference. An accepted closure changes the status to `completed` while
retaining the row as an audit trail. Physical deletion is reserved for an
explicit correction of an invalid record.

## Register, backup, and audit

The system of record is `data/commitments.csv` in the dedicated local
ATS workspace. It is personal data and is not stored in Git. The fixed
CSV columns are:

`commitment_id,direction,stakeholder,commitment,commitment_date,due_date,status,source_type,source_datetime,source_link,evidence,first_seen_at,last_updated_at,notes`

Identifiers use `COM-YYYYMMDD-<short deterministic suffix>`. Proposal
identifiers and fingerprints are stable across scans. After the user submits a
set of decisions, ATS validates and applies all accepted decisions as
one local transaction. Before replacement it creates timestamped backups of
the register and proposal queue. Each successful batch creates an immutable
decision-audit record with the accepted and rejected proposal IDs.

Submitted decisions use the deterministic decision-batch helper in
the ATS workspace. The helper performs register edits, validation,
backups, audit recording, and queue updates in one invocation. It restores the
previous register and queue if the transaction fails. The orchestrating agent
does not repeat those steps manually unless the helper reports an actionable error.

Operational state is kept beside the local register in the dedicated ATS
workspace. It records the last attempt, last successful scan, completed
schedule checkpoint, per-source watermarks and status, duration, proposal
count, and a concise error summary. A failed or partial source does not advance
that source's watermark. A Teams result at the configured 100-item limit is not
partial under the explicit assumption policy above.

Per-source completion is independent: every source marked successful advances
to the fixed scan boundary even if another source fails. A full checkpoint
cannot be completed while any configured source remains `not_run`. Teams state
also records its prior watermark, scan interval, returned result count, and
whether completion was assumed at the configured result limit. A Teams-only
recovery advances Teams without claiming that a full scheduled checkpoint was
completed.

## Schedule

ATS has a checkpoint every two hours in Australia/Perth time, anchored at
12:30 AM. Checkpoints therefore occur at 12:30 AM, 2:30 AM, and so on through
10:30 PM. Each source starts 30 minutes before its successful watermark to
provide overlap for delayed indexing and boundary timing.

The planner flags a source watermark as stale when it is more than two
checkpoint intervals old. Scheduled and manual receipts keep that warning
visible until a successful source collection advances the watermark.
The terminal dashboard shows an active watermark alarm near the top. It names
each stale source, its connector status, its last successful watermark and age,
and the last failed or partial attempt time when that evidence is available.

The Windows task runs directly at each checkpoint and performs a state check
before scanning. If the computer or scheduler host was unavailable at a
checkpoint, `StartWhenAvailable` triggers one catch-up scan from the last
successful per-source watermark and satisfies all earlier checkpoints covered
by that scan. The task launches its PowerShell host with a hidden window so
routine checkpoints run headlessly without interrupting the signed-in user.
The schedule and overlap are stored in
`data/scan-schedule.json`.

The active scheduler is a standalone local task rather than a heartbeat tied to
a particular chat. Its adapter contains only dispatch instructions and invokes
the project-local ATS skill in `.agents/skills/ats`. Workflow
rules live in this design and the skill rather than being duplicated in the
scheduler configuration. Scheduling is an adapter: the same scan, queue,
review, and decision contracts also work in a manual Codex CLI session.

The proposed Friday 1:00 PM Australia/Perth email report is currently disabled.
On 17 September 2026, the user confirmed that Microsoft Graph `Mail.Send` is
unavailable under company policy. ATS must treat this as a durable policy
constraint and must not retry Graph authentication, consent, registration, or
delivery unless the user explicitly confirms that policy has changed. Weekly
email requires a separately approved delivery route before it can be enabled.
The Windows task was unregistered at the user's request on 17 September 2026;
only the inactive configuration in `data/weekly-email.json` and the prototype
files remain.

## Control interfaces

ATS does not require ChatGPT Work or a dedicated GUI task. Its human
interfaces are plain text, including Codex CLI conversations, the local
`scripts/Invoke-ATS.ps1` command, and the local terminal interface
started by `bin\ats.cmd` (or `ats` when `bin` is on `PATH`). A compatible agent surface may also be used. The
user can ask ATS to:

- record commitments from calls or meetings;
- correct descriptions, owners, dates, or statuses;
- run an immediate scan;
- show open, overdue, or soon-due commitments;
- review deletion candidates; and
- delete a commitment only after explicit approval.

## Reporting

Each due run gives a short numbered list of proposed additions, updates,
closures, and material uncertainties. The canonical review is a compact
plain-text list containing proposal ID, direction, stakeholder, action, due
date, a human-readable source, and one evidence line. The source label identifies
the channel, such as Meeting note, Teams chat, Email, Calendar, or Manual entry;
meeting-note sources also include the file name. The user may approve or reject proposal IDs in
conversation or through `scripts/Invoke-ATS.ps1 decide`. Both paths
invoke the same atomic decision-batch helper.

An HTML review panel may be generated by an optional UI adapter, but it is never
required to review or decide proposals. When a scheduled run creates proposals,
it stores them in the local queue and reports the count plus a compact text
review. A later CLI session can render the same queue without rescanning. No
scheduler is allowed to apply proposals merely because it displayed them.

A completed scheduled checkpoint always produces a one-line receipt, even when
there are no proposals. Reports stay concise, highlight overdue open
commitments and those due within seven days, and mention source-access or
authentication failures. No proposal is applied merely because it was
reported.

## Collection and classification performance

Teams, Outlook, meeting discovery, and local meeting-note discovery are
independent and should be started in parallel. The routine collection path uses
three initial connector calls plus one local command: one broad Teams search,
one global Outlook mailbox search, one exact-interval calendar query, and
`scripts/Get-ATSMeetingNotes.ps1`. Outlook folder enumeration, Teams
chat/team/channel listing, and profile lookups are fallback diagnostics rather
than routine work. The global mailbox search includes received mail, sent mail,
and custom folders; results are post-filtered to the exact timestamp interval
and paged when the connector reports more data.

Collection is staged: enumerate returned items in the incremental interval,
classify available metadata and snippets in batches, and fetch full content only
when context is needed. Independent context fetches and batch email fetches run
together. Outlook pagination is followed when reported. A Teams result at the
configured 100-item request limit is treated as successful under the explicit
assumption policy and is disclosed in the receipt; no fallback enumeration is
performed solely for reaching that count. Deterministic source identities and
proposal fingerprints handle overlap and deduplication.

For an ordinary incremental interval, the operating target is under two minutes
from wake to stored proposals, subject to connector latency. A submitted
decision batch should normally complete in under thirty seconds. Runtime state
records actual duration so regressions remain visible; these targets never
justify skipping source coverage or bypassing approval.

The initial extraction pass should use the fastest suitable configured model
and modest reasoning. Ambiguous candidates may receive a deeper second pass.
Read-only list and status requests never scan communications and remain direct
local-state reads.

## Future extension

A separate companion concept, tentatively named OathSmith, may identify
commitments that are suitable for AI assistance and prepare reviewable drafts or
deliverables. ATS remains the authoritative record; OathSmith would never
send an external communication without human review and approval.
