# v2.5.1 Release Notes

## Overview

v2.5.1 clarifies the difference between the Microsoft DSM global/default MPIO policy and the effective policy reported by an already-presented Pure MPIO device.

The tool now labels Round Robin as the global/default policy and no longer implies that this value proves the effective policy on existing Pure MPIO devices.

No change was made to iSCSI connection creation, persistent sessions, Pure registration, or per-device MPIO policy. The tool remains non-destructive and does not silently change device-level MPIO policy.

## MPIO policy clarification

### Global/default policy

The Windows host baseline continues to use:

```powershell
Get-MSDSMGlobalDefaultLoadBalancePolicy
Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR
```

This is reported as:

```text
Global/default MPIO policy: RR
```

This value is the Microsoft DSM global/default policy. It does not prove the effective policy of an already-presented Pure device.

### Device policy

When device-level policy is exposed by Windows, the tool treats it as a separate runtime observation.

A live ActiveCluster validation example produced:

```text
Global/default MPIO policy: RR
Observed Pure device policy: RRWS
```

RRWS means Round Robin with Subset.

The observed RRWS value is informational in v2.5.1. The tool does not automatically remediate or change it.

## User-interface and reporting changes

- Renamed generic host-level policy labels to **Global/default MPIO policy**.
- Updated host-status details to identify the Microsoft DSM global/default policy explicitly.
- Updated best-practice configuration confirmation text to say that the tool sets the Microsoft DSM global/default MPIO policy to Round Robin.
- Added an MPIO policy note explaining that existing Pure devices can report a different effective per-device policy.
- Updated iSCSI safety wording to state that per-device MPIO policy is not silently changed.
- Updated device verification logging to identify device policy as an observed device-level value.

## Device-level handling

Existing device policy discovery remains read-only.

v2.5.1 distinguishes plain Round Robin from Round Robin with Subset when policy text is available. RRWS is logged as an observed device policy and is not automatically changed.

No `Set-MSDSMLoadBalancePolicy` or other per-device policy-changing logic was added.

## Unchanged behavior

v2.5.1 does not change:

- Pure host registration;
- Host Group handling;
- iSCSI target portal creation;
- persistent multipath iSCSI session creation;
- source/target path planning;
- storage-cache refresh;
- LUN presentation or mapping;
- disk initialization or formatting;
- CSV or Failover Cluster configuration;
- preferred-array settings.

## Safety boundary

The tool continues to configure the host/global baseline with:

```powershell
Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR
```

It does not infer or force a per-device policy from that global/default setting.

## Upgrade

v2.5.1 is a separate script:

`iSCSI-Host-Tool-v2.5.1.ps1`

v2.5.0 remains available for reference, and v2.4.19 remains under `Archive/`.
