# ATS

ATS is a local-first assistant for tracking commitments in both directions:
work you owe to other people and work other people owe to you. It combines a
private CSV register, incremental communication scans, an approval queue, and a
terminal dashboard.

ATS is deliberately approval-gated. Scans can propose additions, updates, and
closures, but they cannot edit the register until a person approves the
specific proposal.

## Scope

- A PowerShell CLI and terminal UI for open, overdue, and soon-due work.
- A proposal queue with approve/reject decisions.
- Atomic register updates with backups and an immutable audit trail.
- Incremental scan planning with per-source watermarks and overlap.
- Collection workflows for Teams, Outlook, meetings, and local Markdown notes.
- A headless Windows Scheduled Task for unattended checkpoints.
- A project-local Codex skill containing the agent workflow.

See [Scope](docs/SCOPE.md) for the system boundary and
[ATS design](docs/ATS_DESIGN.md) for the complete behavioral contract.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- Codex CLI installed and authenticated for scheduled scans.
- Read access to the Microsoft 365 connectors used by the scan workflow.
- Windows Task Scheduler for unattended checkpoints.

Microsoft credentials are not stored in this repository.

## Quick start

Clone the repository and initialize private runtime files:

```powershell
git clone https://github.com/MKN100/ATS.git
Set-Location ATS
.\scripts\Initialize-ATS.ps1
```

Edit these local, Git-ignored files before scanning:

- `data\meeting-note-folders.json`
- `data\scan-schedule.json`

Launch the terminal UI directly:

```powershell
.\bin\ats.cmd
```

To launch it as `ats` from any terminal, add only `bin` to your user PATH. See
[PATH setup](docs/PATH.md).

## PATH

Only the `bin` directory belongs on PATH. It contains the single `ats.cmd`
launcher; the project root, private data, and implementation scripts remain
outside the command search path. Existing terminals must be reopened after the
user PATH changes.

## Connectors

The scheduled agent coordinates four independent sources:

| Source | Collection path |
| --- | --- |
| Microsoft Teams | Chats, channels, meeting chats, and accessible transcripts |
| Outlook email | Received, sent, and custom mailbox folders |
| Outlook calendar | Meeting discovery and supported meeting evidence |
| Meeting notes | Changed Markdown files in explicitly enrolled local folders |

Collection is read-only. Details, coverage assumptions, and limitations are in
[Connectors](docs/CONNECTORS.md).

## Commands and scripts

Common CLI commands:

```powershell
.\scripts\Invoke-ATS.ps1 open
.\scripts\Invoke-ATS.ps1 overdue
.\scripts\Invoke-ATS.ps1 soon-due
.\scripts\Invoke-ATS.ps1 review
.\scripts\Invoke-ATS.ps1 status
.\scripts\Invoke-ATS.ps1 decide -Approve C-12345678 -Reject A-87654321
```

Useful entry points:

| Script | Purpose |
| --- | --- |
| `Initialize-ATS.ps1` | Create missing private runtime files from safe examples |
| `Invoke-ATS.ps1` | Main CLI for lists, status, review, and decisions |
| `Start-ATSTui.ps1` | Interactive terminal dashboard |
| `Get-ATSScanPlan.ps1` | Calculate the next incremental scan interval |
| `Get-ATSMeetingNotes.ps1` | Enumerate changed Markdown meeting notes |
| `Start-ATSScheduledScan.ps1` | Dispatch one due Codex scan |
| `Update-ATSProposal.ps1` | Add or update a stable proposal |
| `Apply-ATSDecisionBatch.ps1` | Atomically apply approved decisions |

Retrieval commands accept `-Json`. Decision batches accept `-DryRun`.

## Scheduling

The default example schedule uses two-hour checkpoints with a 30-minute source
overlap. After initialization, register or update the headless Windows task:

```powershell
.\scheduling\Register-ATSCodexExecTask.ps1
```

The task runs only while the user is signed in, uses the existing Codex and
connector sessions, and does not open a console window. See
[Scheduling](docs/SCHEDULING.md).

## Repository layout

```text
.agents/skills/ats/   Codex scan and review workflow
bin/                  PATH-safe command launchers
config/examples/      Non-sensitive configuration and register templates
data/                 Private register and local configuration (ignored)
docs/                 Scope, connectors, architecture, scheduling, and PATH
scheduling/           Windows Scheduled Task registration
scripts/              CLI, TUI, state, proposal, and scan helpers
state/                Private runtime state and audit records (ignored)
tests/                 PowerShell regression tests
```

Backups, generated review files, personal diagrams, and migration artifacts are
also excluded from Git.

## Private data boundary

The repository intentionally does **not** publish:

- `data/commitments.csv`
- `data/meeting-note-folders.json`
- pending proposals or scan watermarks
- decision audits or register backups
- generated review pages
- personal cloud-migration data

Safe empty/example files live under `config/examples`. `Initialize-ATS.ps1`
never overwrites an existing runtime file.

## Tests

Run the PowerShell regression scripts from the repository root:

```powershell
Get-ChildItem .\tests\Test-*.ps1 | ForEach-Object { & $_.FullName }
```

The functional release currently targets the Australia/Perth schedule model.
Automated email delivery is not included because it requires an approved
writable mail route.
