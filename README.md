<div align="center">
  <img src=".github/images/wizardhamster.png" alt="EasyDMG Logo" width="175">
  <h1>EasyDMG</h1>
  <p>
    Automate DMG installation on macOS. Double-click a DMG file, and EasyDMG handles the rest — mounting, copying to Applications, unmounting, and cleanup.
  </p>
  <br>
  <font size="4"><strong> Download the latest version from <a href="https://github.com/jeff-schumann/EasyDMG/releases">Releases</a>, open the DMG and drag to Applications.
    <br>Enjoy it.. it could be the last time you perform this annoying task!
  </strong></font>
</div>

## What EasyDMG Does

After setting EasyDMG as your default app for opening DMGs, opening any DMG will automatically:

1. Mount the DMG
2. Perform macOS security check
3. Install the app to your Applications folder (or a folder you choose)
4. Open the app directly, or open Finder and highlight the app
5. Unmount the DMG
6. Trash the DMG (optional)

## Common Questions

**Is it safe?** <br>
EasyDMG runs the same Gatekeeper check macOS uses, before the app is installed. Apps from verified developers install normally. Apps from unidentified developers get a warning first. Apps macOS flags as malware, damaged, or revoked are never installed automatically. EasyDMG doesn't disable any of macOS's built-in protections.

You can turn off the unidentified-developer warning in Settings. This is not recommended unless you know what you are doing, and often find the warning a pain. Even with the warning off, the macOS security check still runs on every install, and apps flagged as unsafe are still blocked. See [SECURITY.md](https://github.com/jeff-schumann/EasyDMG?tab=security-ov-file) for details.

**What if a DMG isn't a simple drag-and-drop?** <br>
EasyDMG won't guess. If a DMG contains a license agreement, a .pkg installer, more than one app, or anything else unusual, it just opens the DMG so you can take it from there. See [Edge Cases & Safeguards](EDGE_CASES.md) for the full list of situations it handles.

**Do I have to use EasyDMG for every install?** <br>
No. You choose whether EasyDMG is your default DMG handler, and you can open any DMG the usual way with right-click → Open With → DiskImageMounter. Where apps are installed, whether DMGs go to the Trash, and more are up to you in Settings.

## Why Use EasyDMG?
Let's be real, installing apps isn't actually that hard. It's only moderately annoying. But it's nice to make your workflow smoother, even if it doesn't change the world. Plus the hamster is cute.

- **It's EASY!**: Set EasyDMG as your default DMG handler and forget about it. 
- **It's simple**: The app only runs when opening a DMG. It doesn't take up space in your dock or menu bar, it's gone until you need it.
- **It's native**: Built with Swift for macOS, it's quick and seamless.
- **It's fast**: Double-click and go. You might not even get to see the hilarious notes in the progress bar.
- **It's flexible**: Make EasyDMG work the way you want.
  - **Where apps go**: Defaults to `/Applications`, but you can pick any folder you want.
  - **How much you see**: A progress bar, a notification when it's finished, or nothing at all.
  - **What happens after**: Open the app, reveal it in Finder, and send the DMG to the Trash. Or don't.
  - **App updates**: Let newer versions replace older ones automatically, or confirm every time.
- **It's cautious**: Designed to make installation easy while staying safe. When ambiguity arises, if EasyDMG can handle it safely (such as retrying passwords or evaluating licenses), it does; otherwise, it gracefully falls back to manual installation.
- **Save disk space**: Move DMGs to Trash after successful installation. No more old DMGs sitting in your downloads folder!
- **Streamlined Security**: macOS normally forces you to open Privacy & Security to approve unrecognized apps. EasyDMG handles that check during install. Verified apps just open, apps from unidentified developers take one click, and apps macOS flags as unsafe are never installed automatically. See [SECURITY.md](https://github.com/jeff-schumann/EasyDMG?tab=security-ov-file) for details.
- **Automatic updates**: Built-in Sparkle integration for easy updates.
- **It's fun**: The wizard hamster updates you on his silly antics in the progress bar. Learn how to summon your own hamster wizard on the [website](https://easydmg.app/summon-a-wizard-hamster).

## Screenshots

<p align="center">
  <img src="https://github.com/user-attachments/assets/d191385a-b7e6-467d-ab09-c79a190592bb" width="48%" alt="Setup - Light Mode" />
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="https://github.com/user-attachments/assets/6c821692-454f-4753-8bec-bfe2471fb077" width="48%" alt="Settings - Dark Mode" />
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/d5632cd3-7e68-4e35-8568-d9ebcfc3dcc7" alt="EasyDMG Progress Bar" width="425" style="border-radius: 15px;">
</p>

## Installation

Download the latest release from the [Releases](https://github.com/jeff-schumann/EasyDMG/releases) page!

### Setting as Default DMG Handler

1. Simply click the button in settings :-)

OR

Manually set:
1. Right-click any DMG file
2. Select **Get Info**
3. Under "Open with:", select **EasyDMG**
4. Click **Change All...**

Now all DMG files will automatically install when opened.

Don't want to use EasyDMG for a specific DMG? You can still right-click and Open With DiskImageMounter any time.

## Privacy

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://github.com/user-attachments/assets/53a9f03a-f8cd-4ab5-9bdb-5193f958b09e">
  <source media="(prefers-color-scheme: light)" srcset="https://github.com/user-attachments/assets/c16077be-5e9e-437a-8e92-45493f196c25">
  <img width="100" alt="hamster-folder-clean" src="https://github.com/user-attachments/assets/9a2cc7e2-3d27-4f9b-a4dd-092513da88d3">
</picture>

EasyDMG is local and private to the core. 

* **Local Only:** All processing happens on your Mac. Your files and data never leave your machine.
* **No Tracking:** There are no analytics, crash reporters, or third-party trackers.
* **Minimal Connection:** The app only connects to the internet to check for updates via **Sparkle** (connecting directly to GitHub). No personal information is transmitted during this check.
* **Data Storage:** Application settings and logs are stored strictly on your local disk (`~/Library/Logs/EasyDMG`). These logs exist solely to help you troubleshoot; they are only shared if you choose to email them to me for support.

EasyDMG's privacy policy is available in [PRIVACY.md](PRIVACY.md).

## Requirements

- macOS 13 (Ventura) or later

## Distribution

EasyDMG is distributed as a **notarized, code-signed app** outside the App Store. This allows full functionality without sandbox restrictions while maintaining macOS security requirements.

### Why Can't I Download From The App Store?

Apps in the App Store are sandboxed, which prohibits:
- Mounting disk images
- Writing to /Applications
- Accessing files outside the sandbox

These are core to EasyDMG's functionality, making App Store distribution incompatible.

## Building from Source

### Prerequisites

- Xcode 14.0 or later
- macOS development environment
- Swift 5.7+

### Build Instructions

```bash
git clone https://github.com/jeff-schumann/EasyDMG.git
cd EasyDMG
xcodebuild -project EasyDMG.xcodeproj -scheme EasyDMG -configuration Debug build
```

The build script automatically copies the app to `/Applications/EasyDMG_XCODE_TEST.app` for testing.

## License

EasyDMG is dual-licensed:

- **GPL-3.0** for open source use - see [LICENSE](LICENSE) file
- **Commercial License** available for proprietary use - see [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md)

If you're using EasyDMG in an open source project, you're covered by GPL-3.0. If you need to use it in a closed-source/proprietary application, contact me about commercial licensing.

## Contributing

Contributions welcome! Please note:

1. By contributing, you agree to the [Contributor License Agreement (CLA)](CLA.md)
2. All contributions will be dual-licensed under GPL-3.0 and commercial licenses
3. Review [Edge Cases & Safeguards](EDGE_CASES.md) to understand existing behavior before proposing changes.
4. Open an issue to discuss proposed changes before submitting large PRs

Or contribute by buying me a coffee! It fuels further development :)
<p align="left">
  <a href="https://www.buymeacoffee.com/jeff.schumann">
    <img src="https://img.shields.io/badge/Support-Buy%20Me%20a%20Coffee-orange?style=flat-square&logo=buy-me-a-coffee" alt="Buy Me A Coffee">
  </a>
</p>

## Support

Found a bug? Have a feature request? [Open an issue](https://github.com/jeff-schumann/EasyDMG/issues).

EasyDMG keeps a local activity log at `~/Library/Logs/EasyDMG/easydmg.log`. It stays on your Mac unless you choose to share it, and it can help explain why EasyDMG installed an app, skipped it, or fell back to manual mode. Attaching it to an issue is the fastest way to get help.
