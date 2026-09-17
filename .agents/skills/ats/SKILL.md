---
name: ats
description: Retrieve and manage ATS's two-way commitment register. Use for current, open, overdue, soon-due, or historical lists; ATS status; scheduled or manual scans; proposal decisions; and requested corrections.
---

# ATS

The ATS root is the project directory containing `.agents`, `data`,
`docs`, `scripts`, and `state`. Resolve it from `ATS_ROOT` when set;
otherwise use the current project directory. Validate the root by checking for
`docs/ATS_DESIGN.md` and `data/commitments.csv` before acting.

Its authoritative design is `docs/ATS_DESIGN.md` relative to that root.

## Read-only retrieval fast path

For requests to show, list, count, or summarize commitments, use only the local CLI. Do not inspect the design, scan communications, access Git, or modify anything.

Run `scripts/Invoke-ATS.ps1` with the matching command: `all`, `open`, `overdue`, `soon-due`, or `deletion-candidates`. For "current list," use `open`; use `all` only for explicitly requested history. Use its output directly and answer concisely with the total, relevant timing, and a compact table. Render `me_to_stakeholder` as **By you** and `stakeholder_to_me` as **To you**. Render a blank due date as **Not specified**.

For ATS run status, run `scripts/Invoke-ATS.ps1 status`. Do not inspect communications or Git.

## Proposal decision fast path

For an explicit decision batch naming proposal IDs, do not reread the design,
scan communications, or hand-edit the CSV. Group proposal IDs into Approve and
Reject lists, omit Leave pending items, and run once:

`scripts/Invoke-ATS.ps1 decide`

Pass approved IDs with `-Approve` and rejected IDs with `-Reject`. The underlying helper
applies the whole batch atomically, validates once, creates timestamped local
backups and an immutable decision-audit record, and updates the proposal queue.
Report only the applied/rejected counts and audit ID. Inspect further only when
the script returns an error.

## Scans and corrections

Only for an explicitly requested scan, scheduled run, correction, or direct
status change, read the authoritative design completely and then read [the scan
workflow](references/scan-workflow.md). Creating or entering this chat is not
authorization to scan communications or edit the register.

Routine checkpoints run every two hours with a 30-minute per-source overlap,
as configured in `data/scan-schedule.json`. Always use the intervals returned
by `scripts/Get-ATSScanPlan.ps1`; do not substitute raw watermarks or fixed
lookbacks.

Inspect `plan.health.stale_sources` on every scan. A source watermark older
than two checkpoints is stale and must be called out in the receipt until a
successful collection advances it. A successful full checkpoint must record a
terminal status for every configured source; the state helper rejects a full
success while any source remains `not_run`.

Every scan is register-read-only. It may update runtime watermarks and the local proposal queue, but it must not change the CSV. Return concise, stable proposals for additions, updates, and closures. Every displayed proposal includes its human-readable source. Plain text is the canonical review interface. Render pending proposals with `scripts/Invoke-ATS.ps1 review`; do not rescan merely to display them. The optional HTML panel may be generated only when the user explicitly requests an interactive panel.

The routine Teams search requests `topn=100`. By explicit user decision, a
response containing all 100 requested results is treated as a successful Teams
collection rather than partial coverage. Classify those results, advance the
Teams watermark to the scan boundary, and include a concise receipt note that
coverage was assumed at the configured result limit. Do not retry or enumerate
Teams containers solely because the result count reached 100. Actual connector
errors or other explicit incompleteness remain partial or failed and do not
advance the watermark.

When completing a Teams collection, pass its planned `scan_from`, returned
result count, and whether the configured-limit assumption was used to
`Set-ATSScanState.ps1`. Source-only recovery uses
`-RunScope source_recovery`; it advances only Teams and never completes a
scheduled checkpoint.

Every scan also collects changed Markdown files from the enabled folders in
`data/meeting-note-folders.json` using `scripts/Get-ATSMeetingNotes.ps1`, as
defined by the scan workflow. Treat `meeting_notes` as an independent source:
report failures and do not advance its watermark unless collection succeeds.

Unsupported Microsoft Loop or SharePoint recap links are excluded from ATS
coverage by explicit user decision. Ignore them without retrying, and do not
mark meetings partial solely because such a link cannot be read. If all other
supported meeting evidence completes, mark meetings successful and advance its
watermark. Actual connector failures or incomplete supported content remain
partial or failed.

For scheduled runs, store proposals in the local queue and include the proposal count and a compact one-line-per-proposal review in the visible receipt. The user may review and decide them later from Codex CLI or any compatible agent surface. Do not queue a second turn, require ChatGPT Work, or hide the review behind a browser tab.

Mark completed work `completed`; physically delete a row only when the user explicitly says that the record itself is invalid and should be deleted.

## Weekly email report

Microsoft Graph `Mail.Send` is unavailable under company policy. This is an
authoritative policy constraint, not a transient authentication failure. Do
not call `Connect-MgGraph`, request Graph consent, enable or register the
Graph-based weekly-email task, or retry that delivery route unless the user
explicitly states that company policy has changed. Automated email delivery is
not part of the functional release. An approved replacement delivery route is
required before weekly email can be enabled.
