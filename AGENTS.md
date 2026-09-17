# ATS project

This folder is ATS's complete local workspace. Treat
`docs/ATS_DESIGN.md` as authoritative and use the project-local skill at
`.agents/skills/ats/SKILL.md` for ATS work.

- Read-only list and status requests use `scripts/Invoke-ATS.ps1`.
- Scheduled and manual scans may update scan state and pending proposals, but
  never the commitment register.
- Apply approved decisions only through the atomic decision helper.
- Keep the register, queue, backups, audit records, and workflow files local to
  this folder. Do not introduce a Git dependency.
- Preserve unrelated data and historical records.
