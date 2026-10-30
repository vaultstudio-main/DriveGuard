# DriveGuard 1.0 Release Plan

## Overview

DriveGuard 1.0 is the first release: a menu bar app that safely unmounts external drives when you step away and mounts them again when you are back. The app is built and runs. **It has not yet been tried against real drives, a real screen lock or a real sleep**, and a tool that touches a backup drive earns trust by being tested first. This plan is that test, plus the safety work and polish that go with it.

**Nothing in DriveGuard connects to an outside service.** The app makes no network connections of its own.

The rules do not bend, and every item below has to respect them: never force an unmount, never eject, never unmount while Time Machine is backing up (or when it cannot tell), only touch drives the person ticked.

## Test on real drives

Use a spare drive with nothing important on it, **not** the Time Machine drive. Untick the Time Machine drive until this section has passed once.

- [ ] Open the menu bar menu a few times: it opens, and "Open DriveGuard…" brings the window to the front, also when another app has focus.
- [ ] With every drive unticked, **Unmount Selected Drives Now** leaves everything mounted, and the log says so.
- [ ] Tick only the spare drive: **Unmount Selected Drives Now** unmounts it, the menu bar icon changes, and **Remount** brings it back. The Time Machine drive stays mounted.
- [ ] A busy drive: open a file on the spare drive, unmount. It is refused (never forced), the log names the program holding it, and it unmounts once the file is closed.
- [ ] Screen lock: lock with Ctrl-Cmd-Q, wait, unlock. The spare unmounts on lock and remounts on unlock.
- [ ] Screen saver, display sleep and user switch, one at a time: each unmounts and remounts. A screen saver stopping while the screen is still locked does **not** remount.
- [ ] System sleep: the spare unmounts just before sleep, remounts on wake, and sleep does not feel delayed.
- [ ] Pause: while paused a lock unmounts nothing. A per-drive delay of one minute waits about a minute.
- [ ] Encrypted drive: with Full Disk Access given, save its password (it should say "Checked with macOS and saved"), lock and unlock. Expect `Unmounted … Confirmed`, then `Remounted … Confirmed`. A wrong password should be refused and not saved.
- [ ] Quit while a drive is unmounted: it remounts the drive before exiting, and the log says "Confirmed: it is mounted".
- [ ] Restart the Mac while the spare is unmounted (screen locked): after startup, the saved log still shows the unmount, "DriveGuard started", the drives mounted at startup, and "was already mounted" for the spare.
- [ ] Time Machine, once everything above passes: start a backup with Back Up Now and lock the screen. DriveGuard waits and retries, and the backup drive stays mounted until the backup finishes.
- [ ] Notifications: allowed on first launch, and a failure (a busy drive that runs out of attempts) produces one.

## Encrypted drives (solved: Full Disk Access, no helper)

Newer macOS makes Time Machine drives encrypted, and macOS refuses `diskutil apfs unlockVolume` (error -69464, "restricted by Sandbox") from any app that lacks a privacy permission. **Test Oct 29: with Full Disk Access given to Terminal, the unlock worked.** So no privileged helper is needed; DriveGuard needs Full Disk Access. See [Encrypted Drives Design.md](Encrypted%20Drives%20Design.md).

- [x] Password saved in the keychain, checked with macOS; refused and not saved while macOS forbids unlocking (so a drive is never unmounted that cannot be brought back). Rebuilt Oct 29.
- [x] On return, a locked drive gets about 5 seconds for macOS to unlock it itself, then DriveGuard unlocks it with the saved password. A wrong password is never retried.
- [x] "Open Full Disk Access settings" button in the drive's settings; Help, README explain the permission.
- [ ] **Needs trying for real:** give DriveGuard Full Disk Access, quit and reopen it, save Backup's password (expect "Checked with macOS and saved"), lock and unlock (expect `Unmounted … Confirmed`, then `Remounted … Confirmed`).
- [ ] Does the permission survive a new build or a re-signed release? Check with the notarized build.
- [ ] If Full Disk Access is turned off later while a password is saved, a drive could be unmounted and then fail to unlock. Add a check before unmounting.
- [ ] First-run onboarding step that explains Full Disk Access.
- [ ] Update the website text (driveguard, privacy, support) once the real test passes.

## Safety work

- [x] **A remount that fails is retried, and never forgotten.** First real test (Oct 29): the lock unmounted the spare and the log confirmed it, and it stayed unmounted through display sleep and two system sleeps. But the remount at unlock failed once (system error 77) while macOS mounted the same drive itself a second later, and DriveGuard dropped the drive from its list. Now: three attempts, a check for whether macOS already mounted it, the drive stays on the list until it is really mounted, and errors are shown in words. Done Oct 29. It needs the lock test repeated.
- [x] **Unlocking the screen cancels every waiting job.** Third real test (Oct 29): you unlocked at 12:51 while DriveGuard was waiting for Time Machine, but only the newest queued job was cancelled; the older one kept waiting and unmounted the drive at 12:53. Now every waiting or retrying job is cancelled. Done Oct 29. **Needs trying: start a backup, lock, unlock after 20 seconds, wait 3 minutes: the log should say it cancelled, and the drive must stay mounted.**
- [x] **Quit remounts first.** Choosing Quit while drives are unmounted brings them back before the app exits (waiting at most 20 seconds). At shutdown or restart it does not wait: macOS unmounts the drives itself and mounts them again at startup. Done Oct 29.
- [x] **The activity log is saved on the Mac** (`~/Library/Application Support/DriveGuard/activity.log`, the last 500 events), so it survives a quit, a crash or a restart. Done Oct 29.
- [x] **The log confirms it.** Every unmount says "Confirmed: it is no longer mounted" and every remount says "Confirmed: it is mounted at <path>", checked with macOS after the fact, and startup lists the external drives that are mounted. Done Oct 29.

- [x] **A timeout for a stuck unmount.** If macOS does not answer an unmount (90 s) or mount (60 s) request, DriveGuard stops waiting, logs it, notifies, and keeps the drive on its list to check when you return. Done Oct 29. It needs trying for real, if a drive ever hangs.
- [ ] **Tests for the decision logic:** when to unmount, when to remount, how overlapping triggers combine, delays and cancellation. These can run without any drives, and a mistake here is the costly kind.
- [ ] **A "test run" button** that shows what would happen on a lock, without unmounting anything.
- [ ] **A reminder for drives left unmounted** well after the person is back (the icon or a notification).
- [ ] Find the cause of the crash seen once while opening the menu bar menu (inside macOS's popup window code, no DriveGuard code in the trace), and confirm it is gone.
- [ ] Decide how a manual remount should behave while the screen is locked.

## Polish

- [ ] The window sometimes takes several seconds to appear at launch. Find out why.
- [ ] Status is shown twice (the top card and the bottom bar). Keep the status in the bar and leave only Pause at the top.
- [x] Lower the macOS requirement to 15 (it builds for 15 with no availability errors), and update the website and README to match. Done Oct 29. **Still to do: run it once on a Mac with macOS 15.**
- [ ] Check Launch at login from a copy in Applications, including that it stays in the menu bar without opening the window.
- [ ] Write the first-run help: the app does nothing until a drive is ticked, so say so.

## Publishing

- [ ] Sign with a Developer ID and notarize the build.
- [ ] Make a `.dmg` and attach it to a GitHub release (1.0).
- [ ] On the website, swap the "Coming soon for Mac" badge on `driveguard.html` and the card on `index.html` for a download link, and add the release to `updates.html`.
- [ ] Update the status line at the top of the README.
- [ ] Decide whether to add an update check. If it ever sends anything, update the privacy page and the README first.

## Later, not planned for 1.0

- A first look at drives that wake the Mac while it sleeps, to see whether anything more can be done than unmounting.
