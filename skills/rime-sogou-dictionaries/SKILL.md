---
name: rime-sogou-dictionaries
description: 为 Ubuntu Fcitx5 下已在使用的 RIME 白霜拼音添加或更新搜狗「网络流行新词」和「开发大神专用词库」。用于转换官方 SCEL、检查重复词、试部署和核对候选，保留白霜、模糊音、整句模型及个人词库。
---

# 为白霜拼音补充搜狗词库

1. 核对目标用户的 Fcitx5 当前方案、RIME 用户目录及生效的 `translator/dictionary` 和 `translator/user_dict`。默认目录是 `${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5/rime`。本流程适用于 `rime_frost` 及本 Skill 生成的 `rime_frost.sogou`。有其他主词库时先查清覆盖关系。安装输入法框架属于单独的操作。
2. 从[网络流行新词](https://pinyin.sogou.com/dict/detail/index/4)和[开发大神专用词库](https://pinyin.sogou.com/dict/detail/index/75228)的官方下载按钮分别获取两份 `.scel`。使用实际下载文件的词条数和摘要记录来源。可在私有临时目录准备个人词库文本导出。使用 `rime_dict_manager -b <用户词库名>` 时，在稳定复制的用户词库上运行，避免触碰桌面正在使用的数据库或同步目录。
3. 用 Python 3.10+ 和 PyYAML 准备候选文件。脚本读取指定的 RIME 目录，输出到一个尚不存在、位于该目录之外的私有目录。个人词库导出可选，提供后也参与去重。

   ```sh
   python3 skills/rime-sogou-dictionaries/scripts/prepare.py \
     --rime-dir "${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5/rime" \
     --hotwords "$stage/hotwords.scel" --developer "$stage/developer.scel" \
     --output "$stage/prepared"
   ```

   按需追加 `--personal-export "$stage/rime_frost.userdb.txt"`。检查输出的 `report.json`，核对原始、重复、跳过和新增数量。保留两份独立的补充表。RIME 1.10 的 `import_tables` 不递归，汇总词库必须保留白霜主词库的直接导入列表和本地词条。更新白霜之后重新生成汇总词库。用户要单独关闭其中一份时，移除汇总词库里的对应导入即可。
4. 在独立的 RIME 用户目录试部署。复制当前配置、词库和模型，省略 `installation.yaml` 和同步目录，再覆盖候选目录生成的 YAML。可用 `rime_deployer --build "$trial_rime_dir" /usr/share/rime-data` 编译。核对编译使用原个人词库名和原有模糊音、模型设置，并检查新老词库都被收录。用每份新增词表中的一个代表词，再加几组原常用词、整句和模糊音，对比修改前后的首选及前五。出现明显退步时先修正并复测。
5. 应用前备份当前 `rime_frost.custom.yaml` 和同名扩展词库，核对从准备到应用期间用户配置没有变化。先放入词库，再原子替换补丁。保留其他补丁键和 `*.userdb`。通过 Fcitx5 的 RIME 菜单选择「重新部署」，也可在目标桌面的用户 D-Bus 会话调用同一入口：

   ```sh
   busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 \
     SetConfig sv fcitx://config/addon/rime/deploy 'a{sv}' 0
   ```

6. 等待部署完成后检查生效的编译配置和桌面实际候选。部署后若不能正常输入或旧词库绑定发生变化，先恢复已备份的补丁及本次替换的词库，再重新部署并复查。交付时报告两份词库各自的新增数量、验证范围和备份位置。原始下载、个人词库和运行记录保存在目标机器的私有目录。
