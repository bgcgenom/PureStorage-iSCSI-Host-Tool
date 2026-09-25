# v2.5.0 Release Notes

## Overview

v2.5.0 adds a complete Windows-side Pure Storage iSCSI connection workflow to the existing host-readiness and Pure registration tooling.

## New in v2.5.0

- Recommended iSCSI topology builder based on audited Windows host interfaces and connected Pure array target ports.
- Automatic target IQN discovery from Pure arrays.
- Same-subnet source/target matching with manual mapping support for exceptions.
- Hierarchical iSCSI plan view grouped by host and array.
- Editable path inclusion with preserved tree expansion state.
- Host/array validation badges and per-path validation results.
- TCP/3260 source-bound preflight validation.
- Existing portal/session detection with idempotent `MATCH` handling.
- Explicit Change Preview before Apply.
- Creation of Windows iSCSI target portals and persistent multipath sessions only after operator confirmation.
- Post-Apply verification of portals, active sessions, persistence, and intended source/target addressing.
- Automatic `Update-HostStorageCache` on affected hosts after successful iSCSI connection writes.
- Best-effort Pure disk detection after storage-cache refresh; absence of presented LUNs is informational.
- Successful post-verification now marks affected hosts, arrays, and enabled paths as **Applied / Verified**.
- Resizable, scrollable iSCSI Change Preview / confirmation dialog.
- Hierarchical Windows Host and Pure Registration result views.

## Safety boundaries

v2.5.0 does not:

- create or map Pure volumes or LUNs;
- initialize or format disks;
- create Cluster Shared Volumes;
- create or modify Pods or Protection Groups;
- build or modify Windows Failover Cluster configuration;
- change preferred-array settings;
- silently change per-device MPIO policy;
- create iSCSI paths outside the validated and confirmed plan.

## Validation

The v2.5.0 candidate was exercised against both first-time and already-configured Windows hosts. The workflow supports idempotent reruns: existing correct portals and sessions are reported as `MATCH`, while post-Apply verification confirms the final runtime state.

The repository CI validates PowerShell parsing and embedded WPF/XAML loading.

## Upgrade

v2.4.19 remains in the repository for reference. v2.5.0 is a separate script:

`iSCSI-Host-Tool-v2.5.0.ps1`

Saved array definitions remain credential-free; runtime authentication is still required after restart.
