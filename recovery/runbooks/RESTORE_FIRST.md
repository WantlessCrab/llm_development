# RESTORE FIRST

## Emergency rule

This is the canonical human restore runbook for the full-machine recovery system.

Use this file first during any restore, corruption response, or full backup readiness review. Do not follow old numbered
placeholder runbooks. Do not improvise from memory. Do not start with a familiar command. Identify the failed layer, the
active authority path, the exact artifact to use, and the stop conditions that apply before running any destructive
command.

This runbook coordinates lower rows. It does not create the low-level backup artifacts itself.

## Authority map

The recovery stack is ordered from physical media to human execution. A lower row owns the artifact or fact. A higher
row may reference it but must not become a second owner.

| Row | Authority | Owns | Does not own |
|---:|---|---|---|
| 01 | smartmontools / GSmartControl | Physical drive admissibility and media health gates. | Files, vaults, dumps, restore order. |
| 02 | Rescuezilla | Offline whole-disk image baseline and bootable restore image facts. | Post-image deltas, DB consistency, package semantics. |
| 03 | cryptsetup / LUKS2 | Encrypted vault substrate, mapper identity, header backup, wrong-disk guards. | Backup payload semantics. |
| 04 | sha256sum / b3sum | Byte-level integrity manifests and restore-admissibility hashes. | Artifact creation or semantic correctness. |
| 05 | rsync | Controlled one-way staging and cold-copy transport, including VM disk transport. | Version history, DB consistency, Docker semantics. |
| 06 | BorgBackup | Deduplicated versioned filesystem payload recovery. | Borgmatic policy orchestration. |
| 07 | borgmatic | Borg policy, retention, checks, hooks, and dry-run/backup cadence. | Payload ownership. |
| 08 | systemd | Local deterministic activation of scheduled/manual recovery jobs. | Payloads, hashes, packages, DB dumps. |
| 09 | journalctl | Execution evidence and failure diagnostics. | Backup correctness or restore decisions. |
| 10 | apt / dpkg / apt-mark / apt-cache | Native OS package and driver reinstall recoverability. | Flatpak, pipx, Docker workload state, user files. |
| 11 | Flatpak CLI | Flatpak remotes, apps, runtimes, overrides, reinstall plan. | `~/.var/app` file payload bytes, which Borg owns. |
| 12 | pipx | pipx-managed CLI reinstall recoverability. | Project venvs, apt Python packages, Docker Python. |
| 13 | dconf / Cinnamon files | Desktop/session/user-experience settings and previewed restore. | Package install state, full PipeWire authority. |
| 14 | Docker / Compose | Docker workload reconstruction and selected guarded artifacts. | PostgreSQL logical recovery, Portainer UI authority, apt install. |
| 15 | Portainer | Portainer-specific Docker-managed UI state and restore plan. | Docker Engine install, generic Docker recovery. |
| 16 | PostgreSQL | Logical database recovery through dumps, restore-list, smoke checks. | Raw Docker volume as primary DB recovery. |
| 17 | libvirt / QEMU / swtpm | Future Windows VM host-side recovery metadata and VM safety gates. | rsync disk copy, package install, in-guest Windows backup. |
| 18 | Restore runbooks | Human execution workflow, validation, stop conditions, proof bundle index. | Low-level artifact creation. |

## Source repo versus vault separation

The source repository is the working recovery project under `/home/wantless/PycharmProjects/automation/recovery`.

The vault is the encrypted backup target opened through Row 03.

The source repository owns recovery logic, scripts, schemas, runbooks, service definitions, and restore plans. The vault
owns protected recovery artifacts such as images, Borg repositories, dumps, manifests, exports, proof bundles, and
cold-copy payloads. Do not edit source logic directly inside the vault. Do not treat a vault artifact as the current
source definition unless it has been intentionally restored into the source repository and reviewed.

Stop on [STOP-UNCLEAR-AUTHORITY] if a source-repo file and a vault artifact disagree about what action should be taken.

## Baseline image versus Borg delta workflow

Rescuezilla owns the bootable baseline image. Borg owns versioned post-image filesystem deltas.

Use the Rescuezilla image when the system disk, boot path, EFI/root relationship, or OS baseline must be restored. Use
Borg after the baseline boots to restore newer user files, projects, configs, source trees, selected system config, and
app data.

Do not expect the Rescuezilla image to include every later local file. Do not expect Borg alone to recreate the bootable
system disk layout. Both layers are required for maximal full-computer recovery.

## Integrity gates

Integrity gates are mandatory trust checks before recovery artifacts are used.

Row 04 owns the byte-level hash manifests and checks. Row 18 owns the human decision: if a required integrity check
fails, stop and return to the owning artifact row before using the artifact.

A restore artifact with failed, missing, or mismatched integrity proof is not trusted until the owning row resolves it.

## Logical database authority

PostgreSQL recovery authority is logical, not raw-volume-primary.

Row 16 owns `pg_dump -Fc`, `pg_dumpall --globals-only --no-role-passwords`, `pg_restore --list`, disposable restore
verification, schema gates, and row-count sanity. Docker volume identity is evidence; it is not the primary database
recovery artifact.

Stop on [STOP-MISSING-DUMP] or [STOP-UNVERIFIED-DUMP] if required logical database evidence is missing or fails
verification.

## Docker and Portainer boundary

Docker/Compose reconstruction belongs to Row 14. Portainer-specific UI/workload state belongs to Row 15.

Portainer is restored after Docker is healthy and must not be used as the authoritative memory of all Docker state.
`latest`, `lts`, or an unversioned Portainer image is not restore authority. Stop on [STOP-PORTAINER-LATEST] if a
restore plan tries to use it.

## VM cold-copy authority

VM disk transport belongs to Row 05 rsync. Row 17 owns VM identity, domain XML, qemu-img facts, NVRAM, swtpm path
metadata, and no-live-disk-copy gates. Row 18 coordinates the human decision but does not copy VM disk payloads.

Stop on [STOP-LIVE-VM-DISK] if the VM disk is in use by a running, paused, suspended, blocked, crashed, or shutting-down
domain.

## Smoke tests

Smoke tests are recovery decision gates, not optional comfort checks.

A smoke test proves the restored layer functions at the minimum acceptable level before a dependent layer starts.
PostgreSQL smoke checks precede database-backed services. Docker workload checks precede Portainer. Desktop session
checks occur after package/user-file restore. Future Windows VM smoke checks occur only after domain XML, disk, NVRAM,
swtpm, and BitLocker/TPM conditions are reviewed.

## Layer order

Normal restore order follows the row order unless a stop condition says otherwise.

1. Prove media health and identify active disks.
2. Restore the baseline image if the root disk is corrupt or replaced.
3. Open the encrypted vault only after wrong-disk guards pass.
4. Verify integrity of selected recovery artifacts.
5. Stage or move artifacts only through controlled transport.
6. Restore filesystem deltas from Borg.
7. Apply borgmatic policy only after Borg repository checks pass.
8. Re-enable automation only after manual restore is validated.
9. Preserve logs and failure evidence.
10. Restore native packages.
11. Restore Flatpaks.
12. Restore pipx CLIs.
13. Restore desktop/user experience settings.
14. Restore Docker/Compose workloads.
15. Restore Portainer.
16. Restore PostgreSQL logically.
17. Restore future VM host-side state.
18. Run this checklist, document evidence, and create a fresh post-recovery backup.

## First-build procedure

Use this procedure when building the recovery stack for the first time on the healthy host.

- [ ] [CHK-FIRST-01] Confirm Rows 01-18 source files exist with
  `scripts/18_runbooks.sh assert-required-artifacts --level source`.
- [ ] [CHK-FIRST-02] Retire old placeholder runbooks with
  `scripts/18_runbooks.sh retire-old-placeholders --execute --confirm-token RETIRE_OLD_PLACEHOLDER_RUNBOOKS` only after
  reviewing the plan and setting the configured guard environment variable.
- [ ] [CHK-FIRST-03] Run every lower row's local verification sequence in order.
- [ ] [CHK-FIRST-04] Generate Row 18 index with `scripts/18_runbooks.sh render-index`.
- [ ] [CHK-FIRST-05] Generate proof bundle index with `scripts/18_runbooks.sh generate-proof-bundle-index`.
- [ ] [CHK-FIRST-06] Run `scripts/18_runbooks.sh check-completeness`.
- [ ] [CHK-FIRST-07] Do not touch the HDD or vault with first full backup writes until local proofs are complete, except
  rows whose intended operation inherently requires external media.

## Normal backup procedure

Use this when the machine is healthy and performing the planned recurring or manual backup.

- [ ] [CHK-NORMAL-01] Run Row 01 `gate` and confirm source NVMe and backup HDD health are admissible.
- [ ] [CHK-NORMAL-02] Confirm Row 03 vault identity and mount/open state. Stop on [STOP-UNKNOWN-VAULT]
  or [STOP-UNMOUNTED-VAULT].
- [ ] [CHK-NORMAL-03] Run Row 07 dry-run before any real borgmatic backup.
- [ ] [CHK-NORMAL-04] Capture package, Flatpak, pipx, desktop, Docker, Portainer, PostgreSQL, and libvirt facts before
  or during the backup cycle as intended by their rows.
- [ ] [CHK-NORMAL-05] Run Row 16 `dump-all-required` and Row 16 `verify-restore-list` for PostgreSQL before treating the
  backup set as database-recoverable.
- [ ] [CHK-NORMAL-06] Run Row 04 integrity manifests over completed artifacts.
- [ ] [CHK-NORMAL-07] Run Row 09 log capture after job completion.
- [ ] [CHK-NORMAL-08] Run Row 18 proof bundle index and archive the evidence set.

## SSD-corruption decision tree

Use this when the internal SSD, root filesystem, bootloader, or OS is suspected corrupt.

1. Stop all non-essential writes.
2. Do not run filesystem repair until media health and image strategy are reviewed.
3. Run Row 01 SMART/NVMe health capture from a safe environment.
4. If the root disk is failing, replace the disk and use Row 02 image restore rather than writing more to the failing
   source.
5. If the disk is healthy but root filesystem is corrupt, decide whether to image current state for evidence before
   repair.
6. If the backup vault has not been verified, stop on [STOP-UNKNOWN-VAULT].
7. After restoring baseline image, restore Borg deltas and logical databases in order.
8. After successful recovery, create a new post-recovery backup before resuming normal work.

## Bare-metal restore

Bare-metal restore means the system disk is being restored to a bootable baseline using Row 02.

- [ ] [CHK-BM-01] Confirm target disk identity. Stop on [STOP-WRONG-DISK] or [STOP-ROOT-DISK].
- [ ] [CHK-BM-02] Confirm replacement SSD size gate using Row 02 and Row 01 facts.
- [ ] [CHK-BM-03] Confirm Rescuezilla image manifest and integrity proof.
- [ ] [CHK-BM-04] Restore EFI/root/partition image relationship exactly as captured.
- [ ] [CHK-BM-05] Boot once into the restored system before applying post-image deltas.
- [ ] [CHK-BM-06] Capture post-boot logs through Row 09.

## Post-image delta restore

Post-image delta restore means restoring newer files, configs, source trees, user data, and app state after the image
baseline.

- [ ] [CHK-DELTA-01] Confirm LUKS vault opened through Row 03, not an ad hoc mount.
- [ ] [CHK-DELTA-02] Confirm Borg repository identity, key export, and repository check.
- [ ] [CHK-DELTA-03] Use Row 06 restore-preview before `restore-selected`.
- [ ] [CHK-DELTA-04] Restore `/home/wantless`, PyCharm projects, source trees, dotfiles, selected `/etc`, `/opt`,
  `/usr/local`, user app data, and artifacts according to Row 06 policy.
- [ ] [CHK-DELTA-05] Do not overwrite active restored configs without a preview and backup.

## Package and app restore

- [ ] [CHK-PKG-01] Use Row 10 restore plan for apt/dpkg/native packages.
- [ ] [CHK-PKG-02] Confirm apt sources, keyrings, preferences, holds, and critical package lists before install.
- [ ] [CHK-PKG-03] Use Row 11 Flatpak reinstall script for Flatpak app state, then restore user data through Borg.
- [ ] [CHK-PKG-04] Use Row 12 pipx reinstall input/script for pipx CLIs.
- [ ] [CHK-PKG-05] Do not use package manager commands generated from stale manifests without reviewing OS version and
  repository compatibility.

## Desktop restore

- [ ] [CHK-DESK-01] Confirm logged-in Cinnamon/X11 session before user desktop restore.
- [ ] [CHK-DESK-02] Use Row 13 preview before any dconf load.
- [ ] [CHK-DESK-03] Confirm live monitor layout; do not blindly apply stale XRandR commands.
- [ ] [CHK-DESK-04] Restore Cinnamon files and autostarts through previewed paths only.
- [ ] [CHK-DESK-05] Do not re-enable old audio keepalive behavior without fresh diagnostics.

## Docker PostgreSQL and Portainer restore

- [ ] [CHK-DOCKER-01] Restore Docker Engine install state through Row 10 before Row 14 workload reconstruction.
- [ ] [CHK-DOCKER-02] Restore Compose source trees and bind-mount payloads through Borg/rsync before
  `docker compose up`.
- [ ] [CHK-DOCKER-03] Use Row 14 generated Compose restore plan. Do not start every stack at once.
- [ ] [CHK-PG-01] Restore PostgreSQL through Row 16 logical dumps, not raw Docker volume as primary authority.
- [ ] [CHK-PG-02] Require `pg_restore --list` proof before any DB restore.
- [ ] [CHK-PG-03] Run Row 16 disposable restore and smoke checks before declaring DB recoverable.
- [ ] [CHK-PORTAINER-01] Restore Portainer only after Docker is healthy.
- [ ] [CHK-PORTAINER-02] Use pinned Portainer restore image. `latest` is observed runtime state only. Stop
  on [STOP-PORTAINER-LATEST].
- [ ] [CHK-PORTAINER-03] Restore or recreate `portainer_data` according to Row 15, with quiescence and guards.

## Future Windows VM restore

- [ ] [CHK-VM-01] Confirm whether a Windows VM exists. Empty domain inventory is valid before any VM is created.
- [ ] [CHK-VM-02] Use Row 17 domain XML, disk path, NVRAM, swtpm, network, pool, and qemu-img facts.
- [ ] [CHK-VM-03] Confirm VM is shut off before any Row 5 cold-copy transport. Stop on [STOP-LIVE-VM-DISK].
- [ ] [CHK-VM-04] Restore NVRAM and swtpm state with matching domain UUID/name relationship before first boot.
- [ ] [CHK-VM-05] Confirm BitLocker recovery key availability before firmware/TPM/Secure Boot-sensitive boot. Stop
  on [STOP-BITLOCKER-UNKNOWN].
- [ ] [CHK-VM-06] Use Row 17 smoke checklist. Do not treat in-guest Windows files as backed up by Row 17.

## Validation checklist

### Pre-restore authority checks

- [ ] [CHK-AUTH-01] Confirm this file is the active restore runbook.
- [ ] [CHK-AUTH-02] Confirm `KNOWN_HOST_WARNINGS.md` has been read.
- [ ] [CHK-AUTH-03] Confirm no old placeholder runbook is being used. Stop on [STOP-PLACEHOLDER-RUNBOOK].
- [ ] [CHK-AUTH-04] Confirm the active failure layer and owning row.

### Media and vault checks

- [ ] [CHK-MEDIA-01] Confirm SMART/NVMe health gates.
- [ ] [CHK-MEDIA-02] Confirm source disk, target disk, backup HDD, and Rescuezilla USB identities.
- [ ] [CHK-MEDIA-03] Confirm LUKS vault UUID/mapper/header backup.

### Bare-metal image checks

- [ ] [CHK-IMAGE-01] Confirm Rescuezilla image identity and manifest.
- [ ] [CHK-IMAGE-02] Confirm target-size gate.
- [ ] [CHK-IMAGE-03] Confirm EFI/root relationship.

### Filesystem delta checks

- [ ] [CHK-FS-01] Confirm Borg key export and repository check.
- [ ] [CHK-FS-02] Confirm restore preview.
- [ ] [CHK-FS-03] Confirm path ownership before overwrite.

### Database checks

- [ ] [CHK-DB-01] Confirm globals dump.
- [ ] [CHK-DB-02] Confirm custom-format database dump.
- [ ] [CHK-DB-03] Confirm `pg_restore --list`.
- [ ] [CHK-DB-04] Confirm disposable restore smoke and row-count sanity.

### Docker and Portainer checks

- [ ] [CHK-DKR-01] Confirm Compose sources and environment references.
- [ ] [CHK-DKR-02] Confirm Docker secrets are recreated manually and not recovered from redacted manifests.
- [ ] [CHK-DKR-03] Confirm Portainer pinned image and `portainer_data`.

### Desktop checks

- [ ] [CHK-UI-01] Confirm dconf backup before guarded load.
- [ ] [CHK-UI-02] Confirm live XRandR review.
- [ ] [CHK-UI-03] Confirm Cinnamon session path.

### VM checks

- [ ] [CHK-LIBVIRT-01] Confirm `qemu:///system`.
- [ ] [CHK-LIBVIRT-02] Confirm domain XML/NVRAM/swtpm/disk facts.
- [ ] [CHK-LIBVIRT-03] Confirm no live disk copy.

### Final validation checks

- [ ] [CHK-FINAL-01] Confirm machine boots normally.
- [ ] [CHK-FINAL-02] Confirm user login, desktop, audio, network, Docker, PostgreSQL, Portainer, local_llm, and
  local_llm_router.
- [ ] [CHK-FINAL-03] Confirm Row 09 logs show no unresolved storage/restore failures.
- [ ] [CHK-FINAL-04] Generate Row 18 proof bundle index.
- [ ] [CHK-FINAL-05] Create a fresh post-recovery backup.

## Known-host warnings

Always read `runbooks/KNOWN_HOST_WARNINGS.md` before destructive action. It records host-specific identity, desktop,
Docker, PostgreSQL, Portainer, VM, audio, and old-runbook warnings that are not fully expressed by generic row logic.

## Stop conditions

Stop means stop the current operation, preserve evidence, and return to the owning row before continuing.

- [STOP-WRONG-DISK] Any destructive operation targets an unexpected disk, partition, UUID, by-id path, mapper, or
  filesystem.
- [STOP-ROOT-DISK] A command would wipe, repartition, format, or LUKS-format the active root disk outside an approved
  bare-metal restore flow.
- [STOP-UNKNOWN-VAULT] The encrypted backup vault identity, UUID, header, mapper, or expected label cannot be proven.
- [STOP-FAILED-SMART] SMART/NVMe health gates fail or are unavailable for a disk required for backup or restore.
- [STOP-MISSING-DUMP] PostgreSQL logical dump artifacts are missing when database recovery is required.
- [STOP-UNVERIFIED-DUMP] `pg_restore --list` or disposable restore verification fails.
- [STOP-LIVE-VM-DISK] A VM disk is in use by a running, paused, suspended, blocked, crashed, or shutting-down domain.
- [STOP-PORTAINER-LATEST] Portainer restore plan tries to use `latest`, `lts`, or unversioned image as restore
  authority.
- [STOP-SECRET-EXPOSURE] Any manifest, command, or runbook asks to store or print secret values unnecessarily.
- [STOP-UNMOUNTED-VAULT] A real-vault backup, restore, hash, or prune operation would run while the expected vault is
  not mounted/open.
- [STOP-UNCLEAR-AUTHORITY] Two files, scripts, paths, services, schemas, or runbooks appear to own the same
  responsibility.
- [STOP-BITLOCKER-UNKNOWN] A Windows VM restore or first boot is about to occur without known BitLocker recovery
  material.
- [STOP-PLACEHOLDER-RUNBOOK] A placeholder or retired runbook is being used as active restore authority.

## Proof bundle
Evidence set to indicate and verify what was captured/checked/restored/validated

Minimum proof bundle contents:
- Row 01 media-health gates.
- Row 02 image manifests.
- Row 03 vault/header evidence.
- Row 04 integrity manifests.
- Row 05 staging/copy logs.
- Row 06 Borg repository/archive/check evidence.
- Row 07 borgmatic dry-run/backup/check logs.
- Row 08 systemd unit/timer state.
- Row 09 journal evidence.
- Rows 10-12 reinstall manifests.
- Row 13 desktop previews and captures.
- Row 14 Docker/Compose manifests.
- Row 15 Portainer manifests.
- Row 16 PostgreSQL dump manifest, restore list, disposable restore smoke, row counts.
- Row 17 libvirt/QEMU/swtpm manifests when a VM exists.
- Row 18 runbook completeness report, proof index, checklist validation, stop-condition validation.

## Post-recovery backup requirement
After any material restore, perform a new backup cycle
Post-recovery backup verifies that the restored system is in known-good state