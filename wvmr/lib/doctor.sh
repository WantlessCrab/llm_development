# wvmr/lib/doctor.sh

if [[ "${WVMR_DOCTOR_SH_LOADED:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi
WVMR_DOCTOR_SH_LOADED=1

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"

wvmr_doctor_reset() {
  WVMR_DOCTOR_FAILS=0
  WVMR_DOCTOR_WARNS=0
  WVMR_DOCTOR_NEEDS=0
}

wvmr_doctor_ok() {
  printf 'OK   %s\n' "$*"
}

wvmr_doctor_warn() {
  WVMR_DOCTOR_WARNS=$((WVMR_DOCTOR_WARNS + 1))
  printf 'WARN %s\n' "$*"
}

wvmr_doctor_need() {
  WVMR_DOCTOR_NEEDS=$((WVMR_DOCTOR_NEEDS + 1))
  printf 'NEED %s\n' "$*"
}

wvmr_doctor_fail() {
  WVMR_DOCTOR_FAILS=$((WVMR_DOCTOR_FAILS + 1))
  printf 'FAIL %s\n' "$*"
}

wvmr_doctor_cmd() {
  local cmd="$1"

  if wvmr_cmd_exists "$cmd"; then
    wvmr_doctor_ok "command ${cmd}: $(command -v "$cmd")"
  else
    wvmr_doctor_fail "missing command: ${cmd}"
  fi
}

wvmr_doctor_optional_cmd() {
  local cmd="$1"

  if wvmr_cmd_exists "$cmd"; then
    wvmr_doctor_ok "optional command ${cmd}: $(command -v "$cmd")"
  else
    wvmr_doctor_warn "optional command missing: ${cmd}"
  fi
}

wvmr_doctor_first_line() {
  local value

  value="$("$@" 2>/dev/null | sed -n '1p' || true)"

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf 'unknown'
  fi
}

wvmr_doctor_file() {
  local label="$1"
  local path="$2"
  local missing_status="${3:-need}"

  case "$(wvmr_path_kind "$path")" in
    file)
      wvmr_doctor_ok "${label}: ${path}"
      ;;
    missing)
      if [[ "$missing_status" == "fail" ]]; then
        wvmr_doctor_fail "${label} missing: ${path}"
      else
        wvmr_doctor_need "${label} missing: ${path}"
      fi
      ;;
    *)
      wvmr_doctor_fail "${label} is not a file: ${path}"
      ;;
  esac
}

wvmr_doctor_dir() {
  local label="$1"
  local path="$2"
  local missing_status="${3:-need}"

  case "$(wvmr_path_kind "$path")" in
    directory)
      wvmr_doctor_ok "${label}: ${path}"
      ;;
    missing)
      if [[ "$missing_status" == "fail" ]]; then
        wvmr_doctor_fail "${label} missing: ${path}"
      else
        wvmr_doctor_need "${label} missing: ${path}"
      fi
      ;;
    *)
      wvmr_doctor_fail "${label} is not a directory: ${path}"
      ;;
  esac
}

wvmr_doctor_xml_absent() {
  local xml="$1"
  local label="$2"
  local pattern="$3"

  if printf '%s\n' "$xml" | grep -Eq "$pattern"; then
    wvmr_doctor_fail "${label}"
  else
    wvmr_doctor_ok "${label}"
  fi
}

wvmr_doctor_user() {
  wvmr_section "User"

  if [[ "${EUID}" -eq 0 ]]; then
    wvmr_doctor_fail "running as root; use normal user"
  else
    wvmr_doctor_ok "running as user: $(id -un)"
  fi

  if id -nG | tr ' ' '\n' | grep -qx 'libvirt'; then
    wvmr_doctor_ok "user is in libvirt group"
  else
    wvmr_doctor_fail "user is not in libvirt group"
  fi

  if [[ -e /dev/kvm ]]; then
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
      wvmr_doctor_ok "/dev/kvm is accessible"
    else
      wvmr_doctor_fail "/dev/kvm exists but is not accessible"
    fi
  else
    wvmr_doctor_fail "/dev/kvm missing"
  fi
}

wvmr_doctor_commands() {
  local cmd

  wvmr_section "Commands"

  for cmd in \
    virsh \
    virt-manager \
    virt-viewer \
    virt-install \
    qemu-img \
    qemu-system-x86_64 \
    swtpm \
    swtpm_setup \
    df \
    find \
    grep \
    sed \
    awk \
    ip \
    id \
    getent \
    lscpu \
    tr; do
    wvmr_doctor_cmd "$cmd"
  done

  wvmr_doctor_optional_cmd "virt-host-validate"
  wvmr_doctor_optional_cmd "osinfo-query"
}

wvmr_doctor_versions() {
  wvmr_section "Versions"

  wvmr_kv "virsh" "$(wvmr_doctor_first_line virsh --version)"
  wvmr_kv "qemu-img" "$(wvmr_doctor_first_line qemu-img --version)"
  wvmr_kv "qemu" "$(wvmr_doctor_first_line qemu-system-x86_64 --version)"
  wvmr_kv "virt-install" "$(wvmr_doctor_first_line virt-install --version)"
  wvmr_kv "virt-viewer" "$(wvmr_doctor_first_line virt-viewer --version)"
  wvmr_kv "swtpm" "$(wvmr_doctor_first_line swtpm --version)"
  wvmr_kv "swtpm_setup" "$(wvmr_doctor_first_line swtpm_setup --version)"
}

wvmr_doctor_kvm() {
  wvmr_section "KVM"

  if grep -Eq '^kvm\b' /proc/modules; then
    wvmr_doctor_ok "kvm module loaded"
  else
    wvmr_doctor_warn "kvm module not visible in /proc/modules"
  fi

  if grep -Eq '^kvm_intel\b' /proc/modules; then
    wvmr_doctor_ok "kvm_intel module loaded"
  else
    wvmr_doctor_warn "kvm_intel module not visible in /proc/modules"
  fi

  if lscpu | grep -Eq '^Virtualization:[[:space:]]+VT-x'; then
    wvmr_doctor_ok "CPU virtualization: VT-x"
  else
    wvmr_doctor_fail "CPU virtualization VT-x not reported by lscpu"
  fi
}

wvmr_doctor_libvirt() {
  local uri_out
  local net_info

  wvmr_section "Libvirt"

  if uri_out="$(virsh -c "$LIBVIRT_URI" uri 2>/dev/null)"; then
    if [[ "$uri_out" == "$LIBVIRT_URI" ]]; then
      wvmr_doctor_ok "libvirt URI: ${uri_out}"
    else
      wvmr_doctor_fail "libvirt URI mismatch: expected ${LIBVIRT_URI}, got ${uri_out}"
    fi
  else
    wvmr_doctor_fail "libvirt URI unavailable: ${LIBVIRT_URI}"
  fi

  if virsh -c "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
    wvmr_doctor_ok "VM domain exists: ${VM_NAME}"
  else
    wvmr_doctor_need "VM domain not defined yet: ${VM_NAME}"
  fi

  if net_info="$(virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" 2>/dev/null)"; then
    if printf '%s\n' "$net_info" | grep -Eq '^Active:[[:space:]]+yes'; then
      wvmr_doctor_ok "network active: ${NETWORK_NAME}"
    else
      wvmr_doctor_fail "network exists but is not active: ${NETWORK_NAME}"
    fi
  else
    wvmr_doctor_fail "network missing: ${NETWORK_NAME}"
  fi

  if ip -br addr show virbr0 >/dev/null 2>&1; then
    wvmr_doctor_ok "virbr0 present"
  else
    wvmr_doctor_warn "virbr0 not visible"
  fi
}

wvmr_doctor_storage() {
  wvmr_section "Storage"

  wvmr_doctor_dir "libvirt image root" "/var/lib/libvirt/images" "fail"
  wvmr_doctor_dir "libvirt boot root" "/var/lib/libvirt/boot" "fail"
  wvmr_doctor_dir "ISO directory" "$ISO_DIR" "need"
  wvmr_doctor_dir "VM image directory" "$VM_IMAGE_DIR" "need"

  wvmr_doctor_file "Windows ISO" "$WIN11_ISO" "need"
  wvmr_doctor_file "VirtIO Windows ISO" "$VIRTIO_WIN_ISO" "need"

  if [[ -e "$OS_DISK" ]]; then
    if [[ -f "$OS_DISK" ]]; then
      wvmr_doctor_ok "OS disk exists: ${OS_DISK}"
    else
      wvmr_doctor_fail "OS disk path exists but is not a file: ${OS_DISK}"
    fi
  else
    wvmr_doctor_need "OS disk not created yet: ${OS_DISK}"
  fi

  wvmr_kv "root filesystem" "$(df -hT / | sed -n '2p')"
}

wvmr_doctor_firmware_tpm() {
  wvmr_section "Firmware and TPM"

  if [[ -f /usr/share/OVMF/OVMF_CODE_4M.fd && -f /usr/share/OVMF/OVMF_VARS_4M.fd ]]; then
    wvmr_doctor_ok "OVMF 4M code/vars present"
  else
    wvmr_doctor_fail "OVMF 4M code/vars missing"
  fi

  if [[ -f /usr/share/OVMF/OVMF_CODE_4M.secboot.fd ]]; then
    wvmr_doctor_ok "OVMF Secure Boot code candidate present"
  else
    wvmr_doctor_warn "OVMF Secure Boot code candidate missing"
  fi

  if [[ -d /var/lib/libvirt/qemu/nvram || -d /etc/libvirt/qemu/nvram ]]; then
    wvmr_doctor_ok "NVRAM root exists"
  else
    wvmr_doctor_need "NVRAM root not created yet"
  fi

  if [[ -d /var/lib/libvirt/swtpm || -d /var/lib/swtpm ]]; then
    wvmr_doctor_ok "swtpm state root exists"
  else
    wvmr_doctor_need "swtpm state root not created yet"
  fi
}

wvmr_doctor_isolation() {
  local xml

  wvmr_section "Isolation baseline"

  if ! virsh -c "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
    wvmr_doctor_need "VM XML not available until domain is defined"
    wvmr_doctor_ok "source config has no shared-folder, raw-disk, Docker, backup-HDD, or DDJ passthrough fields populated"
    return 0
  fi

  if ! xml="$(virsh -c "$LIBVIRT_URI" dumpxml "$VM_NAME" 2>/dev/null)"; then
    wvmr_doctor_fail "failed to read VM XML for isolation checks"
    return 0
  fi

  wvmr_doctor_xml_absent "$xml" \
    "no shared-folder filesystem passthrough in VM XML" \
    '<filesystem[[:space:]>]'

  wvmr_doctor_xml_absent "$xml" \
    "no raw block disk passthrough in VM XML" \
    "<disk[[:space:]][^>]*type=['\"]block['\"]|<source[[:space:]][^>]*dev=['\"]/dev/"

  wvmr_doctor_xml_absent "$xml" \
    "no backup vault/HDD path exposure in VM XML" \
    '/mnt/wantless_recovery|wantless_recovery|backup_hdd_ironwolf|wwn-0x5000c500fd981379'

  wvmr_doctor_xml_absent "$xml" \
    "no Docker socket/storage exposure in VM XML" \
    '/var/run/docker\.sock|/var/lib/docker'

  wvmr_doctor_xml_absent "$xml" \
    "no host project/home share exposure in VM XML" \
    '/home/wantless/PycharmProjects|/home/wantless'

  if printf '%s\n' "$xml" | grep -Eq '<hostdev[[:space:]>]'; then
    if [[ -n "${DDJ_USB_VENDOR_ID}${DDJ_USB_PRODUCT_ID}${DDJ_USB_PORT_PATH}" ]]; then
      wvmr_doctor_warn "hostdev passthrough exists; verify it is the intended DDJ device"
    else
      wvmr_doctor_fail "unexpected hostdev passthrough before DDJ phase"
    fi
  else
    wvmr_doctor_ok "no hostdev passthrough before DDJ phase"
  fi
}

wvmr_doctor_optional_host_validate() {
  wvmr_section "Host validator"

  if wvmr_cmd_exists virt-host-validate; then
    virt-host-validate qemu 2>&1 || true
  else
    wvmr_doctor_warn "virt-host-validate unavailable"
  fi
}

wvmr_doctor_summary() {
  wvmr_section "Summary"
  wvmr_kv "failures" "$WVMR_DOCTOR_FAILS"
  wvmr_kv "warnings" "$WVMR_DOCTOR_WARNS"
  wvmr_kv "needs" "$WVMR_DOCTOR_NEEDS"
  printf 'No files created. No settings changed.\n'

  if [[ "$WVMR_DOCTOR_FAILS" -gt 0 ]]; then
    return 1
  fi

  return 0
}

wvmr_doctor() {
  wvmr_doctor_reset
  wvmr_require_normal_user
  wvmr_load_env

  wvmr_section "WVMR doctor"
  wvmr_kv "root" "$WVMR_ROOT"
  wvmr_kv "env" "$WVMR_ENV_FILE"
  wvmr_kv "vm" "$VM_NAME"
  wvmr_kv "libvirt" "$LIBVIRT_URI"

  wvmr_doctor_user
  wvmr_doctor_commands
  wvmr_doctor_versions
  wvmr_doctor_kvm
  wvmr_doctor_libvirt
  wvmr_doctor_storage
  wvmr_doctor_firmware_tpm
  wvmr_doctor_isolation
  wvmr_doctor_optional_host_validate
  wvmr_doctor_summary
}