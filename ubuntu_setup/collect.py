"""Read-only probes. Commands have fixed arguments; fixtures never enter here."""

from dataclasses import dataclass
import glob
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import stat
import subprocess
import tempfile

from .model import DataError, SCOPES, observation, validate_observations

DPKG = ("dpkg-query", "-W", "-f=${binary:Package}\t${Version}\t${Architecture}\t${db:Status-Status}\t${db:Status-Eflag}\n")
COMMANDS = {
    "dpkg": DPKG,
    "snap": ("snap", "list", "--color=never", "--unicode=never"),
    "flatpak.system": ("flatpak", "list", "--system", "--all", "--columns=ref:f,version:f,active:f"),
    "flatpak.user": ("flatpak", "list", "--user", "--all", "--columns=ref:f,version:f,active:f"),
    "container": ("systemd-detect-virt", "--container"),
    "vm": ("systemd-detect-virt", "--vm"),
    "secure_boot": ("mokutil", "--sb-state"),
    "services": ("systemctl", "list-units", "--state=failed", "--all", "--no-legend", "--no-pager", "--plain"),
    "sysctl_config": ("systemd-analyze", "cat-config", "sysctl.d", "--no-pager"),
    "unit_config": ("systemctl", "show", "--all", "--no-pager", "--property=Id,LoadState,NeedDaemonReload,FragmentPath,DropInPaths", "*"),
    "graphics": ("/usr/bin/python3", str(Path(__file__).with_name("egl_probe.py"))),
}
SYSTEM_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"


class ProbeError(Exception):
    pass


@dataclass
class CommandResult:
    code: int
    output: str


class LocalProbe:
    def __init__(self, timeout=5.0):
        self.timeout = timeout

    def read(self, path):
        # proc/sys readers may allocate the requested buffer in the kernel. Avoid
        # multi-megabyte reads even though the total collection has an upper bound.
        chunks = []
        total = 0
        with Path(path).open("rb", buffering=0) as stream:
            while True:
                chunk = stream.read(4096)
                if not chunk:
                    break
                total += len(chunk)
                if total > 4 * 1024 * 1024:
                    raise ProbeError("文件超出本次采集大小限制")
                chunks.append(chunk)
        return b"".join(chunks).decode("utf-8", errors="strict")

    def exists(self, path):
        try:
            Path(path).stat()
            return True
        except FileNotFoundError:
            return False

    def listdir(self, path):
        return sorted(p.name for p in Path(path).iterdir())

    def link_name(self, path):
        try:
            return Path(os.readlink(path)).name
        except FileNotFoundError:
            return None

    def file_info(self, path):
        path = Path(path)
        try:
            before = path.stat()
        except FileNotFoundError:
            return {"exists": False}
        if not stat.S_ISREG(before.st_mode) or before.st_size > 4 * 1024 * 1024:
            raise ProbeError("监测对象不是大小合适的普通文件")
        with path.open("rb") as stream:
            data = stream.read(4 * 1024 * 1024 + 1)
        after = path.stat()
        if len(data) > 4 * 1024 * 1024 or (before.st_ino, before.st_mtime_ns, before.st_size) != (after.st_ino, after.st_mtime_ns, after.st_size):
            raise ProbeError("文件在采集过程中发生变化")
        return {"exists": True, "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data), "mode": stat.S_IMODE(after.st_mode)}

    def architecture(self):
        return platform.machine()

    def cpu_count(self):
        value = os.cpu_count()
        if value is None:
            raise ProbeError("逻辑处理器数量未知")
        return value

    def storage(self):
        values = os.statvfs("/")
        return {"total_bytes": values.f_blocks * values.f_frsize,
                "available_bytes": values.f_bavail * values.f_frsize,
                "read_only": bool(values.f_flag & os.ST_RDONLY)}

    def index_metadata(self):
        entries = [p.stat() for p in Path("/var/lib/apt/lists").iterdir()
                   if p.is_file() and p.name != "lock"]
        return {"index_file_count": len(entries),
                "oldest_file_mtime": min((s.st_mtime for s in entries), default=None),
                "newest_file_mtime": max((s.st_mtime for s in entries), default=None)}

    def run(self, key):
        if key == "graphics":
            with tempfile.TemporaryDirectory(prefix="ubuntu-setup-egl-") as root:
                return self._command(COMMANDS[key], extra_env={"XDG_CACHE_HOME": root, "MESA_SHADER_CACHE_DISABLE": "true",
                                                             "__GL_SHADER_DISK_CACHE": "0", "__GL_SHADER_DISK_CACHE_PATH": root})
        return self._command(COMMANDS[key])

    def glob(self, pattern):
        return sorted(glob.glob(pattern))

    def module_info(self, release, module):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.+-]*", release) or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]*", module):
            raise ProbeError("内核或模块名称无法安全读取")
        return self._command(("modinfo", "-k", release, module))

    def nvidia_status(self):
        return self._command(("nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"))

    def apt_checks(self, online=False):
        def read_result(args):
            result = self._command(args)
            if result.code != 0:
                raise ProbeError("APT 检查进程未完成")
            value = json.loads(result.output)
            if not isinstance(value, dict):
                raise ProbeError("APT 检查返回格式无法识别")
            if "error" in value:
                raise ProbeError("未安装 python3-apt，未自动补装" if value["error"] == "python_apt_missing" else "APT 状态或软件源无法完整读取")
            return value

        args = ("/usr/bin/python3", str(Path(__file__).with_name("apt_probe.py")))
        cached = read_result(args)
        if not online:
            return cached
        with tempfile.TemporaryDirectory(prefix="ubuntu-setup-apt-") as root:
            try:
                return read_result(args + (root,))
            except (ProbeError, ValueError):
                # Preserve an independent current-dependency result if the
                # network child timed out; never label cached indexes verified.
                cached["updates"].update(mode="online", refresh_status="failed", refresh_error="process_incomplete")
                return cached

    def _command(self, args, *, extra_env=None):
        executable = shutil.which(args[0], path=SYSTEM_PATH)
        if executable is None:
            raise ProbeError(f"未找到 {args[0]}，未安装探测依赖")
        env = {"PATH": SYSTEM_PATH, "LC_ALL": "C", "LANG": "C", "SYSTEMD_PAGER": "cat", "SYSTEMD_COLORS": "0"}
        for name in ("HOME", "XDG_RUNTIME_DIR", "XDG_DATA_HOME", "XDG_CONFIG_HOME"):
            if name in os.environ:
                env[name] = os.environ[name]
        env.update(extra_env or {})
        with subprocess.Popen((executable, *args[1:]), stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, env=env, start_new_session=True) as process:
            try:
                output, _ = process.communicate(timeout=self.timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
                if isinstance(exc, KeyboardInterrupt):
                    raise
                raise ProbeError(f"{args[0]} 超时，结果未知") from exc
        if len(output) > 16 * 1024 * 1024:
            raise ProbeError(f"{args[0]} 输出超出限制")
        return CommandResult(process.returncode, output.decode("utf-8", errors="strict"))


def parse_os_release(text, architecture):
    values = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "=" not in line:
            raise ProbeError("os-release 格式无法识别")
        name, raw = line.split("=", 1)
        parts = shlex.split(raw, comments=False)
        if len(parts) > 1:
            raise ProbeError("os-release 值格式无法识别")
        values[name] = parts[0] if parts else ""
    if not values.get("ID") or not values.get("VERSION_ID"):
        raise ProbeError("发行版或版本信息缺失")
    return {"id": values["ID"], "version_id": values["VERSION_ID"],
            "codename": values.get("VERSION_CODENAME", ""), "architecture": architecture}


def parse_dpkg(text):
    result = {}
    allowed = {"not-installed", "config-files", "half-installed", "unpacked", "half-configured",
               "triggers-awaited", "triggers-pending", "installed"}
    for line in text.splitlines():
        row = line.split("\t")
        if len(row) != 5 or not row[0] or row[0] in result or row[3] not in allowed or row[4] not in {"ok", "reinstreq"}:
            raise ProbeError("dpkg-query 输出无法完整解析")
        result[row[0]] = dict(zip(("version", "architecture", "status", "error_flag"), row[1:]))
    if not result:
        raise ProbeError("dpkg-query 返回空清单，不能据此判断全部软件已移除")
    return result


def parse_snap(text):
    lines = text.splitlines()
    if not lines or lines[0].split() != ["Name", "Version", "Rev", "Tracking", "Publisher", "Notes"]:
        raise ProbeError("snap list 输出无法识别；空输出不当作空清单")
    result = {}
    for line in lines[1:]:
        row = line.split()
        if len(row) != 6 or row[0] in result:
            raise ProbeError("snap list 条目无法完整解析")
        result[row[0]] = {"version": row[1], "revision": row[2], "tracking": row[3], "notes": row[5]}
    return result


def parse_flatpak(text):
    result = {}
    for line in text.splitlines():
        row = line.split("\t")
        if len(row) != 3 or not row[0] or row[0] in result:
            raise ProbeError("flatpak list 输出无法完整解析")
        result[row[0]] = {"version": row[1], "commit": row[2]}
    return result


def _successful(probe, key):
    result = probe.run(key)
    if result.code != 0:
        raise ProbeError(f"{COMMANDS[key][0]} 返回 {result.code}，本次结果未知")
    return result.output


def _environment(probe):
    for key, kind in (("container", "container"), ("vm", "vm")):
        result = probe.run(key)
        technology = result.output.strip()
        if result.code == 0 and re.fullmatch(r"[a-z0-9_-]+", technology) and technology != "none":
            return {"kind": "wsl" if technology == "wsl" else kind, "technology": technology}
        if result.code != 1 or technology != "none":
            raise ProbeError("虚拟化检测无法确定，不能默认当成真实主机")
    return {"kind": "physical", "technology": "none"}


def _resources(probe):
    memory = re.search(r"^MemTotal:\s+(\d+) kB$", probe.read("/proc/meminfo"), re.M)
    if memory is None:
        raise ProbeError("无法识别内存容量")
    cpu = re.search(r"^(?:model name|Hardware)\s*:\s*(.+)$", probe.read("/proc/cpuinfo"), re.M)
    return {"cpu_model": cpu[1] if cpu else "未提供型号", "logical_cpus": probe.cpu_count(),
            "memory_bytes": int(memory[1]) * 1024}


def _devices(probe, bus):
    base = f"/sys/bus/{bus}/devices"
    result = {}
    fields = {"vendor": "vendor", "device": "device", "class": "class"} if bus == "pci" else {
        "vendor": "idVendor", "device": "idProduct", "class": "bDeviceClass"}
    for name in probe.listdir(base):
        if bus == "usb" and ":" in name:  # Interfaces are included separately in bindings.
            continue
        entry = {}
        for field, filename in fields.items():
            value = probe.read(f"{base}/{name}/{filename}").strip()
            if not re.fullmatch(r"(?:0x)?[0-9a-fA-F]{2,8}", value):
                raise ProbeError(f"{bus} 设备属性无法解析")
            entry[field] = value.lower()
        result[name] = entry
    return result


def _bindings(probe):
    result = {}
    for bus in ("pci", "usb"):
        base = f"/sys/bus/{bus}/devices"
        for name in probe.listdir(base):
            path = f"{base}/{name}"
            driver = probe.link_name(path + "/driver")
            module = probe.link_name(path + "/driver/module") if driver else None
            if not probe.exists(path):
                raise ProbeError("设备在读取驱动关系时消失，需重新检查")
            result[f"{bus}:{name}"] = {"driver": driver, "module": module}
    return result


def _modules(probe):
    result = {}
    for line in probe.read("/proc/modules").splitlines():
        row = line.split()
        if len(row) < 6 or not re.fullmatch(r"[A-Za-z0-9_-]+", row[0]):
            raise ProbeError("模块清单无法完整解析")
        entry = {"state": row[4]}
        for field in ("version", "srcversion"):
            try:
                entry[field] = probe.read(f"/sys/module/{row[0]}/{field}").strip() or None
            except FileNotFoundError:
                entry[field] = None  # Many modules do not expose version metadata.
        if not probe.exists(f"/sys/module/{row[0]}"):
            raise ProbeError("模块在采集过程中消失，需重新检查")
        result[row[0]] = entry
    return result


def _sources(probe):
    paths = []
    if probe.exists("/etc/apt/sources.list"):
        paths.append("/etc/apt/sources.list")
    if probe.exists("/etc/apt/sources.list.d"):
        paths.extend(f"/etc/apt/sources.list.d/{name}" for name in probe.listdir("/etc/apt/sources.list.d")
                     if re.fullmatch(r"[A-Za-z0-9_.-]+\.(?:list|sources)", name))
    return {path: probe.file_info(path) for path in paths}


def _services(probe):
    result = {}
    for line in _successful(probe, "services").splitlines():
        row = line.split(maxsplit=4)
        if len(row) < 4 or row[2] != "failed":
            raise ProbeError("失败服务清单无法完整解析")
        result[row[0]] = {"load": row[1], "active": row[2], "sub": row[3]}
    return result


def collect(probe, watch_configs=(), *, online=False, confirmations=None, previous=None, target_id="", confirmation_basis=None):
    """A failure affects one scope. No collector installs its missing dependency."""
    observations = {}

    def capture(scope, fn, coverage=None):
        try:
            value = fn()
            if scope.startswith("checks."):
                from .check_model import validate_check_observation
                if not isinstance(value, dict):
                    raise ProbeError("扩展检查返回格式无法识别")
                validate_check_observation(scope, value)
            observations[scope] = observation(scope, value, coverage=coverage)
        except (OSError, UnicodeError, ProbeError, ValueError) as exc:
            reason = str(exc) if isinstance(exc, ProbeError) else type(exc).__name__
            observations[scope] = observation(scope, status="unknown", reason=reason, coverage=coverage)

    capture("os", lambda: parse_os_release(probe.read("/etc/os-release"), probe.architecture()), ["/etc/os-release"])
    capture("environment", lambda: _environment(probe))
    capture("resources", lambda: _resources(probe), ["/proc/cpuinfo", "/proc/meminfo"])
    capture("storage", probe.storage, ["/"])
    capture("kernel", lambda: {"release": probe.read("/proc/sys/kernel/osrelease").strip()})
    capture("boot", lambda: {"id": probe.read("/proc/sys/kernel/random/boot_id").strip()})
    observations["kernel.next_boot"] = observation("kernel.next_boot", status="unknown", reason="尚未核实引导选择；不从已安装内核推断下次启动版本")
    capture("packages.dpkg", lambda: parse_dpkg(_successful(probe, "dpkg")))
    capture("packages.snap", lambda: parse_snap(_successful(probe, "snap")))
    for installation in ("system", "user"):
        capture(f"packages.flatpak.{installation}", lambda inst=installation: parse_flatpak(_successful(probe, f"flatpak.{inst}")),
                [f"flatpak 默认{installation}安装；不含自定义 installation 或其他用户"])
    capture("sources.apt", lambda: _sources(probe), ["/etc/apt/sources.list", "/etc/apt/sources.list.d；仅摘要，不含凭据"])
    capture("metadata.apt", probe.index_metadata, ["/var/lib/apt/lists；文件时间不能证明内容新鲜或来源有效"])
    for bus in ("pci", "usb"):
        capture(f"hardware.{bus}", lambda b=bus: _devices(probe, b), [f"/sys/bus/{bus}/devices；不读取序列号"])
    capture("drivers.bindings", lambda: _bindings(probe))
    capture("drivers.modules", lambda: _modules(probe), ["/proc/modules 与 /sys/module 的版本信息；版本可能未提供，不含内建驱动，不验证签名"])

    def secure_boot():
        output = _successful(probe, "secure_boot").splitlines()
        if not output or output[0] not in {"SecureBoot enabled", "SecureBoot disabled"}:
            raise ProbeError("Secure Boot 状态无法识别；不推断为关闭")
        return {"enabled": output[0] == "SecureBoot enabled"}

    capture("drivers.secure_boot", secure_boot)
    capture("reboot", lambda: {"required_marker": probe.exists("/run/reboot-required")}, ["/run/reboot-required；缺少标志不代表所有变更均已生效"])
    capture("services", lambda: _services(probe), ["当前可访问的系统服务；不含所有用户服务"])
    capture("configs", lambda: {str(Path(p).absolute()): probe.file_info(p) for p in watch_configs},
            list(watch_configs) or ["未指定额外配置；未验证配置语法或生效情况"])
    from .check_collect import collect_configs, collect_drivers, collect_hardware
    try:
        apt = probe.apt_checks(online)
        for scope, key in (("checks.packages", "packages"), ("checks.updates", "updates")):
            capture(scope, lambda k=key: apt.get(k), coverage=["APT/dpkg；不含 Snap、Flatpak 或手动安装软件", "联网索引仅在临时目录" if online else "仅本地缓存"])
    except (OSError, UnicodeError, ProbeError, ValueError) as exc:
        reason = str(exc) if isinstance(exc, ProbeError) else type(exc).__name__
        for scope in ("checks.packages", "checks.updates"):
            observations[scope] = observation(scope, status="unknown", reason=reason)
    capture("checks.drivers", lambda: collect_drivers(probe, observations),
            ["已绑定 PCI/USB 模块与当前内核；modinfo、固件文件及 NVIDIA 管理接口；不加载模块"])
    capture("checks.configs", lambda: collect_configs(probe, watch_configs),
            ["systemd 选择的 sysctl.d 配置与 /proc/sys 数字值；已加载系统单元的配置状态"])
    capture("checks.hardware", lambda: collect_hardware(probe, observations, confirmations or {}, previous, target_id, confirmation_basis),
            ["离屏 EGL/GLES 单像素绘制回读；显示、声音、输入由用户确认；不覆盖全部设备"])
    assert set(observations) == set(SCOPES)
    validate_observations(observations)
    return observations


def live_identity(probe):
    try:
        value = probe.read("/etc/machine-id").strip()
    except (OSError, UnicodeError, ProbeError) as exc:
        raise DataError("无法识别系统安装实例，不能关联已保存档案") from exc
    if not re.fullmatch(r"[0-9a-f]{32}", value) or value == "0" * 32:
        raise DataError("machine-id 无效，未创建或关联机器档案")
    return value  # Used only in keyed identity comparison, never serialized.
