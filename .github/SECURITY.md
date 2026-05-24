# Security Policy

## Supported Versions

EasyDMG security fixes are targeted at the latest published release.

| Version | Supported |
| --- | --- |
| 1.1.x | :white_check_mark: |
| 1.0.x | :x: |
| < 1.0 | :x: |

If you are reporting a security issue, please confirm the affected EasyDMG version and your macOS version in the report.

## Security & Quarantine Architecture

To balance convenience with system safety, EasyDMG performs a security preflight check using macOS security systems (`syspolicy_check`, `spctl`, and `codesign`) before deciding whether to remove quarantine attributes from a copied application.

### App Security Assessment

When processing a `.app` bundle, EasyDMG performs a multi-stage security preflight check:
1. **Primary Assessment**: Verifies the application's distribution status using `syspolicy_check`.
2. **Fallback Assessment**: Falls back to `spctl` verification if `syspolicy_check` is unavailable or times out.
3. **Diagnostics Refinement**: If primary checks fail, executes deep verification with `codesign` to identify the precise cause of failure.

### Handling and Quarantine Decisions

The app is categorized into one of three security states to determine how the `com.apple.quarantine` attribute is handled:

*   **Verified (Notarized / Gatekeeper Approved)**: The app passes all checks. EasyDMG automatically removes the quarantine attribute to prevent App Translocation and enable seamless background updates.
*   **Unverified (Unsigned / Unidentified Developer)**: No malware or tampering is detected, but the developer cannot be verified. EasyDMG prompts the user with a warning before stripping the quarantine attribute. This prompt can be globally bypassed in Settings by enabling **Compatibility Mode**.
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

<https://github.com/jefe-johann/EasyDMG/issues>
