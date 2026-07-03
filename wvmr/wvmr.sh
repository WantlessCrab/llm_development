#!/usr/bin/env bash
# wvmr/wvmr.sh

set -euo pipefail

WVMR_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# shellcheck source=lib/common.sh
source "${WVMR_SCRIPT_DIR}/lib/common.sh"

# shellcheck source=lib/doctor.sh
source "${WVMR_SCRIPT_DIR}/lib/doctor.sh"

# shellcheck source=lib/libvirt.sh
source "${WVMR_SCRIPT_DIR}/lib/libvirt.sh"

wvmr_usage() {
  printf '%s\n' \
    'Usage:' \
    '  ./wvmr.sh doctor' \
    '  ./wvmr.sh status' \
    '  ./wvmr.sh start' \
    '  ./wvmr.sh stop' \
    '  ./wvmr.sh restart' \
    '  ./wvmr.sh view' \
    '  ./wvmr.sh capture-metadata' \
    '  ./wvmr.sh env' \
    '  ./wvmr.sh help' \
    '' \
    'Scope:' \
    '  doctor            read-only host/VM readiness checks' \
    '  status            read-only libvirt VM state' \
    '  start             start an existing libvirt domain' \
    '  stop              request clean Windows guest shutdown' \
    '  restart           stop then start the VM' \
    '  view              open running VM in virt-viewer' \
    '  capture-metadata  export VM XML and recovery manifest' \
    '  env               show resolved WVMR paths'
}

wvmr_no_args() {
  local command_name="$1"
  shift

  if [[ "$#" -ne 0 ]]; then
    wvmr_die "${command_name} does not accept arguments"
  fi
}

wvmr_print_env() {
  wvmr_require_normal_user
  wvmr_load_env

  wvmr_section "WVMR env"
  wvmr_kv "root" "$WVMR_ROOT"
  wvmr_kv "env file" "$WVMR_ENV_FILE"
  wvmr_kv "vm" "$VM_NAME"
  wvmr_kv "libvirt" "$LIBVIRT_URI"
  wvmr_kv "network" "$NETWORK_NAME"
  wvmr_kv "iso dir" "$ISO_DIR"
  wvmr_kv "win11 iso" "$WIN11_ISO"
  wvmr_kv "virtio iso" "$VIRTIO_WIN_ISO"
  wvmr_kv "image dir" "$VM_IMAGE_DIR"
  wvmr_kv "os disk" "$OS_DISK"
  wvmr_kv "disk format" "$DISK_FORMAT"
  wvmr_kv "memory MiB" "$VM_MEMORY_MIB"
  wvmr_kv "vcpus" "$VM_VCPUS"
  wvmr_kv "os disk size" "$OS_DISK_SIZE"
  wvmr_kv "viewer" "$VIEWER"
  wvmr_kv "state dir" "$STATE_DIR"
  wvmr_kv "vm xml capture" "$CAPTURED_VM_XML"
  wvmr_kv "recovery manifest" "$RECOVERY_MANIFEST"
}

wvmr_main() {
  local command_name="${1:-help}"
  shift || true

  case "$command_name" in
    doctor)
      wvmr_no_args "$command_name" "$@"
      wvmr_doctor
      ;;

    status)
      wvmr_no_args "$command_name" "$@"
      wvmr_vm_status
      ;;

    start)
      wvmr_no_args "$command_name" "$@"
      wvmr_vm_start
      ;;

    stop)
      wvmr_no_args "$command_name" "$@"
      wvmr_vm_stop
      ;;

    restart)
      wvmr_no_args "$command_name" "$@"
      wvmr_vm_restart
      ;;

    view)
      wvmr_no_args "$command_name" "$@"
      wvmr_vm_view
      ;;

    capture-metadata)
      wvmr_no_args "$command_name" "$@"
      wvmr_vm_capture_metadata
      ;;

    env)
      wvmr_no_args "$command_name" "$@"
      wvmr_print_env
      ;;

    help|-h|--help)
      wvmr_no_args "$command_name" "$@"
      wvmr_usage
      ;;

    *)
      wvmr_usage >&2
      wvmr_die "unknown command: ${command_name}"
      ;;
  esac
}

wvmr_main "$@"