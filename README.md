# PureStorage iSCSI Host Tool

PowerShell/WPF utility for validating and configuring Windows Server hosts for Pure Storage iSCSI connectivity, MPIO readiness, host registration, and host-group workflows.

> **Project status:** Current completed release: **v2.5.1**
>
> This is an independent community project and is not an official Pure Storage product.

> [!WARNING]
> ## Use at Your Own Risk
>
> This tool can make configuration changes to Windows Server hosts and Pure Storage arrays.
>
> Depending on the selected workflow, changes may include Windows iSCSI/MPIO settings, Microsoft DSM configuration, power-plan settings, Pure Storage host registration, IQN assignment, and host-group membership.
>
> Review all audit results, Dry Run output, Change Preview information, and confirmation prompts before applying changes.
>
> Test the tool in a non-production environment before using it in production. Use appropriate backups, change-control procedures, and recovery plans.
>
> The authors and contributors are not responsible for data loss, service interruption, outages, misconfiguration, loss of access, or other damages resulting from use or misuse of this software.
>
> This software is provided **"as is"**, without warranty of any kind. See the [MIT License](LICENSE) for the full license terms.

## What it does

The tool provides a guided workflow for preparing Windows Server hosts, validating Pure Storage host registration, building a recommended Pure iSCSI connection plan, and safely applying verified iSCSI portal/session configuration.

### Windows host readiness

- Audits one or more Windows Server hosts.
- Discovers each host iSCSI IQN.
- Validates the Microsoft iSCSI Initiator service.
- Validates/installs Multipath-IO (MPIO).
- Registers `PURE / FlashArray` with Microsoft DSM.
- Sets the Microsoft DSM global/default MPIO policy to Round Robin.
- Applies Pure-recommended global MPIO timers.
- Sets the Windows power plan to High Performance.
- Tracks whether a reboot is required.
- Supports explicit reboot and post-reboot verification workflows.

### Pure Storage registration

- Connects to one or more Pure Storage arrays.
- Supports saved array definitions without storing credentials.
- Validates host names and IQNs before array-side changes.
- Detects name and IQN conflicts.
- Supports:
  - No Host Group
  - Create Host Group
  - Use Existing Host Group
- Existing Host Group selection is populated from connected arrays.
- With multiple connected arrays, only Host Group names common to all connected arrays are presented.
- Provides Validate / Dry Run before Apply.
- Provides Change Preview and confirmation before Pure-side writes.
- Preserves post-Apply verification and logging workflows.

### iSCSI connections

- Builds a recommended host-to-array iSCSI topology from audited Windows hosts and connected Pure arrays.
- Discovers Pure iSCSI target ports/IPs and target IQNs from connected arrays.
- Uses same-subnet matching between host source IPs and Pure target IPs.
- Supports manual mapping for exceptions and non-standard topologies.
- Creates or reuses Windows iSCSI target portals.
- Establishes persistent, multipath iSCSI sessions.
- Validates source IP, target IP, TCP/3260 reachability, portal state, and session state before Apply.
- Treats existing correct configuration as `MATCH`.
- Refreshes the Windows storage cache with `Update-HostStorageCache` after a successful Apply.
- Performs post-Apply verification and marks verified hosts, arrays, and enabled paths as Applied / Verified.
- Detects visible Pure disks when present without requiring LUN presentation to complete the iSCSI workflow.

### Operational features

- Connectivity preflight checks.
- Session status banner.
- Export CSV / Export All.
- Session logging.
- Integrated HTML user documentation.
- Visible application version.
- Session reset without discarding active array connections until the application closes.

## Safety boundaries

The tool is intentionally scoped to Pure Storage host readiness and Pure host registration.

### Changes the tool may make

Depending on the selected workflow and operator confirmation, the tool may modify:

- Windows iSCSI Initiator service configuration;
- Windows Multipath-IO configuration;
- Microsoft DSM registration for `PURE / FlashArray`;
- global/default MPIO settings;
- Pure-recommended MPIO timer settings;
- Windows power-plan configuration;
- Pure Storage host objects;
- host IQN assignments;
- Pure Storage host-group membership;
- explicitly approved Windows iSCSI target portals and persistent/multipath sessions;
- Windows host storage-cache refresh after successful iSCSI Apply.

Array-side changes are not performed silently. Review the Dry Run, Change Preview, and confirmation prompts before Apply.

### Operations intentionally out of scope

The tool **does not**:

- create volumes;
- connect or map LUNs;
- create Cluster Shared Volumes (CSVs);
- create or modify Pods;
- create or modify Protection Groups;
- build a Windows Failover Cluster;
- create storage paths outside the validated iSCSI connection plan;
- silently overwrite conflicting Pure host objects.

These operations remain outside the tool by design.

## Requirements

- Windows PowerShell 5.1 or later
- Windows Presentation Foundation (WPF)
- Administrator rights
- WinRM access to target Windows hosts
- DNS resolution for target hosts and arrays
- HTTPS/TCP 443 access to Pure arrays
- `PowerShellGet`
- `PureStoragePowerShellSDK2`

The tool checks prerequisites and requests approval before installing missing supported dependencies.

## Quick start

1. Run the tool from an elevated PowerShell session.
2. Open **Prerequisites** and verify required components.
3. Enter Windows Server host names.
4. Select **Audit Hosts**.
5. Review the Windows baseline results.
6. If needed, select **Configure Pure Best Practices**.
7. Reboot hosts when the tool reports that a reboot is required.
8. Run **Audit Hosts** again after reboot.
9. Connect one or more Pure arrays.
10. Choose a Host Group mode.
11. Run **Validate / Dry Run**.
12. Resolve any blocked/conflicting rows.
13. Review **Change Preview**.
14. Run **Apply Pure Registration** only when the validated plan is correct.
15. Open **iSCSI Connections**.
16. Select **Build Recommended Plan** or add manual mappings for exceptions.
17. Run **Validate / Dry Run** and resolve any blocked paths.
18. Review **Show Change Preview**.
19. Run **Apply iSCSI Connections**.
20. Confirm the hosts/arrays show **Applied / Verified** and the enabled paths show **Applied / Verified**.
21. Review the log and export results as required.

## Windows baseline

The current host-level Pure baseline includes:

| Setting | Expected state |
|---|---|
| Microsoft iSCSI Initiator | Automatic / Running |
| Multipath-IO | Installed |
| Microsoft DSM | `PURE / FlashArray` registered |
| Global/default MPIO policy | Round Robin |
| NewPathRecoveryInterval | 20 |
| CustomPathRecovery | Enabled |
| NewPDORemovePeriod | 30 |
| NewDiskTimeout | 60 |
| NewPathVerificationState | Enabled |
| Windows power plan | High Performance |

The Round Robin setting above is the **Microsoft DSM global/default MPIO policy**, obtained with `Get-MSDSMGlobalDefaultLoadBalancePolicy` and configured with `Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR`.

This value does **not** prove the effective policy of an already-presented Pure MPIO device. Device-level policy is a separate runtime value and may differ based on Windows MPIO/ALUA behavior.

Example observed during live validation:

- Global/default MPIO policy: `RR`
- Observed Pure device policy: `RRWS` (Round Robin with Subset)

The tool does not treat the observed RRWS value as an instruction to change the device and does not silently apply per-device MPIO policy changes.

## Validation states

Common Pure registration states include:

| State | Meaning |
|---|---|
| `CREATE` | Host does not exist and the IQN is not already assigned. |
| `MATCH` | Existing host matches the expected IQN. |
| `HOST EXISTS - IQN MISSING` | Host exists without the expected IQN. |
| `NAME CONFLICT - DIFFERENT IQN` | Host name exists with a different IQN. |
| `IQN CONFLICT` | IQN is already assigned to another host. |
| `REVIEW` | Additional operator review is required. |
| `BLOCKED` | Apply is prevented until the condition is resolved. |

The tool does not silently overwrite or delete conflicting host definitions.

## Saved array definitions and credentials

Saved array definitions are designed to store only connection metadata such as endpoint and array name.

Credentials are not stored in the saved definition.

- Runtime credentials remain in memory only.
- Reauthentication is required after restarting the tool.
- Saved array metadata is protected with Windows DPAPI.
- Legacy unprotected saved-array data is migrated when supported by the running version.

Do not commit `arrays.dat`, logs, exports, credentials, or environment-specific reports to source control.

## Documentation

The application includes an integrated HTML user guide.

Additional documentation is maintained under `Docs/`:

- `USER-GUIDE.html`
- `OPERATIONS-GUIDE.md`
- `TROUBLESHOOTING.md`
- `SECURITY-SCOPE.md`
- `CHANGE-CHECKLIST.md`

## Repository layout

```text
PureStorage-iSCSI-Host-Tool/
├── iSCSI-Host-Tool-v2.5.1.ps1
├── RELEASE-NOTES-v2.5.1.md
├── Archive/
│   ├── iSCSI-Host-Tool-v2.5.0.ps1
│   ├── RELEASE-NOTES-v2.5.0.md
│   └── iSCSI-Host-Tool-v2.4.19.ps1
├── README.md
├── LICENSE
├── .gitignore
└── Docs/
    └── USER-GUIDE.html
