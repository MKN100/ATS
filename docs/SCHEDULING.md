# Scheduling

ATS uses a Windows Scheduled Task named `ATS-CodexExec`. Each checkpoint starts
a fresh local `codex exec` process, which loads the project-local ATS skill and
runs the same proposal-only workflow available from an interactive session.

## Default schedule

The example configuration in `config/examples/scan-schedule.json` defines:

- a two-hour checkpoint interval;
- a 12:30 AM Australia/Perth anchor; and
- a 30-minute overlap for each source.

`scripts/Initialize-ATS.ps1` copies that example to the private
`data/scan-schedule.json` file. Edit the private copy to manage the local
schedule. The current scheduler validates the Australia/Perth timezone.

## Register the task

From the repository root:

```powershell
.\scheduling\Register-ATSCodexExecTask.ps1
```

The registration script resolves the current repository path, so no personal
absolute path is stored in source control. Re-run it after moving the
repository.

The task is configured with:

- `StartWhenAvailable` for missed checkpoints;
- `IgnoreNew` to prevent overlapping runs;
- a 15-minute execution limit;
- the signed-in user's existing Codex and connector sessions; and
- `-WindowStyle Hidden` so checkpoints do not open a console window.

The computer must be on and the user must be signed in.

## Run one dispatcher manually

```powershell
.\scripts\Start-ATSScheduledScan.ps1
```

The dispatcher exits without scanning when no checkpoint is due. A due run may
update only scan state and the proposal queue; it cannot modify the commitment
register or apply decisions.

The last compact receipt is written to
`state\last-scheduled-receipt.md`. Runtime state is private and excluded from
Git.
