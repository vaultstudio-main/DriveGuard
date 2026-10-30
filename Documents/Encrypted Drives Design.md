# Encrypted drives: design and experiments

## The problem

macOS locks an encrypted APFS volume when it is unmounted (and newer macOS makes Time Machine drives encrypted). A plain mount then fails ("encrypted and locked, use unlockVolume"). `diskutil apfs unlockVolume` from DriveGuard **and from Terminal** is refused with error -69464, "restricted by Sandbox; check Privacy & Security > Files and Folders". Disk Utility can unlock, because it is an Apple app.

What Ejectify does (read Oct 29, MIT licensed, ideas only): plain mount first, then a ~5 second wait for macOS to unlock the drive itself, then `diskutil apfs unlockVolume` with a password kept in its own keychain entry, then a password prompt. Its privileged helper only mounts and unmounts; it does not unlock. Its helper accepts every connection with no client check, which DriveGuard must do better.

## What we know and don't know

- Known: Terminal and DriveGuard are both refused with -69464. A plain `diskutil mount` says the volume is locked.
- Not known: which permission the check wants, and whether root is treated differently.
- Reported by others: Full Disk Access did not help Ejectify users; running as root helped one.

## Experiments (in order, one result each)

1. **Terminal with a privacy permission.** Add Terminal under System Settings > Privacy & Security > Full Disk Access, quit and reopen Terminal, run `diskutil apfs unlockVolume <disk>` again. Then, if still refused, look for Terminal under Files and Folders (Removable Volumes). Result decides whether a permission the user grants is enough (no helper).
2. **Root.** `sudo diskutil apfs unlockVolume <disk>`. Result decides whether a privileged helper can unlock.
3. **Ejectify itself** on the same Mac and drive, password saved, unlock-when-needed on. Result tells us whether anything can do it on this macOS.
4. **Native unlock.** With the password remembered in the keychain, does macOS unlock the drive itself when it is re-attached or on wake? (Ejectify waits 5 seconds for this.)

## Design that fits any outcome

Unlocking is a ladder, each step tried only if the one before did not leave the drive mounted:

1. Plain mount (fine for unencrypted drives).
2. If encrypted and locked: wait about 5 seconds and look again (macOS may unlock it itself).
3. Unlock with the permission/helper path that experiments 1 or 2 found, if one exists.
4. Otherwise: tell the person plainly, keep the drive on the owed list, and offer to open Disk Utility.

Rules that do not change: never force, never eject, one wrong password is never retried, the password (if any is ever stored) is never logged, and the helper (if any) only does mount, unmount and the lock check, accepts only the signed DriveGuard app, and refuses the startup disk and internal drives.

## Decision after the experiments

- Experiment 1 works: ship with a permission step in onboarding and a clear message when it is missing. No helper.
- Only experiment 2 works: build the privileged helper (see the release plan).
- Neither works: encrypted drives stay skipped, and the plan says why.

## Result (Oct 29)

Experiment 1 worked: with Full Disk Access given to Terminal, `diskutil apfs unlockVolume` unlocked the drive with its passphrase. No helper needed. DriveGuard keeps the password in the keychain (chosen over asking each time) and needs Full Disk Access. Built, not yet tried inside DriveGuard.
