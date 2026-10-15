# CalSync

Menu bar app that mirrors busy time between calendars as opaque “Busy” blockers,
using the calendars already synced into macOS Calendar (no third-party access to
the org accounts needed). Requires macOS 15+ and the Xcode Command Line Tools.

## Prerequisites

CalSync only reads and writes the calendars macOS already syncs, through EventKit.
It doesn't connect to any server itself, so the accounts need to be set up in macOS first:

1. **Add each account in macOS.** Go to System Settings → Internet Accounts and add the
   accounts (Exchange/Microsoft 365, Google, iCloud, CalDAV, …). In each account,
   turn on **Calendars**. You can also add accounts from Calendar → Settings → Accounts.
2. **Check that the calendars appear in Calendar.app.** If a calendar isn't listed
   there, CalSync can't see it either. Shared or delegated calendars must be
   visible in Calendar.app too.
3. **Make sure the target calendar is writable.** Blockers can only be written to
   calendars you can edit. Read-only calendars (subscriptions, holidays, some
   shared calendars) are marked `· read-only` in Settings and can only be a
   *source* of a one-way link. Don't use "On My Mac" calendars as a target:
   blockers there never reach the server.
4. **Set the refresh interval (optional).** In Calendar → Settings → Accounts, the
   **Refresh Calendars** setting controls how often non-push accounts are fetched.
   Set it to "Push" or a short interval so new events reach CalSync quickly.
5. **Grant calendar access.** Approve the prompt on first launch, which asks for
   **Full Access**. If you denied it, enable CalSync under System Settings →
   Privacy & Security → Calendars.

**Calendar.app doesn't need to be open.** macOS syncs the accounts in the
background, both downloading events and uploading the blockers CalSync writes. Only CalSync
itself needs to be running. Blockers reach the server, and other people, only after
macOS has synced, so expect some delay for accounts that aren't push.

## Build & run

```bash
./build.sh            # builds build/CalSync.app
./build.sh install    # also copies to ~/Applications and launches it
```

On first launch, approve the calendar access prompt, then open **Settings…** from
the menu bar icon, add a link between the two calendars, hit **Preview Changes**,
and if it looks right, **Sync Now**. A second preview should show nothing to do. If it
keeps wanting to recreate blockers, the server is mangling the notes marker.

## Copying meeting details

By default the copies show only the time, as “Busy”. For each direction of a link
you can turn on **Copy titles and join links into …**. The copy then gets the
meeting title and its Teams/Zoom/Meet/Webex join link (taken from the invite text
and unwrapped from Outlook Safe Links). Turn on **Prefix titles with the calendar alias**
to get titles like `[AMAG] Weekly sync`.

Give each calendar an **alias** in its link card. Exchange calendars are all called
“Calendar”, so the alias is how you tell them apart in prefixes, the menu and the
log. Without an alias, CalSync uses the account name.

- Copied titles can be seen by anyone who can view event details in that calendar.
  EventKit can't mark events private, so only turn this on where that's acceptable.
- A join link doesn't decide which Teams account joins: Teams uses the account
  that's active. The prefix tells you which account to switch to before joining.

## How it syncs

Stateless: each run computes which
blockers should exist in the look-ahead window, creates the missing ones and deletes
stale ones. Blocker notes contain only `[calsync] <calendar hash>:<event hash>`
(plus the join link when copying details). A copied event whose title or link
changes is replaced on the next sync.
Skipped: all-day, free, cancelled, declined, (optionally) tentative events, and
CalSync's own blockers. Blockers whose link was removed are deleted.

Runs every N minutes, ~10 s after any calendar change, and 30 s after wake.
Log: `~/Library/Logs/CalSync.log`. Settings are stored in UserDefaults (`local.calsync`).

## Signing

Builds are ad-hoc signed, so macOS may ask for calendar access again after each
rebuild. To avoid that, create a self-signed code-signing certificate in Keychain
Access (Certificate Assistant → Create a Certificate → type “Code Signing”) and
build with `CALSYNC_SIGN_IDENTITY="<cert name>" ./build.sh install`.
