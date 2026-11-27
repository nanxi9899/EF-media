# EF-media

飞牛 fnOS / 群晖 DSM 7.4 / 铁威马 TOS 7.0 三平台媒体服务器套件，x86_64 架构。

> **下载现成套件**：请到 [Releases](https://github.com/nanxi9899/EF-media/releases) 页面下载 `.fpk` / `.spk` / `.tpk` 附件（单文件较大，故以 Release 附件形式提供，而非提交进仓库）。云端自动编译工作流见 `.github/workflows/`（需要带 `workflow` scope 的 token 推送）。

目前提供 **Jellyfin 正式版**、**Emby 正式版** 与 **Emby 最新测试版**，共 3 个版本 × 3 个平台 = 9 个套件包。

## 版本

| 软件 | 正式版 | 测试版 |
|------|--------|--------|
| Jellyfin | 12.4 | — |
| Emby | 4.10.2.0 | 4.11.0.19 (beta) |

> Emby Server 为闭源软件，官方只提供编译好的二进制（无服务端源码）；Jellyfin 虽开源，但标准做法同样是使用官方编译包。因此本项目是把**官方 x86_64 二进制**按各 NAS 平台的套件规范重新封装，而非从源码编译——源码编译在这两个项目上都不可行或无意义。

## 目录结构

```
.
├── assets/icons/    # 套件图标（各平台打包时复用）
├── scripts/
│   └── build_all.sh       # 统一入口：下载官方二进制→组装payload→打包12个套件
├── fpk/          # 飞牛 fnOS 套件（fnpack 官方工具打包）
│   └── build_fpk.sh
├── spk/          # 群晖 DSM 7.4 套件
│   └── build_spk.sh       # 自研：INFO / scripts / conf / privilege
├── tpk/          # 铁威马 TOS 7.0 套件
│   ├── build_tpk.py       # 自研：JSON头 + lang + XZ tar 三段式封装
│   ├── build_emby_tpk.sh
│   └── build_jellyfin_tpk.sh
├── .github/workflows/sync-upstream.yml   # 定时检查上游，有新版本就云端重新打包并发布
└── versions.json     # 记录已打包版本，供同步工作流比对
```

## 云端自动编译

`.github/workflows/sync-upstream.yml` 实现了完整的「同步上游 → 自动打包 → 发布 Release」流水线：

1. **触发**：每天定时（北京时间 02:00）+ 手动 `workflow_dispatch`。
2. **探测**：读取 Jellyfin 官方 repo 目录与 Emby Releases API，取最新正式版 / 测试版。
3. **比对**：与 `versions.json` 对比，无更新则跳过；有更新才构建。
4. **构建**：`scripts/build_all.sh` 下载官方 x86_64 二进制，解包组装 payload，调用三平台自研脚本产出 12 个套件。
5. **校验 + 发布**：校验 spk checksum / tpk md5 / 数量（必须 12 个），通过后用内置 `GITHUB_TOKEN` 覆盖发布到 `v1.0` Release，并回写 `versions.json`。

> 首次推送 `.github/workflows/` 下的文件需要带 `workflow` scope 的 classic token；此后工作流运行时用仓库内置的 `GITHUB_TOKEN` 即可发布 Release，无需额外密钥。也可在 Actions 页面手动点「Run workflow」立即触发一次。

## 打包方式（全部自研脚本，不依赖第三方仓库的成品包）

- **fpk**：飞牛官方 `fnpack v1.2.3` 工具 + 自写 manifest / 生命周期脚本 / 权限资源 / UI 入口。
- **spk**：遵循 Synology DSM 7 官方规范，自写 INFO（含 checksum）、7 个生命周期脚本、`conf/privilege`（run-as package）、端口配置、UI 入口。
- **tpk**：遵循 TOS tpk 公开格式（JSON 头 + 本地化 + XZ 压缩 TAR），自写 Python 打包器与服务脚本。

数据目录均落在各平台的持久目录，升级套件不会丢失媒体库配置。

## 安装

- **飞牛**：应用中心 → 手动安装 → 选择 `.fpk`；或 `sudo appcenter-cli install-fpk <文件>`。
- **群晖**：套件中心 → 手动安装 → 选择 `.spk`。若因签名提示，需在设置中允许「任何来源」。
- **铁威马**：应用中心 → 手动安装 → 选择 `.tpk`。注意 TOS 7 官方已关闭 tpk 的新上架通道，但**仍支持本地侧载安装**。

## 端口

- Jellyfin：8097
- Emby：8096

## 校验状态

所有包已通过：二进制架构确认（ELF x86-64）、压缩包完整性、清单/配置文件校验、脚本语法检查。

**限制**：构建在无真实 NAS 设备的沙箱中完成，仅做了结构与静态校验，未在真机实际安装运行。若启动异常，请提供日志；另外 TOS 7 更推荐 Docker/deb 方案，tpk 属于历史格式侧载。
