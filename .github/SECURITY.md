<h1>
  <img
    align="right"
    width="150"
    alt="Security hamster"
    src="https://github.com/user-attachments/assets/381cca17-e1b0-44ef-8b75-d9057be9bcd5#gh-dark-mode-only"
  />
  <img
    align="right"
    width="150"
    alt="Security hamster"
    src="https://github.com/user-attachments/assets/5f0c850b-c834-48e6-849c-5ec130929111#gh-light-mode-only"
  />
<br>
  Security Policy
</h1>
<br>

## Supported Versions

EasyDMG security fixes are targeted at the latest published release.

If you are reporting a security issue, please confirm the affected EasyDMG version and your macOS version in the report.

## How EasyDMG Checks Apps

EasyDMG copies the app to a temporary location inside your chosen installation folder, then checks that copy before completing the installation or replacing an existing app.

It requests a security assessment using macOS's built-in `spctl` tool. If that assessment rejects the app, EasyDMG uses `codesign` to help distinguish signature problems from unsigned or unnotarized software. macOS may contact Apple during these checks; notarization information may also be available locally, including from a cached or attached ticket.

These checks help assess an app, but aren't a guarantee of safety or an exact substitute for macOS's checks when launching it. See [Apple's guidance on testing notarized software](https://developer.apple.com/forums/thread/130560).

### Assessment Results

- **Verified:** The assessment succeeds and identifies notarized Developer ID software, Apple software, or Mac App Store software. EasyDMG proceeds automatically. Acceptance without confirmed notarization for a Developer ID app, or an unknown assessment source, is treated as unverified.
- **Unverified:** EasyDMG couldn't establish a verified result. This includes unsigned or unnotarized apps, inconclusive results, and checks that timed out or couldn't run. It does not establish that an app is safe. By default, EasyDMG asks whether to continue, open the DMG in Finder, or cancel.
- **Blocked:** EasyDMG recognizes a report of malware, a revoked certificate, or a damaged or modified signature or app bundle. It won't complete automatic installation or remove quarantine. The available choices are to open the DMG in Finder or cancel.

The **Do not warn me about apps from unidentified developers** setting skips the warning for **all unverified results**, including failed or timed-out checks. It's off by default. Security checks still run, and blocked results cannot be approved for automatic installation.

### Quarantine and Installation

After verification or approval, EasyDMG attempts to remove the `com.apple.quarantine` marker from the temporary app copy and its contents, then moves it into place. This reduces first-launch friction and avoids quarantine-related problems with app location and updates. If removal fails, the failure is logged, but installation can still continue.

Removing quarantine changes the app's normal first-launch warning behavior. EasyDMG does not disable Gatekeeper system-wide.

If you cancel or choose Open in Finder at the security prompt, EasyDMG attempts to remove the temporary copy and does not replace the existing app. The original DMG is kept.

**Open app after installation** is off by default. When enabled, it also opens unverified apps whose installation you approved, including through the warning preference above.

## Replacing Existing Apps

EasyDMG can find renamed apps and apps in subfolders within your selected installation folder. Ambiguous matches require confirmation. Matching an app's application identifier helps locate an existing copy; it does not verify that both copies were signed by the same developer.

EasyDMG refuses automatic replacement when it detects that an existing app is managed by the App Store. It checks relevant replacement permissions before asking you to quit the existing app. Enabling **Always install newer versions without asking** skips eligible replacement prompts, but does not skip the security assessment.

## Password-Protected DMGs

EasyDMG first uses macOS's unlock flow, which can use passwords saved by macOS. If EasyDMG's own password prompt is needed, input is masked and passed to the system disk-image tool through an input pipe, rather than command-line arguments.

EasyDMG does not save entered passwords or write them to its logs. Any password storage offered by macOS is managed by macOS. Canceling the password prompt stops the installation.

## EasyDMG Updates

EasyDMG's own updates use HTTPS and [Sparkle's signed update archives](https://sparkle-project.org/documentation/). Sparkle verifies archive signatures using the public key included in EasyDMG. These signatures authenticate EasyDMG updates; they don't authenticate other apps you install from DMGs.

## Reporting a Vulnerability

Please do not report security vulnerabilities in public GitHub issues.

Instead, email: `jeffschumann.dev@gmail.com`

Please include:

- a short description of the issue and its potential impact
- the EasyDMG version and macOS version involved
- clear reproduction steps or a proof of concept, if available
- whether the issue has been disclosed anywhere else

If logs would help, EasyDMG's local activity log is at `~/Library/Logs/EasyDMG/easydmg.log`, with older entries in `easydmg.previous.log` in the same folder. Logs can contain usernames, full file paths, app names, and security-check results. Review them before sharing, and send security-related logs privately with your report. See [PRIVACY.md](../PRIVACY.md) for more about local logging.

The goal is to acknowledge receipt within 7 days and share follow-up status as the report is investigated and any fixes are prepared.

## Disclosure Guidance

Please allow time for investigation and a fix before making a vulnerability public. Coordinated disclosure helps protect EasyDMG users while a patch or mitigation is being prepared.

If a report turns out to be a general bug rather than a security issue, it may be redirected to the public issue tracker:

<https://github.com/jeff-schumann/EasyDMG/issues>
