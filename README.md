# fnos-media-fpk

飞牛 fnOS / 群晖 DSM 7.4 / 铁威马 TOS 7.0 三平台媒体服务器套件，x86_64 架构。

包含 **Jellyfin** 与 **Emby** 各自的**最新正式版 + 最新测试版**，共 4 个版本 × 3 个平台 = 12 个套件包。

## 版本

| 软件 | 正式版 | 测试版 |
|------|--------|--------|
| Jellyfin | 12.4 | 2026111613 (unstable) |
| Emby | 4.10.2.0 | 4.11.0.13 (beta) |

> Emby Server 为闭源软件，官方只提供编译好的二进制（无服务端源码）；Jellyfin 虽开源，但标准做法同样是使用官方编译包。因此本项目是把**官方 x86_64 二进制**按各 NAS 平台的套件规范重新封装，而非从源码编译——源码编译在这两个项目上都不可行或无意义。

## 目录结构

```
.
├── fpk/          # 飞牛 fnOS 套件（fnpack 官方工具打包）
│   ├── build_fpk.sh
│   └── *.fpk
├── spk/          # 群晖 DSM 7.4 套件
│   ├── build_spk.sh       # 自研：INFO / scripts / conf / privilege
│   └── *.spk
├── tpk/          # 铁威马 TOS 7.0 套件
│   ├── build_tpk.py       # 自研：JSON头 + lang + XZ tar 三段式封装
│   ├── build_emby_tpk.sh
│   └── *.tpk
├── .github/workflows/sync-upstream.yml   # 定时检查上游，有新版本就重新打包
└── versions.json     # 记录已打包版本，供同步工作流比对
```

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
