"""Private local storage with a single writer and an atomic publication point."""

import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import stat
import tempfile

from .model import DataError, SCOPES, new_id, now, read_json, validate_snapshot


def _identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{32}", value):
        raise DataError("记录编号格式错误，未访问其引用路径")
    return value


class StateStore:
    def __init__(self, root):
        self.root = Path(root).absolute()
        self.lock_fd = None

    def _path(self, relative):
        rel = Path(relative)
        if rel.is_absolute() or ".." in rel.parts:
            raise DataError("状态文件引用越界")
        current = self.root
        for part in rel.parts:
            current = current / part
            if current.is_symlink():
                raise DataError("状态文件或目录不能是符号链接")
        return current

    def _directory(self, relative):
        path = self._path(relative)
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        directories = [self.root]
        current = self.root
        for part in path.relative_to(self.root).parts:
            current = current / part
            current.mkdir(mode=0o700, exist_ok=True)
            directories.append(current)
        for directory in directories:
            info = directory.stat()
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise DataError("状态目录必须仅当前用户可访问；请选择独立的私有目录")
        return path

    def __enter__(self):
        project = Path(__file__).resolve().parent.parent
        if self.root.is_symlink() or self.root.resolve().is_relative_to(project):
            raise DataError("机器记录必须保存在仓库之外，且状态目录不能是符号链接")
        self._directory(".")
        path = self._path(".lock")
        self.lock_fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            os.close(self.lock_fd)
            self.lock_fd = None
            raise DataError("另一个检查任务正在使用这个状态目录") from exc
        return self

    def __exit__(self, *args):
        if self.lock_fd is not None:
            fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            os.close(self.lock_fd)
            self.lock_fd = None

    def write(self, relative, value, *, immutable=False, text=False):
        destination = self._path(relative)
        parent = self._directory(str(Path(relative).parent))
        if immutable and destination.exists():
            raise DataError("拒绝覆盖已有历史记录")
        data = value if text else json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
        fd, temporary = tempfile.mkstemp(prefix=".write-", dir=parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, destination)
            directory_fd = os.open(parent, os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def read(self, relative):
        return read_json(self._path(relative))

    def bind(self, source_kind, token):
        path = self._path("identity.json")
        if path.exists():
            identity = self.read("identity.json")
            if not isinstance(identity, dict) or identity.get("schema_version") != 1:
                raise DataError("不认识的机器身份记录")
            _identifier(identity.get("machine_id"))
            salt = identity.get("binding_salt")
            if not isinstance(salt, str) or not re.fullmatch(r"[0-9a-f]{64}", salt):
                raise DataError("机器身份关联记录损坏")
            digest = hmac.new(bytes.fromhex(salt), token.encode(), hashlib.sha256).hexdigest()
            if identity.get("source_kind") != source_kind or not hmac.compare_digest(str(identity.get("binding_digest", "")), digest):
                raise DataError("目标身份或真实/模拟来源不符；保留原记录，请使用另一状态目录")
        else:
            existing = [p for p in self.root.iterdir() if p.name != ".lock"]
            if existing:
                raise DataError("已有资料但缺少机器身份记录，不能当作首次运行")
            salt = os.urandom(32)
            identity = {"schema_version": 1, "machine_id": new_id(), "source_kind": source_kind,
                        "binding_salt": salt.hex(),
                        "binding_digest": hmac.new(salt, token.encode(), hashlib.sha256).hexdigest(), "created_at": now()}
            self.write("identity.json", identity, immutable=True)
        self.identity = identity
        return identity["machine_id"]

    def event(self, run_id, sequence, kind, **details):
        path = self._path(f"runs/{_identifier(run_id)}/events.jsonl")
        fd = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as stream:
            stream.write(json.dumps({"schema_version": 1, "sequence": sequence, "event_id": new_id(),
                                     "machine_id": self.identity["machine_id"], "run_id": run_id,
                                     "occurred_at": now(), "kind": kind, **details}, ensure_ascii=False, allow_nan=False) + "\n")
            stream.flush()
            os.fsync(stream.fileno())

    def _load_run(self, run_id):
        run_id = _identifier(run_id)
        manifest = self.read(f"runs/{run_id}/state.json")
        if not isinstance(manifest, dict) or manifest.get("schema_version") != 1 or manifest.get("status") != "completed" or manifest.get("run_id") != run_id:
            raise DataError("当前记录没有完整的完成标记")
        snapshot = self.read(f"inventory/snapshots/{run_id}.json")
        validate_snapshot(snapshot)
        if snapshot["machine_id"] != self.identity["machine_id"] or snapshot["source_kind"] != self.identity["source_kind"] or snapshot["run_id"] != run_id or snapshot["snapshot_id"] != run_id:
            raise DataError("快照与当前目标不匹配")
        assessment = self.read(f"assessments/{run_id}.json")
        if not isinstance(assessment, dict) or assessment.get("schema_version") != 1 or assessment.get("snapshot_id") != run_id or assessment.get("assessment_id") != run_id or assessment.get("machine_id") != self.identity["machine_id"]:
            raise DataError("检查结果与快照不匹配")
        if not isinstance(assessment.get("checks"), list):
            raise DataError("检查结果格式错误")
        seen = set()
        for check in assessment["checks"]:
            if not isinstance(check, dict) or not isinstance(check.get("check_id"), str) or not isinstance(check.get("input_scopes"), list) or not isinstance(check.get("result"), str) or check["result"] not in {"passed", "failed", "unknown", "pending", "not_applicable"}:
                raise DataError("检查项目格式错误")
            if not all(isinstance(scope, str) and scope in snapshot["observations"] for scope in check["input_scopes"]):
                raise DataError("检查项目的输入范围错误")
            if not isinstance(check.get("context", {}), dict):
                raise DataError("检查项目的等待记录错误")
            if not isinstance(check.get("reason_code", ""), str):
                raise DataError("检查项目的原因编号错误")
            if not check["check_id"] or check["check_id"] in seen or not isinstance(check.get("rule_version"), str) or not check["rule_version"]:
                raise DataError("检查项目的编号或版本错误")
            seen.add(check["check_id"])
            context = check.get("context", {})
            if "pending_boot_id" in context and context["pending_boot_id"] is not None and not isinstance(context["pending_boot_id"], str):
                raise DataError("等待重启的启动标识格式错误")
            if "rule_versions" in assessment:
                observations = snapshot["observations"]
                scopes = check["input_scopes"]
                expected = [observations[s]["observation_id"] for s in scopes]
                if check.get("observation_refs") != expected:
                    raise DataError("检查结果的观察引用与快照不匹配")
                refs = check.get("evidence_refs")
                if not isinstance(refs, list) or len(refs) != len(scopes):
                    raise DataError("检查结果缺少证据引用")
                for ref, scope in zip(refs, scopes):
                    obs = observations[scope]
                    expected_ref = {"snapshot_id": run_id, "scope": scope, "observation_id": obs["observation_id"],
                                    "observed_at": obs["observed_at"], "collector_version": obs["collector_version"],
                                    "status": obs["status"], "coverage": obs["coverage"]}
                    if ref != expected_ref:
                        raise DataError("检查证据与对应观察不匹配")
        if "rule_versions" in assessment and assessment["rule_versions"] != {c["check_id"]: c["rule_version"] for c in assessment["checks"]}:
            raise DataError("检查记录的规则版本清单不匹配")
        changes = self.read(f"runs/{run_id}/changes.json")
        if not isinstance(changes, dict) or changes.get("schema_version") != 1 or not isinstance(changes.get("changes"), list) or not isinstance(changes.get("invalidated_checks"), list):
            raise DataError("变化记录格式错误")
        report_file = manifest.get("report_file", "report.md")
        if report_file not in ("report.html", "report.md"):
            raise DataError("不认识的报告文件格式")
        if not self._path(f"runs/{run_id}/{report_file}").is_file():
            raise DataError("完成记录缺少报告")
        return snapshot, assessment

    def load_previous(self):
        recovered = []
        pointer = self.read("inventory/current.json") if self._path("inventory/current.json").exists() else None
        if pointer is not None and (not isinstance(pointer, dict) or pointer.get("schema_version") != 1 or pointer.get("machine_id") != self.identity["machine_id"]):
            raise DataError("当前快照索引格式或目标不符")
        current = _identifier(pointer.get("run_id")) if pointer is not None else None
        if current:
            self._load_run(current)
        manifests = {}
        run_root = self._path("runs")
        for path in sorted(run_root.iterdir()) if run_root.exists() else []:
            run_id = _identifier(path.name)
            self._path(f"runs/{run_id}")
            if not path.is_dir():
                raise DataError("任务路径格式错误")
            manifest_path = f"runs/{run_id}/state.json"
            if not self._path(manifest_path).exists():
                # A crash immediately after mkdir has not published any snapshot.
                manifest = {"schema_version": 1, "run_id": run_id, "status": "interrupted"}
            else:
                manifest = self.read(manifest_path)
                if not isinstance(manifest, dict) or manifest.get("schema_version") != 1 or manifest.get("run_id") != run_id or manifest.get("status") not in {"collecting", "completed", "interrupted"}:
                    raise DataError("历史任务状态损坏")
            if manifest["status"] != "completed":
                if manifest["status"] == "collecting" or not self._path(manifest_path).exists():
                    manifest.update(status="interrupted", recovered_at=now())
                    self.write(manifest_path, manifest)
                recovered.append({"run_id": run_id, "status": "interrupted", "action": "保留原始记录，本次重新采集"})
            else:
                manifests[run_id] = manifest
        # Recover a completed report whose publication was interrupted. The predecessor
        # chain, not wall-clock order, decides which complete snapshot can follow current.
        seen = set()
        while True:
            candidates = [rid for rid, m in manifests.items() if rid != current and m.get("previous_run_id") == current]
            if not candidates:
                break
            if len(candidates) != 1 or candidates[0] in seen:
                raise DataError("完成记录存在分叉或循环，未猜测当前快照")
            candidate = candidates[0]
            self._load_run(candidate)
            seen.add(candidate)
            current = candidate
            self._publish(current)
            recovered.append({"run_id": current, "status": "completed", "action": "已恢复完整报告的索引"})
        if current is None and manifests:
            raise DataError("缺少可验证的快照索引，不能当作首次运行")
        previous, assessment = self._load_run(current) if current else (None, None)
        return previous, assessment, recovered

    def last_known(self, previous):
        result = {}
        if previous is None:
            return result
        for scope, obs in previous["observations"].items():
            ref = obs.get("last_known_ref")
            if obs["status"] == "observed" or ref is None:
                continue
            if not isinstance(ref, dict) or ref.get("scope") != scope:
                raise DataError("上次已知观察的引用错误")
            snapshot_id = _identifier(ref.get("snapshot_id"))
            snapshot = self.read(f"inventory/snapshots/{snapshot_id}.json")
            validate_snapshot(snapshot)
            if snapshot["machine_id"] != self.identity["machine_id"] or snapshot["source_kind"] != self.identity["source_kind"] or snapshot["snapshot_id"] != snapshot_id:
                raise DataError("上次已知观察来自其他目标或错误快照")
            candidate = snapshot["observations"][scope]
            if candidate["status"] != "observed":
                raise DataError("上次已知观察不是有效采集结果")
            result[scope] = candidate
        return result

    def begin(self, run_id, previous, source_kind):
        self._directory(f"runs/{_identifier(run_id)}")
        self.write(f"runs/{run_id}/state.json", {"schema_version": 1, "run_id": run_id, "status": "collecting",
                   "previous_run_id": previous["run_id"] if previous else None,
                   "source_kind": source_kind, "started_at": now()}, immutable=True)
        self.event(run_id, 1, "collection_started")

    def _publish(self, run_id):
        self.write("inventory/current.json", {"schema_version": 1, "machine_id": self.identity["machine_id"], "run_id": run_id})

    def finish(self, snapshot, assessment, changes, invalidations, report):
        run_id = snapshot["run_id"]
        self.write(f"inventory/snapshots/{run_id}.json", snapshot, immutable=True)
        self.write(f"assessments/{run_id}.json", assessment, immutable=True)
        self.write(f"runs/{run_id}/changes.json", {"schema_version": 1, "changes": changes, "invalidated_checks": invalidations}, immutable=True)
        self.write(f"runs/{run_id}/report.html", report, immutable=True, text=True)
        self.event(run_id, 2, "report_completed", snapshot_id=run_id, report_file="report.html")
        manifest = self.read(f"runs/{run_id}/state.json")
        manifest.update(status="completed", completed_at=now(), report_file="report.html")
        self.write(f"runs/{run_id}/state.json", manifest)
        self._publish(run_id)
