# Contributing

Thank you for your interest in contributing to the PureStorage iSCSI Host Tool.

This project is intended to remain Pure Storage-specific while staying generic across supported Windows host environments.

## Project Scope

Contributions should preserve the following design principles:

- Pure Storage-specific behavior and best practices
- no assumptions tied to one customer's environment
- no hardcoded host names, array names, IP addresses, VLANs, site mappings, or path counts
- environment-specific topology and expectations should be configurable
- no support for non-Pure storage vendors
- destructive or configuration-changing actions must be explicit
- Dry Run / validation should precede writes
- Change Preview should clearly show intended changes
- Apply actions should require operator confirmation
- existing configuration should be detected and treated idempotently where possible

## Out of Scope

The iSCSI Host Tool is not intended to:

- create or map Pure volumes or LUNs
- initialize or format disks
- create Cluster Shared Volumes
- create or modify Pure Pods
- create or modify Protection Groups
- build or modify Windows Failover Clusters
- change preferred-array settings
- silently change per-device MPIO policy
- automatically remediate storage topology outside the validated plan

Deep read-only host and device validation may be better suited to the separate PureStorage Host Validation / Readiness project.

## Requirements

Development and testing should account for:

- Windows PowerShell 5.1 or later
- Windows Presentation Foundation (WPF)
- PowerShell remoting / WinRM
- PureStoragePowerShellSDK2
- Microsoft iSCSI Initiator
- Microsoft Multipath-IO (MPIO)

## Coding Guidelines

### PowerShell

- keep compatibility with Windows PowerShell 5.1 unless a version change is explicitly approved
- avoid use of reserved or automatic variable names such as `$Host`
- prefer clear, explicit error handling
- do not suppress errors unless failure is intentionally best-effort
- do not store credentials, API tokens, or secrets
- avoid global machine-wide configuration changes when a narrower scope is sufficient

### WPF

- keep UI behavior consistent with existing tabs and controls
- avoid fixed layouts that prevent resizing or scrolling
- preserve tree expansion state where practical
- keep status text clear and operationally meaningful

## Validation Requirements

Before submitting a change:

1. Confirm the PowerShell script parses without errors.
2. Confirm embedded WPF/XAML loads successfully.
3. Test Dry Run / validation behavior.
4. Verify existing correct configuration remains idempotent.
5. Verify blocked/conflict conditions still prevent Apply.
6. Confirm no out-of-scope storage operations were introduced.

Repository CI currently validates:

- PowerShell parser correctness
- embedded WPF/XAML validity

## Pull Requests

Pull requests should include:

- a concise description of the change
- why the change is needed
- affected workflows
- whether the change performs writes
- validation/testing performed
- screenshots for UI changes when useful

Changes that modify Windows hosts or Pure arrays should clearly document:

- what is read-only
- what changes configuration
- what confirmation is required
- how post-change verification works

## Security

Do not include:

- passwords
- API tokens
- private keys
- production secrets
- unredacted customer information
- environment-specific confidential data

Security issues should be reported according to `SECURITY.md`.

## Style

Keep the tool operationally clear and conservative.

Prefer explicit status such as:

- `MATCH`
- `CREATE`
- `CONNECT`
- `BLOCKED`
- `Applied / Verified`

over ambiguous success messages.

## License

By contributing, you agree that your contribution may be distributed under the MIT License used by this project.

This is an independent community project and is not an official Pure Storage product.
