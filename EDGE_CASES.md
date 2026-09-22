# EasyDMG Edge Cases & Safeguards

This guide explains what EasyDMG does when an installation is more complicated than a simple drag-and-drop. It covers automatic handling, decisions you may be asked to make, and situations that need manual installation.

EasyDMG proceeds automatically when it can identify one valid main app, choose a usable destination, and pass the installation safeguards. Obvious helper apps can be ignored when exactly one main app remains. When automatic installation cannot proceed, EasyDMG offers manual installation or explains a confirmed problem, such as insufficient disk space.

**Last reviewed:** 2026-09-22, against the current source. This review did not include new runtime tests. Historical checks are identified separately below.

## Quick Reference

The outcomes below remain subject to the other installation checks and your settings.

| Situation | What EasyDMG does | Your involvement |
| --- | --- | --- |
| [Password-protected DMG](#the-dmg-needs-a-password) | Tries the macOS unlock flow first, then its own prompt if needed. | Enter a password if macOS cannot unlock it automatically. |
| [DMG license agreement](#the-dmg-has-a-license-agreement) | Hands license acceptance to macOS; usually leaves installation manual. | Accept the agreement and follow the manual flow; the native encrypted-mount exception is below. |
| [Package, installer wrapper, or multiple main apps](#the-dmg-contains-an-installer-or-several-apps) | Opens the DMG for manual installation. | Choose and run the appropriate installer or app. |
| [Missing or invalid app](#there-is-no-usable-top-level-app) | Opens the mounted contents in Finder. | Inspect the contents and follow the developer's instructions. |
| [Unusable install folder](#the-chosen-folder-is-unavailable-or-not-writable) | Offers Personal when appropriate, or manual installation. | Choose the offered alternative or cancel. |
| [App requires `/Applications`](#the-app-requires-applications) | Uses that folder or offers a one-time change to it. | Confirm the change, or arrange a manual install with an administrator. |
| [Existing app](#the-app-is-renamed-or-in-a-subfolder) | Finds eligible copies inside your chosen folder and can update in place. | Confirm replacement unless an eligible newer-version update is automatic. |
| [Several installed copies](#several-installed-copies-match) | Selects a candidate conservatively and requires replacement confirmation. | Review the selected copy. |
| [Running app](#the-app-is-already-running) | Asks it to quit before copying. | Approve quitting, retry if necessary, or cancel. |
| [Unverified or blocked app](#macos-cannot-verify-the-app-or-flags-it-as-unsafe) | Warns for unverified apps; never automatically installs blocked apps. | Approve an unverified app, open Finder, or cancel, as offered. |
| [Insufficient space or interrupted copy](#there-is-not-enough-space-or-copying-fails) | Stops with an explanation when the cause is known; otherwise offers manual recovery. | Resolve the problem or use the manual flow. |
| [Cancellation or manual handoff](#cleanup-and-cancellation) | Keeps the original DMG and attempts to remove any temporary app copy. | Retry later or complete installation manually. |

## Opening and Inspecting a DMG

### The DMG needs a password

EasyDMG first lets macOS's DiskImageMounter handle unlocking. This can use a saved password or the native macOS prompt. EasyDMG watches for the volume to mount or the unlock flow to be canceled, and can reuse an already-mounted image.

If native unlocking is unavailable, EasyDMG offers its own secure password prompt. Incorrect passwords can be retried without a fixed limit. After two failed attempts, **Use macOS Password Prompt** provides another route. Canceling stops installation and keeps the DMG. An explicit handoff to the macOS prompt does not create a redundant manual-install notification.

Password handling is described further in [Security Policy](.github/SECURITY.md#password-protected-dmgs).

### The DMG has a license agreement

For an unencrypted DMG, EasyDMG checks image metadata for a software license agreement before mounting. If one is found, it opens the image with DiskImageMounter so macOS presents the agreement, and leaves installation manual. If that licensed image is already mounted, EasyDMG opens its contents without repeating the agreement prompt.

Encrypted DMGs have two paths:

- **Native macOS unlock:** A successful native mount has already enforced any image-level agreement. EasyDMG avoids another metadata/password prompt and can continue automatic installation if the other safeguards pass.
- **EasyDMG password prompt:** EasyDMG checks license metadata using the entered password before mounting. A detected agreement sends the image to macOS for manual installation.

A custom agreement shown inside an app on first launch does not itself trigger manual installation. Failed or unreadable license metadata is logged and is not treated as proof that a license gate exists.

### The DMG will not mount

Fast, generic mount failures get up to three total attempts with a short pause between attempts. Password-related failures go to the unlock flow instead; timed-out mount attempts are not repeated by this retry loop. An already-attached image can be reused if its mount is readable.

If mounting still fails, EasyDMG hands the DMG to DiskImageMounter for manual handling.

### The DMG contains an installer or several apps

A visible top-level `.pkg` or `.mpkg` sends the DMG to manual installation, even when an app is also present.

EasyDMG also recognizes installer-like and auxiliary app names using words such as `install`, `setup`, `uninstall`, `helper`, and `readme`, plus compact suffixes such as `Installer` or `Helper`. For example, `FooInstaller.app` is treated as an installer wrapper. This is a name-based safeguard, not inspection of what the app will do when launched.

If exactly one main app remains after filtering obvious auxiliaries, EasyDMG proceeds with that app's validation and installation checks. If several plausible main apps remain, or the only app looks like an installer or helper, it opens the mounted contents for manual installation.

### There is no usable top-level app

EasyDMG scans the top level of the mounted image. It ignores app names beginning with `.` and does not search recursively for apps inside other folders. No candidate means manual installation.

A candidate must have a readable `Contents/Info.plist` and a runnable executable under `Contents/MacOS`. A declared, nonblank package type (`CFBundlePackageType`) must be `APPL`; missing or blank values are accepted. If the executable name (`CFBundleExecutable`) is missing or blank, EasyDMG uses the app bundle's base name. The executable must exist, must not be a directory, and must have execute permission.

If validation fails, EasyDMG opens the mounted contents for manual inspection rather than copying the invalid bundle.

## Choosing Where to Install

### The chosen folder is unavailable or not writable

**Install Location** can be Applications (`/Applications`), Personal (`~/Applications`), or a custom folder. The first-launch default is based on actual write access. EasyDMG checks that the destination exists, is a folder, and is writable; Personal can be created on demand.

When permissions prevent installation in the chosen folder and Personal is a usable alternative, EasyDMG offers Personal for that installation, optionally as the new default. It does not silently change the destination.

If the selected folder is missing, is not a directory, or has no usable fallback, EasyDMG offers manual installation with the volume still mounted, or cancellation.

### The app requires `/Applications`

EasyDMG requires apps carrying a system extension or DriverKit driver to install directly in `/Applications`. If that folder is selected and usable, installation proceeds normally. If another folder is selected, EasyDMG offers a one-time install to `/Applications` when it is usable. Otherwise it explains that an administrator is needed and offers manual installation.

Bundled launch daemons and declared privileged helpers are recorded in the log, but do not alone override your chosen location. Private app assumptions about installation paths are covered under [Limits and Optional Improvements](#limits-and-optional-improvements).

### The folder is on an external or network drive

Settings warn when a custom folder is on a recognized incompatible local drive format: ExFAT, FAT, or NTFS. This warning does not categorically block installation. If copying fails, EasyDMG can identify an incompatible format or a disconnected source/destination and explain the problem.

Network destinations are not categorically rejected and are not covered by the local drive-format warning. Compatibility depends on the share and filesystem. Other copy failures can lead to manual recovery.

## Updating an Existing App

### The app is renamed or in a subfolder

EasyDMG uses macOS's registered application locations and app identifiers to find eligible copies inside your chosen install folder. It also checks the incoming app's exact filename there. One matching copy can be updated in place, preserving its location and name.

For registered candidates, EasyDMG resolves symlinks when checking folder boundaries and excludes copies inside mounted disk images, the Trash, temporary installation folders, and other app bundles. Copies outside your chosen folder are not selected for replacement. Apps requiring `/Applications` use their incoming filename directly in that folder.

Discovery is not a recursive search of every folder. If the mounted-image check fails, EasyDMG falls back to the incoming filename and requires confirmation before replacing an existing app there. If a discovered copy's parent folder is not writable, it also falls back to the incoming filename.

### Several installed copies match

If several eligible copies match, EasyDMG selects the default registered copy when it is among those candidates and requires confirmation before replacing it. Otherwise it falls back to the incoming filename and requires confirmation before replacing an existing app there.

Matching an app identifier helps locate a copy; it does not establish that both copies were signed by the same developer. See [Security Policy](.github/SECURITY.md#replacing-existing-apps).

### You want to keep the existing copy

**Keep Both** is available when the selected existing copy has a different name or location from where the incoming app would normally go, that incoming destination is free, and discovery found no more than one eligible match.

It leaves the existing app in place and installs the incoming app under its own filename in your chosen install folder. It does not invent a new filename when that destination is already occupied.

### A newer version can replace the old one automatically

**Always install newer versions without asking** skips the replacement prompt only when the incoming version compares as newer, the app identity matches, and selection does not require confirmation. Same, older, or unknown versions still require a decision.

This preference does not skip permission checks, running-app prompts, or security assessment.

### The app is already running

For replacement, EasyDMG checks permissions before asking you to quit the existing app. It then checks running instances against the relevant app identifiers and actual replacement path, avoiding unrelated copies elsewhere.

For a new installation, including Keep Both, it checks running instances of the incoming app's identifier without restricting the check to a replacement path. Keep Both can therefore still ask a running copy to quit.

EasyDMG asks you to approve quitting affected apps. If they do not quit, it offers retry or cancellation rather than force-quitting them.

### The app is protected by macOS or the App Store

Automatic replacement is blocked when EasyDMG detects an App Store receipt, App Store extended attributes, or root ownership. This protection applies in every install folder.

For replacement targets within `/Applications`, EasyDMG also checks App Management access with a no-op modification-date write. A likely denial opens a helper dialog so you can grant permission in System Settings and retry. Inconclusive failures proceed to the normal installation attempt and copy-error handling. Destinations outside `/Applications` are not sent through this permission prompt.

## Security and Copying

### macOS cannot verify the app or flags it as unsafe

EasyDMG copies the app into a temporary location inside the destination folder and assesses it before moving it into place or replacing an existing app.

- **Verified:** Installation proceeds.
- **Unverified:** EasyDMG offers approval, Finder, or cancellation. **Do not warn me about apps from unidentified developers** allows these installs without that warning.
- **Blocked:** Automatic installation cannot proceed. EasyDMG offers Finder or cancellation and attempts to remove the temporary copy.

The warning preference does not disable security assessment or allow blocked apps to install automatically. See [Security Policy](.github/SECURITY.md#how-easydmg-checks-apps) for the assessment and approval details.

### Quarantine affects first launch or app updates

For permitted installs, EasyDMG attempts to remove the quarantine marker from the temporary copy before putting it in place. This reduces quarantine-related first-launch, app-location, and updater problems. Removal is best-effort: a failure is logged but does not abort installation.

The earlier version of this document attributed a Sparkle false-update issue to copied quarantine attributes. Other apps may have different assumptions; a reproducible report is needed to diagnose those. See [Quarantine and Installation](.github/SECURITY.md#quarantine-and-installation) for the security implications.

### There is not enough space or copying fails

EasyDMG estimates the app's size and checks free space on the actual destination filesystem with a 500 MiB buffer. This does not reserve space; if capacity information cannot be read, installation proceeds and relies on copy-error handling.

The copy is staged under a temporary `.easydmg-*` name in the destination folder. An existing app is not replaced until copying and security assessment have completed. A copy failure triggers an attempt to remove the temporary app.

Confirmed insufficient space, a disconnected source or destination, or an incompatible drive format gets a specific explanation. Other failures can lead to manual installation with the volume still mounted. If a replacement failure reveals an App Store or root-ownership restriction, EasyDMG instead shows the protected-app dialog and attempts to unmount the volume. The original DMG is kept on these failure paths.

### Copying takes a long time

Copying runs on a background thread, allowing the progress interface to continue showing activity messages. The progress bar represents installation stages, not bytes copied or a precise time estimate.

### The app contains framework links or signed code

EasyDMG copies app contents without rewriting executable code. It does not need to rebuild or re-sign the installed app for Hardened Runtime or notarization. EasyDMG itself is configured for Hardened Runtime and Developer ID notarization.

**Historical check:** The earlier document records a local check on 2026-05-03 in which the copy operation preserved an app-style framework symlink, such as `Versions/Current -> Versions/A`. That check was not rerun during this review; it is not a guarantee for every destination filesystem.

## Cleanup and Cancellation

### You cancel installation

Canceling keeps the original DMG regardless of the trash preference. If a temporary app copy exists, EasyDMG attempts to remove it. Canceling before replacement leaves the existing installed copy in place.

During normal installation cancellation, EasyDMG attempts to unmount a volume it opened itself. A volume detected as already mounted before processing is left mounted. Canceling during password entry stops the unlock/install flow without reopening the DMG for another attempt.

### EasyDMG hands installation back to you

For an already-mounted image, manual handoff opens its contents in Finder and leaves the volume mounted so you can install from it. For an image that needs mounting or a native prompt, EasyDMG opens it with DiskImageMounter.

The original DMG is kept. EasyDMG does not track completion of your manual installation or later trash the file on your behalf.

### Installation succeeds

After installing, EasyDMG reveals the app in Finder if that preference is enabled, attempts to unmount the image, then attempts to trash the DMG if **Move DMG to trash after successful installation** is enabled. Successful installation attempts to unmount even an image that was already mounted before EasyDMG started processing it.

**Open app after installation** runs afterward if enabled. If launching fails, EasyDMG logs the failure; the app remains installed, and any DMG cleanup already performed is not reversed. This preference also applies to unverified apps whose installation was permitted. It is off by default.

### Unmounting, trashing, or temporary-file cleanup fails

EasyDMG tries a normal unmount first. If the volume is busy, it waits briefly and retries; if normal unmounting fails, it attempts a forced unmount. These operations have time limits.

An unmount failure is logged and does not undo a successful installation. The current success path still attempts to trash the DMG when that preference is enabled, even if unmounting failed. A mounted volume may therefore remain available after installation.

Trashing and temporary-copy cleanup are also best-effort. Failures are logged. A failed trash operation does not undo installation; a failed temporary-copy cleanup can leave a hidden `.easydmg-*` item in the destination folder.

## Feedback and Troubleshooting

### You use notification or silent mode

Feedback settings change routine progress and completion messages, not the installation safeguards or decisions requiring your input. Notification mode falls back to the progress bar when macOS cannot show notification banners or alerts.

Silent mode suppresses routine progress and successful-install notifications. **Still notify me if installation fails** controls failure notifications in that mode, subject to macOS notification permissions. Ordinary manual handoffs, such as a package installer or multiple apps, are not treated as installation failures. Mount, validation, permission, or copy failures can qualify for failure notifications even when a manual recovery is offered.

### You need to understand an unexpected result

The local activity log is at `~/Library/Logs/EasyDMG/easydmg.log`, with older entries in `easydmg.previous.log` in the same folder. It records installation outcomes, reasons for manual handling, and cleanup failures. It stays on your Mac unless you share it.

For a reproducible problem, [open an issue](https://github.com/jeff-schumann/EasyDMG/issues) with:

- EasyDMG and macOS versions.
- The app/DMG name and download source, where available.
- Your install destination, relevant settings, and whether the image or an existing app was already open.
- What you expected, what happened, and the relevant log entries.

Logs can include usernames and full paths; review them before sharing. For security issues, use the private reporting route in [Security Policy](.github/SECURITY.md#reporting-a-vulnerability).

## Limits and Optional Improvements

No confirmed outstanding defect is tracked in this reference. That does not mean every configuration has been tested.

- **Network and unusual filesystems:** Compatibility depends on the destination. Investigate reproducible failures before introducing broader restrictions.
- **App-specific assumptions:** An app can assume `/Applications` in an updater, relaunch script, or license check without shipping a detectable system-extension marker. The bundle checks cannot reliably identify every such assumption.
- **Precise copy progress:** Byte-level progress would be an optional usability improvement, estimated at **5/10 complexity**. The current staged progress is not a byte counter.

Keep concrete bugs and selected enhancements in GitHub issues. Update this guide when behavior changes, and revisit historical checks when a real-world failure warrants it. Useful manual regression scenarios include interrupted copies, unusual destinations, password/license combinations, and replacement of renamed or multiple installed copies.
