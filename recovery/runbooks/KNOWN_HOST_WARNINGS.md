# KNOWN HOST WARNINGS

## Known host identity

This file records restore-critical warnings for the current host. It is not a complete hardware inventory; lower rows
own exact hardware, disk, package, and runtime facts.

Known host identity:

```text
hostname: wantless-Z890-GAMING-X-WIFI7
user: wantless
OS family: Linux Mint 22.3 / Ubuntu noble lineage
desktop: Cinnamon on X11
boot mode: UEFI
system board: Gigabyte Z890 GAMING X WIFI7
CPU: Intel Core Ultra 9 285K
GPU of record for ROCm workloads: AMD Radeon RX 7900 XTX / Navi 31
```

## Destructive operation warnings

- [STOP-WRONG-DISK] Never run format, wipefs, parted, mkfs, cryptsetup luksFormat, Rescuezilla restore, or destructive
  rsync without proving the active target by stable identity.
- [STOP-ROOT-DISK] Never test destructive disk operations against the active root disk.
- Use by-id/by-uuid paths when a row supports them.
- A new copy of an old file can have a new modified time. Do not infer authority from timestamp alone.
- If two files appear to own the same restore decision, stop on [STOP-UNCLEAR-AUTHORITY].

## Storage and disk warnings

- Row 01 owns physical media health admissibility.
- Row 03 owns encrypted vault identity and wrong-disk prevention.
- Row 04 owns hash verification after artifacts exist.
- The backup HDD is not touched until local dry-run proof is complete unless a row inherently requires external media.
- LUKS header backups are critical recovery artifacts and must be verified before treating a vault as recoverable.

## Desktop session warnings

- Cinnamon/dconf/user-session restore requires the logged-in user session, not root-only context.
- Do not blindly apply historical XRandR commands. Monitor geometry has changed during this project; live Row 13 capture
  is authoritative for current layout.
- Do not re-enable old audio keepalive behavior without fresh diagnostics. Prior keepalive behavior caused random audio
  dropouts.
- Default audio preferences and PipeWire/WirePlumber state are not the same thing; Row 13 captures desktop-facing
  preferences, not full audio authority.

## Docker and PostgreSQL warnings

- Docker/Compose workload reconstruction belongs to Row 14.
- PostgreSQL logical recovery belongs to Row 16.
- Raw Docker volume backup is not the primary authority for PostgreSQL recovery.
- `llm_database` must be recovered from logical dumps, `pg_restore --list`, disposable restore smoke, and row-count
  sanity.
- Secret values must not be persisted into manifests. Environment variable names and secret references are acceptable;
  secret values are not.

## Portainer warning

- Active Portainer image may be observed as `portainer/portainer-ce:latest`.
- `latest` is not restore authority.
- Restore must use the pinned staged Portainer image identity approved by Row 15.
- Stop on [STOP-PORTAINER-LATEST] if a restore plan tries to use `latest`, `lts`, or an unversioned image as the
  authority.

## Future VM and BitLocker warning

- Row 17 is future-VM-ready. Empty current domain inventory is valid if no Windows VM has been created.
- VM disk byte transport belongs to Row 05 rsync after Row 17 proves no live disk use.
- Host-side VM metadata belongs to Row 17.
- In-guest Windows backup is outside Row 17.
- BitLocker, TPM, Secure Boot, firmware variables, machine type, disk identity, boot order, NVRAM, and swtpm state can
  interact. Stop on [STOP-BITLOCKER-UNKNOWN] if recovery key availability is unknown before first boot.

## Audio input display warning

- Desktop display state has previously included multiple monitors and X11 framebuffers with drift between captures.
- Treat Row 13 live capture as authoritative at restore time.
- Treat audio routing, speaker/headset changes, and keepalive state as active-state sensitive. Do not restore old
  experiments as defaults.

## Old runbook authority warning

- [STOP-PLACEHOLDER-RUNBOOK] Old `00`-through-`70` placeholder runbooks are not active restore authority.
- Canonical active runbooks are:
    - `runbooks/RESTORE_FIRST.md`
    - `runbooks/KNOWN_HOST_WARNINGS.md`
- Generated indexes are navigation aids, not higher authority than the two canonical runbooks.