# wvmr/lib/common.sh

if [[ "${WVMR_COMMON_SH_LOADED:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi
WVMR_COMMON_SH_LOADED=1

wvmr_common_root() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P
}

if ! WVMR_COMMON_ROOT="$(wvmr_common_root)"; then
  printf 'ERROR: failed to resolve WVMR root\n' >&2
  exit 1
fi

: "${WVMR_ENV_FILE:=${WVMR_COMMON_ROOT}/wvmr.env}"

# Output
wvmr_section() {
  printf '\n===== %s =====\n' "$*"
}

wvmr_kv() {
  printf '%-28s %s\n' "$1:" "${2:-}"
}

wvmr_ok() {
  printf 'OK   %s\n' "$*"
}

wvmr_warn() {
  printf 'WARN %s\n' "$*" >&2
}

wvmr_fail() {
  printf 'FAIL %s\n' "$*" >&2
  return 1
}

wvmr_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Env
wvmr_require_env() {
  local name

  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      wvmr_die "missing env value: ${name}"
    fi
  done
}

wvmr_assert_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    wvmr_die "${name} must be an integer: ${value}"
  fi
}

wvmr_assert_disk_size() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+[KMGTP]?$ ]]; then
    wvmr_die "${name} must look like 240G, 500G, or 1024M: ${value}"
  fi
}

wvmr_assert_safe_name() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    wvmr_die "${name} contains unsupported characters: ${value}"
  fi
}

wvmr_load_env() {
  if [[ "${WVMR_ENV_LOADED:-0}" == "1" ]]; then
    return 0
  fi

  if [[ ! -f "$WVMR_ENV_FILE" ]]; then
    wvmr_die "missing env file: ${WVMR_ENV_FILE}"
  fi

  # shellcheck disable=SC1090
  source "$WVMR_ENV_FILE"

  wvmr_require_env \
    VM_NAME \
    LIBVIRT_URI \
    NETWORK_NAME \
    ISO_DIR \
    VM_IMAGE_DIR \
    WIN11_ISO \
    VIRTIO_WIN_ISO \
    DISK_FORMAT \
    OS_DISK \
    VM_MEMORY_MIB \
    VM_VCPUS \
    OS_DISK_SIZE \
    VIEWER \
    VIEWER_WAIT_SECONDS \
    WVMR_ROOT \
    STATE_DIR \
    DIAGNOSTICS_DIR \
    CAPTURED_VM_XML \
    RECOVERY_MANIFEST

  if [[ "$WVMR_ROOT" != "$WVMR_COMMON_ROOT" ]]; then
    wvmr_die "WVMR_ROOT mismatch: env=${WVMR_ROOT} actual=${WVMR_COMMON_ROOT}"
  fi

  wvmr_assert_safe_name "VM_NAME" "$VM_NAME"
  wvmr_assert_safe_name "NETWORK_NAME" "$NETWORK_NAME"
  wvmr_assert_integer "VM_MEMORY_MIB" "$VM_MEMORY_MIB"
  wvmr_assert_integer "VM_VCPUS" "$VM_VCPUS"
  wvmr_assert_integer "VIEWER_WAIT_SECONDS" "$VIEWER_WAIT_SECONDS"
  wvmr_assert_disk_size "OS_DISK_SIZE" "$OS_DISK_SIZE"

  if [[ "$DISK_FORMAT" != "qcow2" ]]; then
    wvmr_die "unsupported DISK_FORMAT for baseline: ${DISK_FORMAT}"
  fi

  WVMR_ENV_LOADED=1
}

# Checks
wvmr_require_normal_user() {
  if [[ "${EUID}" -eq 0 ]]; then
    wvmr_die "run as normal user, not root"
  fi
}

wvmr_cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

wvmr_require_cmd() {
  local cmd="$1"

  if ! wvmr_cmd_exists "$cmd"; then
    wvmr_die "missing command: ${cmd}"
  fi
}

wvmr_require_cmds() {
  local cmd

  for cmd in "$@"; do
    wvmr_require_cmd "$cmd"
  done
}

wvmr_path_kind() {
  local path="$1"

  if [[ -d "$path" ]]; then
    printf 'directory'
  elif [[ -f "$path" ]]; then
    printf 'file'
  elif [[ -e "$path" ]]; then
    printf 'other'
  else
    printf 'missing'
  fi
}

wvmr_yes_no() {
  if "$@" >/dev/null 2>&1; then
    printf 'yes'
  else
    printf 'no'
  fi
}