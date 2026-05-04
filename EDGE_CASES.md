# EasyDMG Edge Cases & Potential Issues

This document tracks edge cases that could affect automatic DMG installation. It is intentionally conservative: EasyDMG should automate only the boring, common case and fall back to manual installation when a DMG looks unusual.

**Last updated**: 2026-05-03

## Current Rule of Thumb

EasyDMG should automatically install a DMG only when it finds one valid, top-level `.app` bundle that looks like the actual app the user wants in `/Applications`.

If the DMG contains installers, packages, license gates, multiple plausible apps, or anything else ambiguous, EasyDMG should open the DMG and let the user handle it manually.

## Worth Handling Soon

### 22. DMG-Level License Agreements - Rating: 5/10 - ACTIONABLE WITH CARE

Some DMGs display a license agreement before mounting in Finder. EasyDMG should not silently bypass a license gate.

**Current behavior**: License detection exists in code but is disabled because the old check produced false positives without sandboxing.

**Suggested fix**: Revisit this with stricter parsing instead of a broad text search. If detection is reliable, fall back to DiskImageMounter so macOS shows the normal license flow.

**Implementation difficulty**: 4/10.

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

macOS can translocate quarantined apps launched from unsafe locations. EasyDMG copies apps to `/Applications` and removes `com.apple.quarantine`, so the normal translocation trigger should not apply.

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

**Current behavior**: EasyDMG removes `com.apple.quarantine` after copying, matching the behavior users expect from a normal Finder drag-and-drop install.

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
