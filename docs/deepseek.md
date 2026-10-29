# DeepSeek 本机部署

`swkit deepseek` 部署固定版本 `DeepSeek-V4.1-Flash-1017` 的 `UD-IQ1_S` GGUF。
这是 Unsloth 的低位量化权重，质量与原始精度存在差别。5 个分片约 233 GB；
运行程序为 Unsloth `b11876-mix-ec42614` 的 Linux x86_64 CUDA 12 portable 构建。
模型修订号、每个文件大小和 SHA256 在 `configs/deepseek/manifest.json`，不随运行自动升级。

需要 Python 3.12+、curl、Linux x86_64 和独立挂载的磁盘。安装前用 `plan` 检查，
再对相同位置执行 `install`。路径必须是绝对路径，不能含空格、引号、反斜杠或 `%`。

```bash
swkit deepseek plan --data-dir /mnt/ssd/deepseek --backing-mount /mnt/ssd
swkit deepseek install --data-dir /mnt/ssd/deepseek --backing-mount /mnt/ssd
# Or keep the download running after the terminal closes (requires a user systemd bus):
swkit deepseek background --data-dir /mnt/ssd/deepseek --backing-mount /mnt/ssd
swkit deepseek status
swkit deepseek verify
swkit deepseek configure
swkit deepseek start
curl http://127.0.0.1:18080/health
swkit deepseek stop
```

`plan` 只读；`install` 使用当前用户下载、逐文件校验 SHA256 后改名，断线保留 `.part`
供重跑续传。安装目录和运行记录分别由显式参数和 XDG 状态目录决定，不修改驱动、
系统包、现有 Ollama 或 Shell 配置。不会自动删除模型。`status` 检查文件大小和程序
版本；`verify` 重新读取全部 233 GB 校验，二者都不等于推理验收。

下载固定使用 HTTPS 上的 HTTP/1.1，避开已在目标机器观察到的 HTTP/2 协议中断。
临时连接错误最多额外续传 4 次，每次按磁盘上实际保留的长度续传；HTTP 权限或
不存在错误、证书校验错误、磁盘错误及最终 SHA256 不匹配不会被当作临时传输错误重试。
参数含义以 [curl 官方手册](https://curl.se/docs/manpage.html) 及目标机器版本为准。

模型文件默认从 Hugging Face 下载；网络不稳定时可对 `plan`、`install`、`deploy` 或
`background` 显式增加 `--model-source modelscope`，从同一发布者的
[ModelScope 仓库](https://modelscope.cn/models/unsloth/DeepSeek-V4.1-Flash-1017-GGUF)续传。
先从该站读取文件清单，要求全部 5 个文件的大小、SHA256 与固定 Hugging Face 清单一致，
再使用该站返回的固定文件修订号下载；不一致或修订号不固定时拒绝切换。最后仍校验
整个分片的 SHA256。已完成分片和 `.part` 保留，不复制为第二套模型。
选择只作用于本次模型下载，不改变系统代理、DNS 配置或运行组件的来源；续传时沿用
完整命令中的源参数。短片段测速不保证整个 233 GB 下载速度或成功。

CUDA 构建仍需要 CUDA 12 用户态库，`nvidia-smi` 正常不代表这些库已经能加载。
若本机已有受信任、与该构建兼容的 CUDA 12.8 库，可执行
`swkit deepseek prepare-cuda --from-dir /absolute/compatible/library/directory`。
它将 `libcudart.so.12`、`libcublas.so.12` 和 `libcublasLt.so.12` 的真实内容复制到
数据目录的 `cuda-libs/`，校验复制后的大小与 SHA256，并要求运行程序实际列出 CUDA
设备。已有不同内容时拒绝覆盖。原目录不修改，复制完成后不依赖原软件继续保留这些文件。
来源、校验值和设备结果保存在该目录的 `manifest.json`。
配置服务时只为这个服务设置 `LD_LIBRARY_PATH`，不修改全局动态库路径、驱动或 Shell。
这项操作验证库加载及设备枚举，不能代替模型推理验收。

`deploy` 顺序执行安装和服务配置；`background` 将其交给用户的 systemd 管理器，
内存限制 1 GiB。后台任务通过 `journalctl --user -u deepseek-deploy` 查看；
`stop-download` 仅停止这个任务，保留所有已下载内容。后台任务可跨终端关闭继续运行，
不能跨重启继续运行，重启后重新运行 `background` 续传。完成下载后的服务配置仍需
当时有效的 sudo 授权；配置失败不删除已校验的模型。后台任务不等于部署完成。

`configure` 校验并安装 `/etc/systemd/system/deepseek-local.service`，需 sudo。
不覆盖无管理标记的同名服务；更新已有受管服务前备份。默认不启动、不启用开机启动。
服务以配置时的普通用户运行，只监听 `127.0.0.1:18080`，提供 llama-server 的网页和
OpenAI 兼容接口。SSD 掉线时由挂载依赖停止；运行数据不能移动后直接沿用旧配置。

初始上下文 4096 tokens、并发 1、CPU 线程 24；GPU 自动分配，Engram 使用 mmap
和按需读取。内存软限制 112 GiB、硬限制 118 GiB，禁用服务交换，防止拖垮桌面。
这不是对所有硬件的自动适配：发布方估计需要 128–145 GB 内存加显存，
还要考虑桌面占用。GPU 驱动不正常时 `start` 拒绝启动。完整推理、可接受速度、
重启后访问和内存余量仍须在目标机器验证；不把官方支持、文件完整或程序启动当作通过。

恢复：`stop` 停止服务且保留全部模型。恢复服务文件前检查本次备份与之后的改动，
只还原相应配置，然后 `systemctl daemon-reload`。不提供自动数据删除或驱动回滚。

依据：

- [DeepSeek 官方发布](https://api-docs.deepseek.com/news/news261017/)
- [Unsloth 运行指南、内存与量化结果](https://unsloth.ai/docs/models/deepseek-v4.1-flash)
- [固定模型来源](https://huggingface.co/unsloth/DeepSeek-V4.1-Flash-1017-GGUF/tree/60ad3651641b5c97679c807e064ab1d7a3ca1455)
- [运行程序发布与 DeepSeek 支持提交](https://github.com/unslothai/llama.cpp/releases/tag/b11876-mix-ec42614)

检查命令：`bash -n scripts/deepseek.sh`、
`shellcheck -x --source-path=SCRIPTDIR scripts/deepseek.sh`、
`python3 -m unittest discover -s tests -p test_deepseek.py -v`。
