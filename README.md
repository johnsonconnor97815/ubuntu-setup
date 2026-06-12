# ubuntu-setup

[![CI](https://github.com/johnsonconnor97815/ubuntu-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/johnsonconnor97815/ubuntu-setup/actions/workflows/ci.yml)

为全新安装的 Ubuntu 机器自动化安装与配置软件的工具(Python + bash)。

## 开发环境初始化(克隆后首次)

本仓库用 [Trellis](.trellis/) 管理开发流程,并集成 Codegraph 代码索引。新机器 `git clone` 后,用内置 setup skill 一键拉齐本地环境(安装并索引 Codegraph、注册 codegraph MCP、设置 Trellis 开发者身份):

- **Claude Code**:运行 `/trellis:setup`
- **Codex CLI**:触发 `trellis-setup` skill(位于 `.agents/skills/trellis-setup/`,Codex 原生扫描)

流程幂等,可安全重复运行。Codex 用户还需在用户级 `~/.codex/config.toml` 开 `[features].hooks = true` 并 `/hooks` 审批一次(详见 skill 说明)。

## 本地跑集成验证(真装回归)

单元套件(`python -m unittest discover -s tests`)默认不真装任何东西。catalog 条目的真装回归在 `tests/integration/`(一次性干净 Ubuntu 24.04 guest,逐条目 fresh check → install → 幂等重跑),由 `UBUNTU_SETUP_INTEGRATION=1` 解锁:

```bash
# 容器档(Docker;apt / deb / ppa / script 四个遍历套件,各自独立模块)
UBUNTU_SETUP_INTEGRATION=1 python -m unittest tests.integration.test_container_catalog -v

# snap 档(LXD/Incus 系统容器;主机无 lxd/incus 时显式 skip 并给出解锁步骤)
UBUNTU_SETUP_INTEGRATION=1 python -m unittest tests.integration.test_system_snap -v
```

并行度、条目过滤、诊断产物等旋钮见 `tests/integration/__init__.py` 与各套件模块的 docstring。`UBUNTU_SETUP_VERIFY_BASE_IMAGE`(以字节一致的官方镜像源替换 `ubuntu:24.04`,如 `mirror.gcr.io/library/ubuntu:24.04`)仅供 docker.io 被本机代理劫持的开发机使用;CI 不设置它。

CI 上同一批套件由 [`catalog-verify.yml`](.github/workflows/catalog-verify.yml) 以五档并行(apt/deb/ppa/script/snap)按周程 + 手动触发全量回归。
