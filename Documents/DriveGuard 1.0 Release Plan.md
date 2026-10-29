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
- [ ] Quit while a drive is unmounted, relaunch: it remounts the drive and says so.
- [ ] Time Machine, once everything above passes: start a backup with Back Up Now and lock the screen. DriveGuard waits and retries, and the backup drive stays mounted until the backup finishes.
- [ ] Notifications: allowed on first launch, and a failure (a busy drive that runs out of attempts) produces one.

## Safety work

- [ ] **A timeout for a stuck unmount.** If macOS never answers an unmount request, DriveGuard waits forever. It should log it, notify, and move on to the next drive.
- [ ] **Tests for the decision logic:** when to unmount, when to remount, how overlapping triggers combine, delays and cancellation. These can run without any drives, and a mistake here is the costly kind.
- [ ] **A "test run" button** that shows what would happen on a lock, without unmounting anything.
- [ ] **A reminder for drives left unmounted** well after the person is back (the icon or a notification).
- [ ] Find the cause of the crash seen once while opening the menu bar menu (inside macOS's popup window code, no DriveGuard code in the trace), and confirm it is gone.
- [ ] Decide how a manual remount should behave while the screen is locked.

## Polish

- [ ] The window sometimes takes several seconds to appear at launch. Find out why.
- [ ] Status is shown twice (the top card and the bottom bar). Keep the status in the bar and leave only Pause at the top.
- [ ] Lower the macOS requirement if older versions work (it is set to macOS 27 now), and update the website and README to match.
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
