import json
import fnmatch
from pathlib import Path

from ubuntu_setup.collect import CommandResult
from ubuntu_setup.model import load_fixture

FIXTURE = Path(__file__).parent / "fixtures/desktop.json"


def fixture_data():
    return json.loads(FIXTURE.read_text())


def observations():
    return load_fixture(FIXTURE)[1]


class FakeProbe:
    """Synthetic OS boundary: no host files, environment or subprocesses."""

    def __init__(self):
        self.files = {
            "/etc/os-release": 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n',
            "/proc/meminfo": "MemTotal:       8388608 kB\n",
            "/proc/cpuinfo": "model name : Synthetic CPU\n",
            "/proc/sys/kernel/osrelease": "6.8.0-example\n",
            "/proc/sys/kernel/random/boot_id": "synthetic-boot-a\n",
            "/proc/modules": "example 1024 0 - Live 0x00000000\n",
            "/sys/module/example/version": "1.0-example\n",
            "/sys/module/example/srcversion": "synthetic-source-a\n",
            "/sys/bus/pci/devices/0000:01:00.0/vendor": "0xffff\n",
            "/sys/bus/pci/devices/0000:01:00.0/device": "0x0001\n",
            "/sys/bus/pci/devices/0000:01:00.0/class": "0x030000\n",
            "/sys/bus/usb/devices/1-1/idVendor": "ffff\n",
            "/sys/bus/usb/devices/1-1/idProduct": "0002\n",
            "/sys/bus/usb/devices/1-1/bDeviceClass": "00\n",
            "/proc/sys/vm/swappiness": "60\n",
        }
        self.directories = {"/sys/bus/pci/devices": ["0000:01:00.0"],
                            "/sys/bus/usb/devices": ["1-1", "1-1:1.0"],
                            "/etc/apt/sources.list.d": ["example.sources"]}
        self.commands = {"container": CommandResult(1, "none\n"), "vm": CommandResult(1, "none\n"),
                         "dpkg": CommandResult(0, "nano\t1.0-example\tamd64\tinstalled\tok\n"),
                         "snap": CommandResult(0, "Name Version Rev Tracking Publisher Notes\n"),
                         "flatpak.system": CommandResult(0, ""), "flatpak.user": CommandResult(0, ""),
                         "secure_boot": CommandResult(0, "SecureBoot enabled\n"),
                         "services": CommandResult(0, ""),
                         "sysctl_config": CommandResult(0, "# /etc/sysctl.d/example.conf\nvm.swappiness=60\n"),
                         "unit_config": CommandResult(0, "Id=example.service\nLoadState=loaded\nNeedDaemonReload=no\nFragmentPath=/usr/lib/systemd/system/example.service\nDropInPaths=\n"),
                         "graphics": CommandResult(0, '{"status":"unavailable","stage":"synthetic"}')}
        self.calls = []

    def read(self, path):
        if path not in self.files:
            raise FileNotFoundError(path)
        value = self.files[path]
        if isinstance(value, Exception):
            raise value
        return value

    def listdir(self, path):
        return list(self.directories[path])

    def exists(self, path):
        return path in self.files or path in self.directories or path.startswith("/sys/bus/") or path == "/sys/module/example"

    def link_name(self, path):
        return "example" if "/driver" in path else None

    def file_info(self, path):
        return {"exists": True, "sha256": "synthetic-digest", "size": 10, "mode": 420}

    def architecture(self):
        return "x86_64"

    def cpu_count(self):
        return 4

    def storage(self):
        return {"total_bytes": 100000, "available_bytes": 50000, "read_only": False}

    def index_metadata(self):
        return {"index_file_count": 2}

    def run(self, key):
        self.calls.append(key)
        result = self.commands[key]
        if isinstance(result, Exception):
            raise result
        return result

    def glob(self, pattern):
        return sorted(p for p in self.files if fnmatch.fnmatchcase(p, pattern))

    def module_info(self, release, module):
        return CommandResult(0, "filename: /lib/modules/example.ko\nversion: 1.0-example\n"
                                "srcversion: synthetic-source-a\nvermagic: 6.8.0-example SMP\nsigner: Example\n"
                                "alias: pci:*\nalias: usb:*\n")

    def apt_checks(self, online=False):
        return {"packages": {"backend": "synthetic", "installed_count": 1, "broken": [], "held": [], "held_changed": [],
                             "simulation_resolved": True, "simulation_broken_count": 0, "actions": [],
                             "metadata_mode": "online" if online else "cache", "metadata_complete": True},
                "updates": {"mode": "online" if online else "cache", "refresh_status": "verified" if online else "not_requested",
                            "refresh_error": "", "sources": [{"id": "synthetic", "suite": "noble", "apt_trusted": True,
                                                              "package_indexes": 1, "missing_indexes": 0}],
                            "unsafe_options": [], "candidates": [], "metadata_complete": True}}
