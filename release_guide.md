# EasyDMG Release Guide

This is the release flow that actually worked for `1.0.4`.

Publish the final DMG as `EasyDMG.dmg` so GitHub's `releases/latest/download/EasyDMG.dmg` link can stay stable across releases.

The short version:
- Do not package a public release DMG from the plain `Release` build output.
- Archive + export first, then build the DMG from the exported app.
- Notarize and staple the DMG before generating the final Sparkle signature.
- Update `appcast.xml` only after stapling, because stapling changes the DMG bytes.
- Include concise release notes in the new `appcast.xml` item so Sparkle can show users what changed.

Quick checklist:
1. Bump every version reference (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, and the new top `appcast.xml` item if you pre-create it).
2. Archive the app.
3. Export the archive.
4. Verify a nested Sparkle helper has Developer ID authority + timestamp.
5. Build the DMG from the exported app.
6. Sign the DMG.
7. Notarize the DMG.
8. Staple the DMG.
9. Validate the stapled DMG.
10. Run `sign_update` on the stapled DMG.
11. Insert a new top item in `appcast.xml`, including release notes for Sparkle's update prompt.
12. Commit, push, tag, and create the GitHub release.

## Important: Release Notes Approval

**If you are an agent running this release:**

Before proceeding past step 1 (version bump), draft the release notes in the `appcast.xml` `<description>` block and pause to get user approval on:
- The release notes content and tone
- Any known issues or caveats to mention
- Whether to include technical details or keep it high-level

Do not continue with the build until the user approves.

## Prerequisites

Before starting, make sure all of these are true:

- `Developer ID Application: Jeffrey Schumann (M2ABUL7722)` is installed.
- Sparkle signing key exists in Keychain.
- `notarytool` profile exists and works.
- `gh` is logged in if you want to create the GitHub release from the terminal.

Useful checks:

```bash
security find-identity -v -p codesigning | rg "Developer ID Application|Apple Development"
security find-generic-password -s https://sparkle-project.org -a ed25519 -g 2>&1 | head -20
xcrun notarytool history --keychain-profile EasyDMG
gh auth status
```

Notes:
- The Sparkle keychain item should use service `https://sparkle-project.org` and account `ed25519`.
- The public key in the keychain comment should match `SUPublicEDKey` in `EasyDMG/Info.plist`.
- Some release commands may need full system/keychain access. If `xcodebuild -exportArchive`, `hdiutil create`, or Sparkle `sign_update` say a cert/key is missing or the device is not configured, rerun outside the sandbox.

## Agent Sandbox Permissions

If you are an agent running this release in a sandboxed workspace, ask for the needed sandbox permission on the first attempt for known release steps. Do not first run the command, wait for `Device not configured`, keychain, signing, DNS, or permission failures, and then try alternate workarounds. The release process is allowed to need approval; ask clearly and continue once approved.

Request escalation up front for:

- `xcodebuild -exportArchive` if Xcode/keychain access has been flaky in the current session.
- `env BUILD_DIR=... TEMP_DIR=... OUTPUT_DMG=... ./create_dmg.sh`, because it runs `hdiutil create`.
- `codesign --force --sign ... --timestamp ... EasyDMG.dmg`, because it may need keychain/timestamp access.
- `xcrun notarytool submit ... --wait`, `xcrun stapler staple ...`, and `xcrun stapler validate ...`, because they use Apple services and system signing/notarization state.
- Sparkle `sign_update ... EasyDMG.dmg`, because it needs the private Sparkle signing key.
- `hdiutil attach ...` and `hdiutil detach ...` for final downloaded-DMG checks.
- Git writes: `git add`, `git commit`, `git tag`, and `git push`.
- `gh release create` or `gh release upload`, because publishing the GitHub release is externally visible and uses network access.

If approval is denied, pause and tell the user exactly which release step is blocked. Do not substitute a less trustworthy release path just to avoid asking for permission.

## Version Bump

Update these first:

- `EasyDMG.xcodeproj/project.pbxproj`
  - `MARKETING_VERSION`
  - `CURRENT_PROJECT_VERSION`
- `appcast.xml`
  - If you pre-create the new top `<item>` before the build, update only the versioned placeholders:
    - `<title>`
    - `<sparkle:version>`
    - `<sparkle:shortVersionString>`
    - draft release notes in `<description>`
    - release URL / DMG filename in `<enclosure url="...">`
  - Leave `pubDate`, `length`, and `sparkle:edSignature` alone until after stapling and `sign_update`.

Quick sanity check before building:

```bash
rg -n "MARKETING_VERSION|CURRENT_PROJECT_VERSION|DMG_NAME=|<title>|<description>|sparkle:version|sparkle:shortVersionString|releases/download/v" \
  EasyDMG.xcodeproj/project.pbxproj create_dmg.sh appcast.xml
```

Do not fill in the final `appcast.xml` metadata yet.

## Build The Real Release App

Do not use the plain `xcodebuild ... -configuration Release build` output for notarized releases.

That path produced an app where nested Sparkle helpers like `Autoupdate` and the Sparkle XPC services were still ad-hoc signed, which caused notarization to fail.

Use this instead:

```bash
xcodebuild -project EasyDMG.xcodeproj \
  -scheme EasyDMG \
  -configuration Release \
  -archivePath /tmp/EasyDMG-1.0.4.xcarchive \
  archive

xcodebuild -exportArchive \
  -archivePath /tmp/EasyDMG-1.0.4.xcarchive \
  -exportPath /tmp/EasyDMG-1.0.4-export \
  -exportOptionsPlist exportOptions.plist
```

After export, verify one nested Sparkle helper is Developer ID signed with a timestamp:

```bash
codesign -dv --verbose=4 /tmp/EasyDMG-1.0.4-export/EasyDMG.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate 2>&1 | sed -n '1,40p'
```

What you want to see:
- `Authority=Developer ID Application: Jeffrey Schumann (M2ABUL7722)`
- `Timestamp=...`

## Build The DMG

`create_dmg.sh` now supports overriding `BUILD_DIR`, so use the exported app directory:

```bash
BUILD_DIR=/tmp/EasyDMG-1.0.4-export \
TEMP_DIR=/tmp/EasyDMG_1_0_4_export_dmg \
OUTPUT_DMG=/Users/jeff/Jeff/Projects/EasyDMG/EasyDMG.dmg \
./create_dmg.sh
```

Then sign the DMG container too:

```bash
codesign --force \
  --sign "Developer ID Application: Jeffrey Schumann (M2ABUL7722)" \
  --timestamp \
  /Users/jeff/Jeff/Projects/EasyDMG/EasyDMG.dmg
```

## Notarize The DMG

Submit with the saved keychain profile:

```bash
xcrun notarytool submit /Users/jeff/Jeff/Projects/EasyDMG/EasyDMG.dmg \
  --keychain-profile EasyDMG \
  --wait
```

If notarization fails, fetch the log:

```bash
xcrun notarytool log <submission-id> --keychain-profile EasyDMG
```

## Staple And Validate

If notarization is accepted:

```bash
xcrun stapler staple /Users/jeff/Jeff/Projects/EasyDMG/EasyDMG.dmg
xcrun stapler validate /Users/jeff/Jeff/Projects/EasyDMG/EasyDMG.dmg
```

Important:
- `stapler validate` is the check that matters here.
- `spctl -a -vv -t open <local-dmg>` may say `Insufficient Context` for a local file that was not downloaded. That is not the release-blocking check.

## Generate Final Sparkle Metadata

Do this only after stapling.

Stapling changes the DMG bytes, which changes:
- the file size
- the Sparkle signature

Generate the final signature:

```bash
/Users/jeff/Library/Developer/Xcode/DerivedData/EasyDMG-dibggcaewvrasrcrtvhemiwxucou/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
  /Users/jeff/Jeff/Projects/EasyDMG/EasyDMG.dmg
```

This prints something like:

```text
sparkle:edSignature="..." length="..."
```

Insert a new top `<item>` in `appcast.xml` for the new release. Do not overwrite the previous release entry.

Add release notes with a `<description>` block inside the new item. Sparkle shows this HTML in the update prompt.

Use cumulative release-note sections in the newest item. Keep sections newest-first and tag each with its build number so Sparkle can hide notes the user already has:

```xml
<description><![CDATA[
<style>
  .sparkle-installed-version,
  .sparkle-installed-version ~ section[data-sparkle-version] {
    display: none;
  }
</style>

<section data-sparkle-version="12">
<h2>EasyDMG 1.2.0</h2>
<ul>
  <li>Improved DMG handling in edge cases.</li>
</ul>
</section>

<section data-sparkle-version="11">
<h2>EasyDMG 1.1.0</h2>
<ul>
  <li>Previous release bullets here.</li>
</ul>
</section>
]]></description>
```

Notes:
- Put `<description>` before the `<enclosure>` line.
- Use `data-sparkle-version` values from `CURRENT_PROJECT_VERSION`.
- Keep older sections in the newest item so users skipping versions get caught up.
- Do not duplicate older notes inside newer sections.
- Older appcast items can keep their original descriptions.

Update that new item with:
- the new `pubDate`
- `sparkle:version`
- `sparkle:shortVersionString`
- `sparkle:minimumSystemVersion`
- release notes in `<description>`
- the final release URL
- the final `length`
- the final `sparkle:edSignature`

Release URL format:

```text
https://github.com/jeff-schumann/EasyDMG/releases/download/v1.0.4/EasyDMG.dmg
```

## Commit And Push

Once the final DMG is notarized and `appcast.xml` matches the stapled file:

```bash
git add -A
git commit -m "Finalize 1.0.4 release metadata"
git push origin main
```

## Create The GitHub Release

If the tag does not exist yet:

```bash
git tag v1.0.4
git push origin v1.0.4
```

Then create or publish the GitHub release and upload the DMG:

```bash
gh release create v1.0.4 /Users/jeff/Jeff/Projects/EasyDMG/EasyDMG.dmg \
  --title "EasyDMG 1.0.4" \
  --notes "Release notes here"
```

If the release already exists, upload the asset with overwrite:

```bash
gh release upload v1.0.4 /Users/jeff/Jeff/Projects/EasyDMG/EasyDMG.dmg --clobber
```

## Post-Release Checks

After the GitHub release is live:

- Verify the release asset URL matches the URL in `appcast.xml`.
- Verify `appcast.xml` is pushed to `main`.
- Test Sparkle update discovery from an older build.
- Download the DMG from GitHub once and do one real-world open/install check.

Minimal success snapshot:
- `notarytool` status is `Accepted`
- `xcrun stapler validate` succeeds
- the GitHub release asset URL exactly matches the `appcast.xml` enclosure URL
- `git status` is clean after push

## Known Pitfalls

### 1. Plain Release build is not enough

This failed notarization because nested Sparkle binaries stayed ad-hoc signed.

Bad path:

```bash
xcodebuild -project EasyDMG.xcodeproj -scheme EasyDMG -configuration Release build
```

Good path:

```bash
xcodebuild ... archive
xcodebuild -exportArchive ...
```

### 2. Do not generate Sparkle metadata too early

If you run `sign_update` before notarization and stapling, the signature and length will become stale.

### 3. `generate_appcast` is useful, but be careful

It can prune older feed entries by default. If you want to preserve old history exactly, it is safer to:

- use `sign_update` on the final stapled DMG
- patch only the newest `appcast.xml` item manually

### 4. Local `spctl` can be misleading

For a local DMG, `spctl -a -vv -t open` may report `Insufficient Context`.

Use these instead:
- notarization accepted by `notarytool`
- `xcrun stapler validate`

## Current Working Values

These were valid during the `1.0.4` release:

- Notary profile: `EasyDMG`
- Team ID: `M2ABUL7722`
- Bundle ID: `com.jeff.easydmg`
- Sparkle public key is already set in `EasyDMG/Info.plist`
