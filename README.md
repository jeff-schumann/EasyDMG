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

After setting EasyDMG as your default app for opening DMGs (instructions below - but it's just "click the button"), opening any DMG will automatically:

1. Mount the DMG
2. Copy the app to /Applications folder
3. Open Applications and highlight the new app, ready for you to run it
4. Unmount the DMG
5. Trash the DMG (optional via Settings)

## Features

- **It's EASY!**: Set EasyDMG as your default DMG handler and forget about it. 
- **It's simple**: After setting as your default, the app only runs when opening a DMG. Doesn't take up space in your dock or menubar, it's gone until you need it
- **It's fun**: Enjoy the hamster progress bar if enabled 🪄
- **It's native**: Built with Swift for MacOS, it's quick and seamless
- **Flexible settings**: Choose between progress window, notifications, or silent mode
- **Save disk space**: Optionally moves DMGs to Trash after successful installation. No more old DMGs sitting in your downloads folder!
- **Safety third**: If EasyDMG encounters anything unusual (license agreements, multiple apps, pkg installers), it opens the DMG and lets you handle it manually. It only automates the simple, common case.
- **Automatic updates**: Built-in Sparkle integration for easy updates

## Screenshots

<p align="center">
  <img src="https://github.com/user-attachments/assets/5e454a37-bef2-47ce-9853-5febc06fd07c" width="48%" alt="Setup - Light Mode" />
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="https://github.com/user-attachments/assets/5a6f142b-f8e2-4719-9fc3-3fe8b4327a3e" width="48%" alt="Settings - Dark Mode" />
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

EasyDMG is designed to be private by default. 

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

## Known Limitations

EasyDMG follows a "when in doubt, go manual" philosophy. For unusual DMG configurations (license agreements, multiple apps, pkg installers), it opens the DMG for manual installation rather than risking incorrect automation.

Some edge cases are documented and being tested - see [EDGE_CASES.md](EDGE_CASES.md) for detailed technical documentation including resolved and outstanding issues.

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
3. Review [EDGE_CASES.md](EDGE_CASES.md) for known issues and testing priorities
4. Open an issue to discuss proposed changes before submitting large PRs

## Support

Found a bug? Have a feature request? [Open an issue](https://github.com/jeff-schumann/EasyDMG/issues).

EasyDMG keeps a local support log at `~/Library/Logs/EasyDMG/support.log`. It stays on your Mac unless you choose to share it, and it can help explain why EasyDMG installed an app, skipped it, or fell back to manual mode.

If support needs deeper troubleshooting, you can enable verbose diagnostics:

```bash
defaults write com.jeff.easydmg diagnosticLoggingEnabled -bool YES
```

Then reproduce the issue and check `~/Library/Logs/EasyDMG/diagnostic.log`. To turn verbose diagnostics back off:

```bash
defaults delete com.jeff.easydmg diagnosticLoggingEnabled
```
