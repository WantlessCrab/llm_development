# wvmr/lib/libvirt.sh

if [[ "${WVMR_LIBVIRT_SH_LOADED:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi
WVMR_LIBVIRT_SH_LOADED=1

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)/common.sh"

wvmr_virsh() {
  wvmr_load_env
  virsh -c "$LIBVIRT_URI" "$@"
}

wvmr_vm_exists() {
  wvmr_load_env
  wvmr_virsh dominfo "$VM_NAME" >/dev/null 2>&1
}

wvmr_vm_state() {
  wvmr_load_env
  wvmr_require_cmds virsh sed

  if ! wvmr_vm_exists; then
    printf 'not-defined\n'
    return 0
  fi

  wvmr_virsh domstate "$VM_NAME" 2>/dev/null | sed -n '1p'
}

wvmr_vm_require_defined() {
  if ! wvmr_vm_exists; then
    wvmr_die "VM domain not defined: ${VM_NAME}"
  fi
}

wvmr_vm_wait_for_state() {
  local target_state="$1"
  local wait_seconds="$2"
  local start_ts
  local now_ts
  local state

  wvmr_require_cmds date sleep

  start_ts="$(date +%s)"

  while true; do
    state="$(wvmr_vm_state 2>/dev/null || printf 'unknown')"
    if [[ "$state" == "$target_state" ]]; then
      return 0
    fi

    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= wait_seconds )); then
      return 1
    fi

    sleep 1
  done
}

wvmr_vm_status() {
  local state

  wvmr_require_normal_user
  wvmr_load_env
  wvmr_require_cmd virsh

  wvmr_section "WVMR status"
  wvmr_kv "root" "$WVMR_ROOT"
  wvmr_kv "vm" "$VM_NAME"
  wvmr_kv "libvirt" "$LIBVIRT_URI"

  state="$(wvmr_vm_state)"
  wvmr_kv "state" "$state"

  if [[ "$state" == "not-defined" ]]; then
    printf 'VM domain has not been created yet.\n'
    return 0
  fi

  wvmr_section "Domain"
  wvmr_virsh dominfo "$VM_NAME"

  wvmr_section "Display"
  wvmr_virsh domdisplay "$VM_NAME" 2>/dev/null || true

  wvmr_section "Disks"
  wvmr_virsh domblklist "$VM_NAME" --details 2>/dev/null || true

  wvmr_section "Network interfaces"
  wvmr_virsh domiflist "$VM_NAME" 2>/dev/null || true

  wvmr_section "Snapshots"
  wvmr_virsh snapshot-list "$VM_NAME" 2>/dev/null || true
}

wvmr_vm_start() {
  local state

  wvmr_require_normal_user
  wvmr_load_env
  wvmr_require_cmd virsh
  wvmr_vm_require_defined

  state="$(wvmr_vm_state)"

  case "$state" in
    running)
      wvmr_ok "VM already running: ${VM_NAME}"
      return 0
      ;;
    "shut off")
      ;;
    *)
      wvmr_die "VM state is not start-safe: ${state}"
      ;;
  esac

  wvmr_virsh start "$VM_NAME"

  if wvmr_vm_wait_for_state "running" 30; then
    wvmr_ok "VM running: ${VM_NAME}"
  else
    wvmr_warn "VM start issued, but running state was not confirmed within 30 seconds"
    return 1
  fi
}

wvmr_vm_stop() {
  local state

  wvmr_require_normal_user
  wvmr_load_env
  wvmr_require_cmd virsh
  wvmr_vm_require_defined

  state="$(wvmr_vm_state)"

  case "$state" in
    "shut off")
      wvmr_ok "VM already stopped: ${VM_NAME}"
      return 0
      ;;
    running)
      ;;
    *)
      wvmr_die "VM state is not shutdown-safe through this wrapper: ${state}"
      ;;
  esac

  wvmr_virsh shutdown "$VM_NAME"

  if wvmr_vm_wait_for_state "shut off" 60; then
    wvmr_ok "VM stopped: ${VM_NAME}"
  else
    wvmr_warn "shutdown requested, but VM did not stop within 60 seconds"
    return 1
  fi
}

wvmr_vm_restart() {
  wvmr_vm_stop
  wvmr_vm_start
}

wvmr_vm_view() {
  local state

  wvmr_require_normal_user
  wvmr_load_env
  wvmr_require_cmd "$VIEWER"
  wvmr_vm_require_defined

  state="$(wvmr_vm_state)"
  if [[ "$state" != "running" ]]; then
    wvmr_die "VM is not running: ${VM_NAME}"
  fi

  "$VIEWER" --connect "$LIBVIRT_URI" "$VM_NAME"
}

wvmr_vm_capture_metadata() {
  local tmp_xml
  local tmp_manifest

  wvmr_require_normal_user
  wvmr_load_env
  wvmr_require_cmds virsh python3 mktemp mkdir mv rm
  wvmr_vm_require_defined

  mkdir -p "$STATE_DIR"

  tmp_xml="$(mktemp "${CAPTURED_VM_XML}.tmp.XXXXXX")"
  tmp_manifest="$(mktemp "${RECOVERY_MANIFEST}.tmp.XXXXXX")"

  if ! wvmr_virsh dumpxml "$VM_NAME" >"$tmp_xml"; then
    rm -f "$tmp_xml" "$tmp_manifest"
    wvmr_die "failed to capture VM XML"
  fi

    if ! python3 - "$tmp_xml" "$tmp_manifest" "$LIBVIRT_URI" "$VM_NAME" "$CAPTURED_VM_XML" <<'PY'
import datetime as _dt
import json
import os
import sys
import xml.etree.ElementTree as ET

xml_path, manifest_path, libvirt_uri, expected_name, final_xml_path = sys.argv[1:6]
root = ET.parse(xml_path).getroot()


def text(path: str) -> str:
    node = root.find(path)
    if node is None or node.text is None:
        return ""
    return node.text.strip()


def attrs(node):
    return dict(node.attrib) if node is not None else {}


name = text("name")
uuid = text("uuid")

disks = []
for disk in root.findall("./devices/disk"):
    source = disk.find("source")
    target = disk.find("target")
    driver = disk.find("driver")
    disks.append(
        {
            "device": disk.get("device", ""),
            "type": disk.get("type", ""),
            "driver": attrs(driver),
            "source": attrs(source),
            "target": attrs(target),
        }
    )

interfaces = []
for interface in root.findall("./devices/interface"):
    source = interface.find("source")
    model = interface.find("model")
    mac = interface.find("mac")
    interfaces.append(
        {
            "type": interface.get("type", ""),
            "source": attrs(source),
            "model": attrs(model),
            "mac": attrs(mac),
        }
    )

graphics = []
for item in root.findall("./devices/graphics"):
    graphics.append(attrs(item))

videos = []
for video in root.findall("./devices/video"):
    model = video.find("model")
    videos.append({"model": attrs(model)})

tpms = []
for tpm in root.findall("./devices/tpm"):
    backend = tpm.find("backend")
    model = tpm.find("model")
    tpms.append(
        {
            "model": attrs(model),
            "backend": attrs(backend),
            "version": backend.get("version", "") if backend is not None else "",
        }
    )

hostdevs = []
for hostdev in root.findall("./devices/hostdev"):
    source = hostdev.find("source")
    hostdevs.append(
        {
            "mode": hostdev.get("mode", ""),
            "type": hostdev.get("type", ""),
            "managed": hostdev.get("managed", ""),
            "source": ET.tostring(source, encoding="unicode") if source is not None else "",
        }
    )

manifest = {
    "schema_version": "wvmr.recovery_manifest.v1",
    "captured_at": _dt.datetime.now(_dt.UTC).isoformat(),
    "libvirt_uri": libvirt_uri,
    "expected_name": expected_name,
    "name": name,
    "uuid": uuid,
    "paths": {
        "captured_xml": os.path.abspath(final_xml_path),
    },
    "firmware": {
        "loader": text("./os/loader"),
        "loader_attrs": attrs(root.find("./os/loader")),
        "nvram": text("./os/nvram"),
    },
    "memory": {
        "memory": text("memory"),
        "current_memory": text("currentMemory"),
        "vcpu": text("vcpu"),
    },
    "devices": {
        "disks": disks,
        "interfaces": interfaces,
        "graphics": graphics,
        "videos": videos,
        "tpms": tpms,
        "hostdevs": hostdevs,
    },
    "recovery_rules": {
        "disk_payload_copy_requires_stopped_vm": True,
        "raw_host_disk_passthrough_expected": False,
        "shared_folder_expected": False,
        "backup_hdd_passthrough_expected": False,
        "docker_socket_exposure_expected": False,
    },
}

with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
  then
    rm -f "$tmp_xml" "$tmp_manifest"
    wvmr_die "failed to write recovery manifest"
  fi

  mv -f "$tmp_xml" "$CAPTURED_VM_XML"
  mv -f "$tmp_manifest" "$RECOVERY_MANIFEST"

  wvmr_ok "captured VM XML: ${CAPTURED_VM_XML}"
  wvmr_ok "captured recovery manifest: ${RECOVERY_MANIFEST}"
}