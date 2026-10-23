---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
---

Write a handoff document summarising the current conversation so a fresh agent can continue the work.

**Do not save a file** in the workspace or temp directory. **Copy the full handoff to the OS clipboard** so the user can paste it into a new chat whenever they want.

## Clipboard delivery

After writing the handoff, pipe it to the system clipboard:

| OS | Command |
|----|---------|
| macOS | `pbcopy` (e.g. `pbcopy < handoff.md` or `printf '%s' "$content" \| pbcopy`) |
| Linux (X11) | `xclip -selection clipboard` |
| Linux (Wayland) | `wl-copy` |
| Windows | `clip` |

Use a heredoc or temp file only if the shell needs it; delete any temp file immediately after copying. Prefer a single shell invocation.

Tell the user briefly that the handoff is on the clipboard (e.g. "Copied to clipboard — paste into your next chat with Cmd+V").

## Document content

Include a **suggested skills** section listing skills the next agent should invoke.

Do not duplicate content already captured in other artifacts (PRDs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

Redact any sensitive information, such as API keys, passwords, or personally identifiable information.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.
