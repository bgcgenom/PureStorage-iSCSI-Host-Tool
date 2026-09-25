# Security Policy

## Supported Versions

Security fixes are provided for the current release of the PureStorage iSCSI Host Tool.

| Version | Supported |
| ------- | --------- |
| 2.5.x   | Yes |
| 2.4.x   | No |
| < 2.4   | No |

Older releases remain available for reference but are not actively maintained for security fixes.

## Reporting a Vulnerability

Please do not open a public GitHub issue for a suspected security vulnerability.

If you believe you have found a security issue, use GitHub's private vulnerability reporting feature for this repository when available.

Include as much detail as possible:

- affected tool version
- Windows Server version
- PowerShell version
- Pure Storage PowerShell SDK version
- relevant workflow or function
- steps required to reproduce the issue
- expected behavior
- observed behavior
- whether credentials, tokens, host configuration, array configuration, or storage access could be exposed or modified
- sanitized logs or screenshots when useful

Do not include:

- passwords
- API tokens
- private keys
- authentication cookies
- production IP addresses unless necessary and appropriately sanitized
- customer-confidential information
- unredacted infrastructure exports

## Security Scope

Security-sensitive areas of this project include:

- runtime credential handling
- Pure Storage array authentication
- saved array metadata
- Windows remote administration through WinRM
- Windows iSCSI portal and session configuration
- MPIO configuration
- Pure Storage host registration
- host-group membership changes
- change-preview and confirmation controls
- post-Apply verification
- logging and exported reports

Credentials are intended to remain in memory only for the active session and are not intentionally stored in saved array definitions.

## Safe Configuration Principles

Changes that can modify Windows hosts or Pure Storage configuration should preserve the following safeguards:

- Validate / Dry Run before writes
- explicit Change Preview
- explicit operator confirmation
- no silent destructive remediation
- no silent overwrite of conflicting Pure host objects
- no storage provisioning outside the documented scope
- no disk initialization or formatting
- no automatic CSV or Failover Cluster creation
- no silent per-device MPIO policy changes

## Response

Security reports will be reviewed as time permits.

If a reported issue is confirmed, the preferred remediation process is:

1. reproduce and validate the issue
2. develop and test a fix
3. run repository parser and embedded WPF/XAML validation
4. publish the corrected version
5. document the security-relevant change in the release notes

This is an independent community project and is not an official Pure Storage product.
