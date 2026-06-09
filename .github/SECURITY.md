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

## Security & Quarantine Architecture

To balance convenience with system safety, EasyDMG performs a security preflight check using macOS security tools (`spctl` and `codesign`) before deciding whether to remove quarantine attributes from a copied application.

### App Security Assessment

When processing a `.app` bundle, EasyDMG performs a multi-stage security preflight check:
1. **Primary Assessment**: Runs `spctl --assess --type execute` to match macOS's launch-time Gatekeeper decision. Stapled apps are verified locally; unstapled-but-notarized apps trigger an online lookup with Apple's notary service.
2. **Diagnostics Refinement**: If `spctl` rejects the app, EasyDMG runs `codesign --verify --deep --strict` to identify the precise cause (revoked signature, tampered bundle, unsigned, etc.).

### Handling and Quarantine Decisions

The app is categorized into one of three security states to determine how the `com.apple.quarantine` attribute is handled:

*   **Verified (Notarized / Gatekeeper Approved)**: The app passes all checks. EasyDMG automatically removes the quarantine attribute to prevent App Translocation and enable seamless background updates.
*   **Unverified (Unsigned / Unidentified Developer)**: No malware or tampering is detected, but the developer cannot be verified. EasyDMG prompts the user with a warning before stripping the quarantine attribute. This prompt can be globally bypassed by enabling **Do not warn me about apps from unidentified developers** in Settings.
*   **Blocked (Malware / Revoked / Damaged)**: If macOS reports active malware, a revoked signature, or a tampered/damaged bundle, EasyDMG **refuses** to automatically remove quarantine and restricts options to canceling or manual installation.

## Reporting a Vulnerability

Please do not report security vulnerabilities in public GitHub issues.

Instead, email: `jeffschumann.dev@gmail.com`

Please include:

- a short description of the issue and its potential impact
- the EasyDMG version and macOS version involved
- clear reproduction steps or a proof of concept, if available
- whether the issue has been disclosed anywhere else

Reports will be reviewed as quickly as possible. If the report is confirmed, the goal is to acknowledge receipt within 7 days and share follow-up status as fixes or mitigations are prepared.

## Disclosure Guidance

Please allow time for investigation and a fix before making a vulnerability public. Coordinated disclosure helps protect EasyDMG users while a patch or mitigation is being prepared.

If a report turns out to be a general bug rather than a security issue, it may be redirected to the public issue tracker:

<https://github.com/jeff-schumann/EasyDMG/issues>
