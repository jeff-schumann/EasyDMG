# Privacy Policy for EasyDMG

Effective date: April 7, 2026

EasyDMG is designed to process disk image files locally on your Mac. This Privacy Policy explains what information the app handles, what information it does not collect, and when limited network activity can occur.

## Summary

EasyDMG does not create user accounts, does not include advertising, and does not include analytics, telemetry, or crash-reporting services in the current version of the app.

Most EasyDMG activity happens entirely on your device. The main exception is update-related network activity handled through Sparkle, the app's software update framework, and any links you choose to open manually.

## Information EasyDMG Processes on Your Device

EasyDMG may access and process the following information locally on your Mac:

- DMG files you open with EasyDMG
- The mounted contents of those DMG files when scanning for app bundles
- App bundle names and file paths needed to copy apps into `/Applications`
- Existing app bundle names in `/Applications` when checking whether a replacement prompt is needed
- Local preference settings such as:
  - your chosen feedback mode
  - whether to move DMGs to Trash after installation
  - whether to reveal installed apps in Finder
  - update preferences and the last time an update check ran
- Notification permission status from macOS, so EasyDMG can decide whether to show a completion notification

EasyDMG uses this information only to perform its installation workflow and remember your preferences.

## Information EasyDMG Does Not Collect

EasyDMG does not intentionally collect or transmit to the developer:

- the contents of your DMG files
- the apps you install
- your documents, photos, contacts, or other personal files
- advertising identifiers
- precise location information
- payment information
- account credentials

EasyDMG also does not operate its own backend service for user tracking, analytics, or cloud storage.

## Local Logs

EasyDMG keeps a local support log on your Mac at `~/Library/Logs/EasyDMG/support.log`. This support log is enabled by default and is intended to help explain how EasyDMG handled a DMG, such as whether mounting succeeded, whether an install completed, or why EasyDMG fell back to manual mode.

By default, the support log is designed to avoid recording full file paths or raw command output. It may include details such as:

- EasyDMG version and build
- DMG file names
- app names discovered inside a DMG
- install, mount, unmount, and trash outcomes
- fallback reason codes such as multiple apps found or password-protected DMG

EasyDMG also supports an optional verbose diagnostic log at `~/Library/Logs/EasyDMG/diagnostic.log`. Verbose diagnostics are off by default and must be explicitly enabled, for example when troubleshooting a bug. When enabled, the diagnostic log may include more detailed local information such as file paths, mount points, or compacted command output.

All of these logs stay on your device unless you choose to share them yourself, for example when reporting a bug.

## Notifications

EasyDMG may request permission to send macOS notifications. If you allow notifications and choose a notification-based feedback mode, EasyDMG can send local notifications such as confirming that an installation completed. These notifications are generated on your device and are not sent to the developer.

You can revoke notification access at any time in macOS system settings.

## Network Activity and Third Parties

EasyDMG performs very limited network activity.

### Software Updates

EasyDMG uses Sparkle to check for app updates. In the current version, EasyDMG is configured to check an appcast feed hosted at:

`https://raw.githubusercontent.com/jefe-johann/EasyDMG/main/appcast.xml`

If an update is available, the update package may be downloaded from GitHub Releases.

In practical terms, this means GitHub may receive standard request data associated with serving web content, such as your IP address, request headers, and the fact that your device requested the appcast or a release download. EasyDMG itself does not maintain a separate server-side database of update checks.

The current app configuration enables automatic update checks by default. The current app configuration does not enable Sparkle's optional system profiling setting.

You can turn automatic update checks off in EasyDMG's Settings window.

### Links You Open Yourself

If you click links in EasyDMG, such as the GitHub repository or issue tracker, your web browser or macOS will connect to those external sites directly. Those services have their own terms and privacy practices.

Relevant third-party services include:

- GitHub General Privacy Statement: https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement
- Sparkle project documentation: https://sparkle-project.org/documentation/

## How Information Is Used

EasyDMG uses information it handles only to:

- mount and inspect a DMG you opened
- identify app bundles for installation
- copy an app into `/Applications`
- optionally reveal the installed app in Finder
- optionally move the source DMG to Trash
- optionally send a local completion notification
- remember your local preferences
- check for and download app updates if enabled

EasyDMG is not designed to sell personal information or share personal information for cross-context behavioral advertising.

## Data Retention

EasyDMG does not keep a developer-operated server-side history of the DMGs you open or the apps you install.

Locally on your Mac:

- preference values stored in macOS user defaults remain until you change or remove them
- local EasyDMG support and diagnostic logs remain on your Mac until they are rotated or removed
- macOS may retain local notification settings and local console logs according to system behavior
- any installed apps, mounted volumes, or trashed DMGs are handled according to your actions and macOS behavior

## Security

EasyDMG is distributed as a signed and notarized macOS app. The app is designed to keep DMG processing local to your device except for update-related requests and links you open yourself.

No method of electronic storage or transmission is perfectly secure, but EasyDMG aims to minimize privacy exposure by avoiding unnecessary data collection and by keeping core installation activity on-device.

## Children's Privacy

EasyDMG is a general-purpose utility app and is not directed to children under 13. EasyDMG does not knowingly collect personal information from children.

## Changes to This Privacy Policy

This Privacy Policy may be updated from time to time to reflect product changes, operational changes, or legal requirements. When this policy changes, the updated version should be published with a new effective date.

## Contact

For privacy questions or requests related to EasyDMG, please use the project's GitHub issue tracker:

https://github.com/jefe-johann/EasyDMG/issues
