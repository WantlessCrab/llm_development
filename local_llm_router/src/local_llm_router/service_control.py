from __future__ import annotations

import json
import shutil
import subprocess
import urllib.request
from dataclasses import asdict, dataclass, field
from typing import Any, Literal

from .config import LocalServicesConfig, LocalServiceTargetConfig

ServiceAction = Literal["status", "start", "stop", "restart"]


@dataclass(frozen=True)
class ManagedLocalService:
    service_id: str
    label: str
    authority: str
    supervisor_name: str
    code_svc_command: str
    health_url: str
    managed: bool = True

    @classmethod
    def from_config(cls, service_id: str,
                    config: LocalServiceTargetConfig) -> "ManagedLocalService":
        return cls(
            service_id=service_id,
            label=config.label,
            authority=config.authority,
            supervisor_name=config.supervisor_name,
            code_svc_command=config.code_svc_command,
            health_url=config.health_url,
            managed=config.managed,
        )


DEFAULT_SERVICES: dict[str, ManagedLocalService] = {
    "local_llm": ManagedLocalService(
        service_id="local_llm",
        label="local_llm backend",
        authority="supervisor",
        supervisor_name="code-host:local-llm",
        code_svc_command="code-svc",
        health_url="http://127.0.0.1:8020/health",
    ),
    "local_llm_router": ManagedLocalService(
        service_id="local_llm_router",
        label="local_llm_router daemon",
        authority="supervisor",
        supervisor_name="code-host:local-llm-router",
        code_svc_command="code-svc",
        health_url="http://127.0.0.1:8015/health",
    ),
}


@dataclass
class LocalServiceStatus:
    service_id: str
    label: str
    authority: str
    supervisor_name: str
    code_svc_command: str
    supervisor_available: bool
    code_svc_path: str | None
    supervisor_state: str | None
    supervisor_ok: bool
    health_url: str
    health_ok: bool
    health_status: str | None = None
    health_error: str | None = None
    managed: bool = True
    details: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class LocalServiceActionResult:
    ok: bool
    action: str
    service_id: str | None
    message: str
    statuses: list[LocalServiceStatus] = field(default_factory=list)
    command_results: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "action": self.action,
            "service_id": self.service_id,
            "message": self.message,
            "statuses": [item.to_dict() for item in self.statuses],
            "command_results": self.command_results,
        }


def _run(args: list[str], *, timeout: float = 15.0) -> dict[str, Any]:
    try:
        completed = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                                   check=False)
        return {
            "args": args,
            "returncode": completed.returncode,
            "stdout": completed.stdout.strip(),
            "stderr": completed.stderr.strip(),
            "ok": completed.returncode == 0,
        }
    except Exception as exc:
        return {"args": args, "returncode": None, "stdout": "", "stderr": str(exc), "ok": False}


def _check_health(url: str, timeout: float = 3.0) -> tuple[bool, str | None, str | None]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            raw = response.read(4096).decode("utf-8", errors="replace")
        try:
            body = json.loads(raw)
            return True, str(body.get("status", "ok")), None
        except json.JSONDecodeError:
            return True, "ok", None
    except Exception as exc:
        return False, None, str(exc)


def _parse_supervisor_state(stdout: str, supervisor_name: str) -> str | None:
    for line in stdout.splitlines():
        if not line.strip():
            continue
        if not line.startswith(supervisor_name):
            continue
        parts = line.split()
        if len(parts) >= 2:
            return parts[1]
    if stdout.strip() and supervisor_name in stdout:
        return stdout.strip()
    return None


class LocalServiceController:
    """Supervisor-backed lifecycle controller for host-local daemons.

    Authority boundary:
      - host-local Python daemons are controlled through code-svc/Supervisor
      - Docker/Compose/Portainer services are intentionally out of scope
    """

    def __init__(self, services: dict[str, ManagedLocalService] | None = None, *,
                 enabled: bool = True):
        self.services = services or DEFAULT_SERVICES
        self.enabled = enabled

    @classmethod
    def from_config(cls, config: LocalServicesConfig) -> "LocalServiceController":
        services = {
            service_id: ManagedLocalService.from_config(service_id, target)
            for service_id, target in config.targets.items()
        }
        return cls(services=services, enabled=config.enabled)

    def selected_services(self, service_id: str | None = None) -> list[ManagedLocalService]:
        if service_id:
            service = self.services.get(service_id)
            if not service:
                raise KeyError(f"unknown local service: {service_id}")
            return [service]
        return list(self.services.values())

    def status(self, service_id: str | None = None) -> list[LocalServiceStatus]:
        statuses: list[LocalServiceStatus] = []
        for service in self.selected_services(service_id):
            code_svc_path = shutil.which(service.code_svc_command)
            supervisor_result = (
                _run([service.code_svc_command, "status", service.supervisor_name])
                if code_svc_path else
                {
                    "args": [service.code_svc_command, "status", service.supervisor_name],
                    "returncode": None,
                    "stdout": "",
                    "stderr": f"{service.code_svc_command} not found",
                    "ok": False,
                }
            )
            supervisor_state = _parse_supervisor_state(supervisor_result.get("stdout", ""),
                                                       service.supervisor_name)
            supervisor_ok = supervisor_state == "RUNNING"
            health_ok, health_status, health_error = _check_health(service.health_url)
            statuses.append(LocalServiceStatus(
                service_id=service.service_id,
                label=service.label,
                authority=service.authority,
                supervisor_name=service.supervisor_name,
                code_svc_command=service.code_svc_command,
                supervisor_available=bool(code_svc_path),
                code_svc_path=code_svc_path,
                supervisor_state=supervisor_state,
                supervisor_ok=supervisor_ok,
                health_url=service.health_url,
                health_ok=health_ok,
                health_status=health_status,
                health_error=health_error,
                managed=service.managed,
                details={
                    "supervisor_status": supervisor_result,
                    "authority_note": "Supervisor via code-svc is authoritative for this host-local daemon.",
                },
            ))
        return statuses

    def action(self, action: ServiceAction,
               service_id: str | None = None) -> LocalServiceActionResult:
        if action == "status":
            statuses = self.status(service_id)
            return LocalServiceActionResult(
                ok=all(item.health_ok for item in statuses),
                action=action,
                service_id=service_id,
                message="status collected via Supervisor authority",
                statuses=statuses,
            )

        if not self.enabled:
            return LocalServiceActionResult(
                ok=False,
                action=action,
                service_id=service_id,
                message="local service control is disabled in config",
                statuses=self.status(service_id),
            )

        command_results: list[dict[str, Any]] = []
        ok = True
        for service in self.selected_services(service_id):
            if service.authority != "supervisor":
                ok = False
                command_results.append({
                    "service_id": service.service_id,
                    "ok": False,
                    "message": f"unsupported authority for local service control: {service.authority}",
                })
                continue
            if not service.managed:
                ok = False
                command_results.append({
                    "service_id": service.service_id,
                    "ok": False,
                    "message": "service target is configured as managed=false",
                })
                continue
            if not shutil.which(service.code_svc_command):
                ok = False
                command_results.append({
                    "service_id": service.service_id,
                    "ok": False,
                    "message": f"Supervisor CLI wrapper not found: {service.code_svc_command}",
                })
                continue

            result = _run([service.code_svc_command, action, service.supervisor_name], timeout=45.0)
            result["service_id"] = service.service_id
            result["authority"] = service.authority
            result["supervisor_name"] = service.supervisor_name
            command_results.append(result)
            ok = ok and result["ok"]

        return LocalServiceActionResult(
            ok=ok,
            action=action,
            service_id=service_id,
            message="Supervisor action complete" if ok else "one or more Supervisor actions failed",
            statuses=self.status(service_id),
            command_results=command_results,
        )