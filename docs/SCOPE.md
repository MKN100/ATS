# Scope

ATS is a local-first, two-way commitment register. It tracks commitments made
by the user and commitments made to the user, along with due dates, source
evidence, and completion status.

## In scope

- Discover explicit commitments in supported communication sources.
- Maintain a local CSV register and proposal queue.
- Propose additions, corrections, and closures.
- Show open, overdue, and soon-due commitments in a terminal UI.
- Preserve evidence, backups, and decision audit records locally.
- Run incremental scans from a Windows Scheduled Task.

## Approval boundary

Scans never edit the commitment register. They may update scan watermarks and
the pending proposal queue, but a person must approve a proposal before ATS
changes the register. Approved decision batches are applied atomically with a
backup and audit record.

## Out of scope

- Treating every request or suggestion as a commitment.
- Automatically accepting proposals.
- Sending messages or email without an approved delivery route.
- Publishing the commitment register, enrolled meeting-note paths, runtime
  state, backups, or audit history.

The complete behavioral contract is in [ATS_DESIGN.md](ATS_DESIGN.md).
