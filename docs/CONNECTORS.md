# Connectors

ATS does not store Microsoft credentials. Microsoft 365 collection is
orchestrated by Codex using the connectors available to the signed-in user.

## Microsoft Teams

The routine scan searches accessible chats, channel messages, meeting chats,
and transcripts. ATS classifies every returned item in the planned interval.
The current operating policy requests 100 results and treats a result set at
that configured limit as complete while disclosing the assumption in the scan
receipt.

## Outlook email

ATS searches the mailbox across received, sent, and custom folders, applies
the exact planned time interval, and follows connector pagination when it is
reported.

## Outlook calendar and meetings

Calendar data locates relevant meetings. A calendar invitation alone is not a
commitment. Accessible meeting chats and transcripts may provide commitment or
completion evidence. Unsupported Loop or SharePoint recap content is outside
the current coverage boundary.

## Markdown meeting notes

`scripts/Get-ATSMeetingNotes.ps1` reads changed Markdown files from folders
explicitly enrolled in the private `data/meeting-note-folders.json` file. The
repository includes a safe example at
`config/examples/meeting-note-folders.json`; real paths are intentionally not
versioned.

Connector collection remains read-only. Discovered changes enter the proposal
queue and require approval before they affect the register.
