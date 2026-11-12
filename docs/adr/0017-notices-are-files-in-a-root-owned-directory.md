# 0017 — Notices are files in a root-owned directory, shown as KDE notifications

- Status: Accepted
- Date: 2026-11-12

## Context

Something outside the session (the admin, a consumer's agent, a unit of the image) sometimes has to tell
the desktop user something, for example that an update is waiting for a restart. Plasma's notification
server is on the user's session bus, which any app of the session can write to, so a notice sent through it
cannot be told from one an app forged. Notices must not carry commands.

## Decision

- **A directory is the channel**: `/run/webtop/notices/`, owned by root and not writable by the desktop user.
  A notice is a file `<id>.json` (`id`: letters, digits, `.`, `_`, `-`, not starting with a dot):
  `{"title": "...", "body": "...", "urgency": "low|normal|critical", "action": "restart"}`.
  `urgency` (default `normal`) and `action` are optional. Title up to 200 and body up to 2000 characters, the file
  up to 16 KiB. A writer writes a temporary name (not `*.json`) in the directory, then renames it; removing the
  file withdraws the notice.
- **`webtop-notices`** (user service, with Plasma) shows them. The directory is the state: it is scanned at start,
  on every change and every 30 s (a login or a thaw from Sleep sends no event). Files that are not regular,
  too large or invalid are skipped with a journal line, never fatal.
- **Shown once per content**: dismissing a notice keeps it dismissed until the next login; a changed file shows
  again, replacing the notification in place; a removed file closes it. The state is in `$XDG_RUNTIME_DIR`, per
  invocation of `webtop-session`.
- **One action, `restart`**: Plasma's own Restart (`org.kde.LogoutPrompt` `promptReboot`), which asks for confirmation
  and ends in `reboot.target`. An unknown action is a notice without a button. There is no URL action and
  no command.
- **Text is plain**: Plasma renders markup and links in a notification body, so the body is escaped (`& < >`).
  The title is plain text there already and is passed as is.

## Consequences

- A notice is as trustworthy as root: the user cannot write the directory, but any session app can still
  send its own notification through the bus, only not with this channel's weight.
- The watcher does not pick a file's sender or language; writers choose the text.
- Standalone, an admin drops a file in the directory; under Kubernetes the consumer's agent does (kube-webtop-workspaces
  sends `update-pending`).
- The directory is on `/run`, so notices do not outlive a boot; the writer recreates what still holds.
- Moving `webtop-defaults-notice` onto the channel is left for later; it uses `webtop-notify` directly.
