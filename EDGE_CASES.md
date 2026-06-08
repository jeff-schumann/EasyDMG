# EasyDMG Edge Cases & Potential Issues

This document tracks edge cases that could affect automatic DMG installation. It is intentionally conservative: EasyDMG should automate only the boring, common case and fall back to manual installation when a DMG looks unusual.

**Last updated**: 2026-05-28

## Current Rule of Thumb

EasyDMG should automatically install a DMG only when it finds one valid, top-level `.app` bundle that looks like the actual app the user wants in `/Applications`.

If the DMG contains installers, packages, license gates, multiple plausible apps, or anything else ambiguous, EasyDMG should open the DMG and let the user handle it manually.

## Worth Handling Soon

### 17. Non-Standard `/Applications` Locations - Rating: 3/10 - PARTIALLY RESOLVED

Some users may have unusual `/Applications` setups, such as a symlink, network mount, external drive, or permission-limited location.

**Current behavior**: EasyDMG validates that `/Applications` exists, is a directory, and is writable before installing. This prevents silent failures for the most obvious bad states.

**Remaining concern**: Network-mounted or external `/Applications` folders may still behave oddly. This is uncommon, but EasyDMG could choose to fall back when `/Applications` is not on a local volume.

**Implementation difficulty**: 3/10.

### 19. Huge Apps and Long Copies - Rating: 4/10 - MOSTLY MITIGATED

Large apps can take long enough that users wonder whether anything is still happening.

**Current behavior**: Copying now runs off the main actor through `withMagicFallback`, so the progress UI can continue showing "still working" messages during slow operations.

**Remaining concern**: Progress is staged, not byte-accurate. This is a UX polish issue rather than a correctness issue.

**Implementation difficulty**: 5/10 if we want true byte-level copy progress; otherwise no immediate action needed.

## Resolved or Mostly Mitigated

### 1. App Translocation - Rating: 2/10 - MOSTLY MITIGATED

macOS can translocate quarantined apps launched from unsafe locations. EasyDMG copies apps to `/Applications` and removes `com.apple.quarantine` (after verifying the app via Gatekeeper/Notarization), so the normal translocation trigger should not apply for safe apps.

**Remaining concern**: A small number of apps may have custom first-launch checks that complain anyway. That is app-specific and not something EasyDMG can reliably detect before launch.

### 4. Symlinks to Shared Frameworks - Rating: 1/10 - VERIFIED

Many app bundles contain framework symlinks such as `Versions/Current -> Versions/A`.

**Current status**: A local sanity check on 2026-05-03 confirmed `FileManager.copyItem` preserved an app-style framework symlink. This should not remain an active concern unless a real-world DMG proves otherwise.

### 7. PKG Installers Masquerading as Apps - Rating: 2/10 - RESOLVED

Some DMGs contain `.app` files that are actually installer wrappers. They expect to run once, install the real app elsewhere, then quit.

**Current behavior**: EasyDMG falls back to manual installation when a top-level `.pkg` or `.mpkg` is present. It also falls back when the only app candidate looks like an installer, setup assistant, helper, readme, or uninstaller instead of the main app, including compact names like `FooInstaller.app`.

### 8. Multi-App DMGs With Uninstallers or Helpers - Rating: 2/10 - RESOLVED

Some DMGs contain the main app plus helper apps such as uninstallers.

**Current behavior**: EasyDMG filters obvious auxiliary apps with names containing `uninstall`, `installer`, `helper`, or `readme`. If exactly one main app remains, it installs that app automatically.

### 9. Hidden `.app` Files - Rating: 1/10 - RESOLVED

Some DMGs include hidden `.app` bundles used by installer scripts.

**Current behavior**: EasyDMG ignores top-level `.app` entries whose names start with `.`.

### 12. Auto-Updater Framework Assumptions - Rating: 3/10 - MOSTLY MITIGATED

The known Sparkle false-update problem was caused by copied quarantine attributes.

**Current behavior**: EasyDMG evaluates the app's security status with macOS Gatekeeper. If it passes (or the user approves an unverified app), EasyDMG removes `com.apple.quarantine` after copying, matching the behavior users expect from a normal Finder drag-and-drop install. Blocked apps retain their quarantine state.

**Remaining concern**: Other update frameworks could have app-specific assumptions, but there is no general-purpose fix unless a specific reproducible bug appears.

### 15. Hardened Runtime and Notarization Checks - Rating: 2/10 - ADDRESSED

Notarized apps with Hardened Runtime should not need special treatment from EasyDMG as long as the app bundle is copied without modification.

**Current status**: EasyDMG itself is configured for Hardened Runtime and Developer ID notarization. EasyDMG does not modify installed app code.

### 18. Insufficient Disk Space During Copy - Rating: 2/10 - RESOLVED

Copying without enough free space could leave a partial app behind.

**Current behavior**: EasyDMG calculates app bundle size and verifies available space with a 500 MB buffer before copying. It stages the copy under a temporary `.easydmg-*` app name and cleans up the staged app if copying fails.

### 21. App Bundle Validation Before Copy - Rating: 2/10 - RESOLVED

Not every directory ending in `.app` is necessarily a normal launchable app bundle.

**Current behavior**: Before copying a single app candidate, EasyDMG verifies `Contents/Info.plist`, requires `CFBundlePackageType == APPL`, requires a non-empty `CFBundleExecutable`, and checks that the referenced executable exists and is executable. If validation fails, it falls back to manual installation.

### 22. DMG-Level License Agreements - Rating: 5/10 - RESOLVED

Some DMGs display a software license agreement (SLA) that the user must accept before the volume mounts. EasyDMG should not silently bypass that gate.

**Current behavior**:
- **Preflight Check**: Before mounting an unencrypted DMG, EasyDMG runs a preflight check using the shared timeout-bounded process runner to parse `hdiutil imageinfo -plist` and look for the `Software License Agreement` property. If found, it opens the DMG via `DiskImageMounter` so the OS displays the standard SLA prompt.
- **Handling Encrypted DMGs**: Reading metadata from an encrypted DMG without a passphrase triggers a macOS SecurityAgent prompt, causing a redundant password prompt. To avoid this, preflight is skipped for encrypted DMGs; instead, the check is deferred until after the user enters the passphrase. EasyDMG then reuses the password to parse the plist metadata and redirects any licensed image to manual installation.
- **Native Handoff**: If an encrypted DMG is mounted directly via the native `DiskImageMounter` path, macOS already presents and enforces the SLA. The extra plist check is skipped on this path to prevent overlapping prompt windows.

**Remaining concern**: Detection relies on the image's SLA flag. A DMG that gates licensing by other means (e.g. a custom first-run agreement inside the app) won't be caught here, but those generally reach the same manual-fallback path through other checks.

### 23. Quitting Running App Instances - Rating: 2/10 - RESOLVED

Attempting to overwrite a running application bundle can cause system errors, lockups, or leave the running process bound to the old deleted files. Furthermore, "Open after install" would target the stale, running copy instead of the new version.

**Current behavior**: EasyDMG checks the target bundle identifier in `/Applications` before starting the copy. If a process with that identifier is running, it prompts the user to quit it before proceeding. If the user cancels, the install aborts cleanly.

### 24. App Management TCC & MAS/Root Safeguards - Rating: 3/10 - RESOLVED

Replacing an app in `/Applications` can fail mid-install due to TCC (App Management) permissions, leaving a partially copied bundle. Additionally, replacing a Mac App Store (MAS) app or a root-owned app with a direct-download DMG would break future App Store update paths.

**Current behavior**: Before writing, EasyDMG probes permissions with a non-destructive, no-op modification date write. If blocked, it diagnoses the cause:
- **MAS / Root Owned**: If the app contains App Store receipt markers (`MASReceipt` or `com.apple.appstore` attributes) or is owned by root, automatic replacement is blocked to protect system safety and App Store update integrity.
- **TCC Permission**: If blocked by standard TCC, it prompts the user with an interactive helper dialog, waits for permission to be granted in System Settings, and retries.

### 25. Password-Protected or Encrypted DMGs - Rating: 1/10 - RESOLVED

Attempting to mount password-protected DMGs non-interactively can cause the process to hang or fail silently.

**Current behavior**:
- **Native Handoff Priority**: EasyDMG prioritizes letting macOS's native `DiskImageMounter` handle encrypted DMGs first. This allows the system to utilize saved Keychain passphrases and native prompt flows, and avoids redundant prompts. EasyDMG monitors the system to detect when the volume mounts or the user cancels.
- **In-App Password Prompt**: If the native flow is not used, EasyDMG prompts the user for the DMG's passphrase via an in-app secure text sheet. This dialog is hosted on a level that survives background activation.
- **Unlimited Retries & Escapes**: Instead of aborting after a fixed number of attempts, EasyDMG allows unlimited retries. After two failures, the dialog displays a "Use macOS Password Prompt..." escape hatch button that hands the image off to `DiskImageMounter`.
- **UI & Notification Polish**: The password window displays a steady status to avoid flickering during attempts. If the user cancels the in-app prompt or explicitly hands off to the macOS prompt, redundant manual-fallback notifications are suppressed.

### 26. Transient Mount Failures - Rating: 2/10 - RESOLVED

A known-good DMG can occasionally fail to mount due to transient macOS or `hdiutil` glitches rather than a corrupt image.

**Current behavior**: Instead of falling back to manual installation immediately upon any mount error, EasyDMG retries generic failures up to three times with a short backoff. It logs each attempt in diagnostics. It bypasses this retry logic for password-protected/encrypted DMGs (which route to their prompt flow) and for timeout-related failures.
