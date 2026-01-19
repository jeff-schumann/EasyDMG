<p align="center">
  <img src=".github/images/wizardhamster.png" alt="EasyDMG Logo" width="175">
  <br><br>
  <strong><font size="6">EasyDMG</font></strong>
  <br><br>
  Automate DMG installation on macOS. Double-click a DMG file, and EasyDMG handles the rest - mounting, copying to Applications, unmounting, and cleanup.
</p>

## Features

- **Zero-click installation**: Set EasyDMG as your default DMG handler and forget about it
- **Smart automation**: Automatically detects .app files and copies them to /Applications
- **Flexible feedback**: Choose between progress window, notifications, or silent mode
- **Save disk space**: Optionally moves DMGs to Trash after successful installation. No more old DMGs sitting in your downloads folder!
- **Simple only**: If EasyDMG encounters anything unusual (license agreements, multiple apps, pkg installers), it opens the DMG and lets you handle it manually. It only automates the simple, common case.
- **Safety first**: Prompts for confirmation when apps already exist
- **Automatic updates**: Built-in Sparkle integration for seamless updates

## Screenshots

<p align="center">
  <img src="https://github.com/user-attachments/assets/f5322123-caed-4677-993e-fec5a83cd6a8" alt="EasyDMG Progress Bar" width="500">
</p>
<p align="center">
<img width="331" height="300" alt="SCR-20260119-cqjv" src="https://github.com/user-attachments/assets/6e6b094e-5a3e-403a-89a8-1965cef1ccfb" />
</p>

## Installation

Download the latest release from the [Releases](https://github.com/jefe-johann/EasyDMG/releases) page and drag to Applications.

### Setting as Default DMG Handler

1. Right-click any DMG file
2. Select **Get Info**
3. Under "Open with:", select **EasyDMG**
4. Click **Change All...**

Now all DMG files will automatically install when opened.

## Requirements

- macOS 10.15 (Catalina) or later
- Notarized and code-signed for security

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
git clone https://github.com/jefe-johann/EasyDMG.git
cd EasyDMG
xcodebuild -project EasyDMG.xcodeproj -scheme EasyDMG -configuration Debug build
```

The build script automatically copies the app to `/Applications/EasyDMG_XCODE_TEST.app` for testing.

## Architecture

Built with SwiftUI and AppKit:

- **EasyDMGApp.swift** - App lifecycle and file handling
- **DMGProcessor.swift** - Core DMG processing logic
- **ProgressWindow.swift** - Floating notification-style progress UI
- **SettingsWindow.swift** - User preferences and setup instructions
- **Sparkle** - Automatic update framework

## License

EasyDMG is dual-licensed:

- **GPL-3.0** for open source use - see [LICENSE](LICENSE) file
- **Commercial License** available for proprietary use - see [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md)

If you're using EasyDMG in an open source project, you're covered by GPL-3.0. If you need to use it in a closed-source/proprietary application, contact us about commercial licensing.

## Contributing

Contributions welcome! Please note:

1. By contributing, you agree to the [Contributor License Agreement (CLA)](CLA.md)
2. All contributions will be dual-licensed under GPL-3.0 and commercial licenses
3. Review [EDGE_CASES.md](EDGE_CASES.md) for known issues and testing priorities
4. Open an issue to discuss proposed changes before submitting large PRs

## Support

Found a bug? Have a feature request? [Open an issue](https://github.com/jefe-johann/EasyDMG/issues).
