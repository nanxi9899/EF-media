#!/bin/bash
# 自研 SPK 打包脚本（遵循 Synology DSM 7 官方规范，不依赖任何第三方仓库配方）
# 用法: build_spk.sh <app: jellyfin|emby> <version> <src_payload_dir> <port> <out_spk>
#   src_payload_dir 是已解包好的应用主体，脚本会把它放到 package.tgz 的 program/ 下
set -e

APP="$1"       # jellyfin | emby
VERSION="$2"
SRC="$3"       # 应用主体源目录（内容会被复制为 target/program/）
PORT="$4"
OUT="$5"
PROCPATH="${6:-}"   # 进程清理匹配路径（可选），默认 program/<pkg>

ART=/root/.codebuddy/artifact/2f8a7d30-9c21-4f0b-1d77-0a8f8d5eb000
ICONS=$ART/spk_icons

case "$APP" in
  jellyfin)
    PKG="jellyfin"
    DISPLAY="Jellyfin"
    DESC="Jellyfin 是一款免费开源的媒体服务器，可整理、管理和流式播放您的电影、电视剧与音乐。"
    MAINTAINER="Jellyfin Contributors"
    MAINTAINER_URL="https://jellyfin.org"
    APPTYPE="jellyfin"
    ;;
  emby)
    PKG="emby"
    DISPLAY="Emby"
    DESC="Emby Server 是一款媒体服务器，可整理、管理并将媒体内容流式传输到各种终端设备。"
    MAINTAINER="Emby LLC"
    MAINTAINER_URL="https://emby.media"
    APPTYPE="emby"
    ;;
  *) echo "unknown app: $APP"; exit 1;;
esac

ROOT=$ART/spk_build/${APP}_${VERSION}
rm -rf "$ROOT"
mkdir -p "$ROOT/scripts" "$ROOT/conf" "$ROOT/package"
PKGDIR="$ROOT/package"

###############################################################################
# 1. 组装 package.tgz 的负载（安装后位于 /var/packages/<pkg>/target）
###############################################################################
mkdir -p "$PKGDIR/program"
cp -a "$SRC"/. "$PKGDIR/program/"
# 清理常见垃圾文件
find "$PKGDIR" \( -name '.DS_Store' -o -name 'Thumbs.db' \) -delete 2>/dev/null || true

# UI 桌面入口（DSM 的 dsmuidir）
mkdir -p "$PKGDIR/ui/images"
cp "$ICONS/${APP}_64.png"  "$PKGDIR/ui/images/${PKG}_64.png"
cp "$ICONS/${APP}_256.png" "$PKGDIR/ui/images/${PKG}_256.png"
cat > "$PKGDIR/ui/config" <<'UICEOF'
{
    ".url": {
        "SYNO.SDS.%PKG%.Application": {
            "title": "%DISPLAY%",
            "desc": "%DISPLAY% Media Server",
            "icon": "images/{0}.png",
            "type": "url",
            "port": "%PORT%",
            "protocol": "http",
            "url": "/",
            "allUsers": true
        }
    }
}
UICEOF
# 用变量替换占位符（用 python 避免 sed 特殊字符问题）
python3 - "$PKGDIR/ui/config" "$PKG" "$DISPLAY" "$PORT" <<'PY'
import sys
p,pkg,disp,port=sys.argv[1:5]
s=open(p).read().replace('%PKG%',pkg).replace('%DISPLAY%',disp).replace('%PORT%',port)
open(p,'w').write(s)
PY

###############################################################################
# 2. 启动包装脚本（安装后位于 target/bin/）
###############################################################################
mkdir -p "$PKGDIR/bin"
if [ "$APPTYPE" = "jellyfin" ]; then
cat > "$PKGDIR/bin/jellyfin-server" <<'BINEOF'
#!/bin/sh
# Jellyfin 启动包装：所有数据落入 DSM 为该套件分配的 var 目录，升级不丢失
TARGET="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$SYNOPKG_PKGVAR"
[ -z "$DATA" ] && DATA="$TARGET/var"
export JELLYFIN_DATA_DIR="$DATA/data"
export JELLYFIN_CONFIG_DIR="$DATA/config"
export JELLYFIN_CACHE_DIR="$DATA/cache"
export JELLYFIN_LOG_DIR="$DATA/log"
export JELLYFIN_WEB_DIR="$TARGET/program/jellyfin-web"
export XDG_CACHE_HOME="$JELLYFIN_CACHE_DIR"
FFDIR="$TARGET/program/jellyfin-ffmpeg"
# ffmpeg 便携版若存在则启用
if [ -x "$FFDIR/ffmpeg" ]; then
  export LD_LIBRARY_PATH="$FFDIR:$FFDIR/lib:${LD_LIBRARY_PATH:-}"
  FFMPEG_ARG="--ffmpeg=$FFDIR/ffmpeg"
else
  FFMPEG_ARG=""
fi
mkdir -p "$JELLYFIN_DATA_DIR" "$JELLYFIN_CONFIG_DIR" "$JELLYFIN_CACHE_DIR" "$JELLYFIN_LOG_DIR"
# 首次运行写入固定端口的 network.xml（避免随机端口，便于 DSM UI 直达）
NETWORK_XML="$JELLYFIN_CONFIG_DIR/network.xml"
if [ ! -f "$NETWORK_XML" ]; then
cat > "$NETWORK_XML" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <InternalHttpPort>PORTPLACEHOLDER</InternalHttpPort>
  <PublicHttpPort>PORTPLACEHOLDER</PublicHttpPort>
  <EnableHttps>false</EnableHttps>
</NetworkConfiguration>
XML
sed -i "s/PORTPLACEHOLDER/$SYNOPKG_PORT/g" "$NETWORK_XML" 2>/dev/null || true
fi
cd "$TARGET/program" || exit 1
exec "$TARGET/program/jellyfin" \
  --datadir "$JELLYFIN_DATA_DIR" \
  --configdir "$JELLYFIN_CONFIG_DIR" \
  --cachedir "$JELLYFIN_CACHE_DIR" \
  --logdir "$JELLYFIN_LOG_DIR" \
  --webdir "$JELLYFIN_WEB_DIR" \
  --package-name synology \
  $FFMPEG_ARG
BINEOF
# 端口写死进 wrapper（network.xml 的占位符）
python3 - "$PKGDIR/bin/jellyfin-server" "$PORT" <<'PY'
import sys
p,port=sys.argv[1:3]
s=open(p).read()
s=s.replace('sed -i "s/PORTPLACEHOLDER/$SYNOPKG_PORT/g" "$NETWORK_XML" 2>/dev/null || true',
            f'sed -i "s/PORTPLACEHOLDER/{port}/g" "$NETWORK_XML"')
open(p,'w').write(s)
PY
else
cat > "$PKGDIR/bin/emby-server" <<'BINEOF'
#!/bin/sh
# Emby 启动包装：所有数据落入 DSM 为该套件分配的 var 目录，升级不丢失
TARGET="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$SYNOPKG_PKGVAR"
[ -z "$DATA" ] && DATA="$TARGET/var"
APP="$TARGET/program"
PID_FILE="$DATA/emby.pid"
[ -f "$APP/share/libdrm/amdgpu.ids" ] && export AMDGPU_IDS_PATH="$APP/share/libdrm/amdgpu.ids"
[ -z "$EMBY_DATA" ] && export EMBY_DATA="$DATA"
export FONTCONFIG_PATH="$APP/etc/fonts"
export LD_LIBRARY_PATH="$APP/lib"
[ -d "$APP/lib/dri" ] && export LIBVA_DRIVERS_PATH="$APP/lib/dri"
[ -d "$APP/etc/OpenCL/vendors" ] && export OCL_ICD_VENDORS="$APP/etc/OpenCL/vendors"
export PATH="$APP/bin:$PATH"
export PCI_IDS_PATH="$APP/share/hwdata/pci.ids"
export SSL_CERT_FILE="$APP/etc/ssl/certs/ca-certificates.crt"
export XDG_CACHE_HOME="$EMBY_DATA/cache"
export NEOReadDebugKeys=1
export OverrideGpuAddressSpace=48
mkdir -p "$EMBY_DATA"
cd "$APP" || exit 1
exec "$APP/system/EmbyServer" \
  -programdata "$EMBY_DATA" \
  -ffdetect "$APP/bin/ffdetect" \
  -ffmpeg "$APP/bin/ffmpeg" \
  -ffprobe "$APP/bin/ffprobe" \
  -restartexitcode 3 \
  -nolocalportconfig \
  -ignore_vaapi_enabled_flag \
  -pidfile "$PID_FILE"
BINEOF
fi
chmod +x "$PKGDIR/bin/"* 2>/dev/null || true
# 保证 program 内可执行文件有执行位（jellyfin、ffmpeg 等）
find "$PKGDIR/program" -maxdepth 2 -type f \( -name jellyfin -o -name createdump -o -name ffmpeg -o -name ffprobe -o -name ffdetect -o -name EmbyServer -o -name 'jellyfin-ffmpeg' \) -exec chmod +x {} \; 2>/dev/null || true
chmod +x "$PKGDIR/program/jellyfin" 2>/dev/null || true
chmod +x "$PKGDIR/program/system/EmbyServer" 2>/dev/null || true

###############################################################################
# 3. scripts：DSM 生命周期脚本（自研）
###############################################################################
PIDFILE_NAME="${PKG}.pid"
DAEMON_NAME="${PKG}"

cat > "$ROOT/scripts/start-stop-status" <<'SSEOF'
#!/bin/sh
# DSM 7 服务生命周期核心脚本：start | stop | status | restart | log
PKG_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
# 安装后 scripts 位于 /var/packages/<pkg>/scripts，实际负载在 /var/packages/<pkg>/target
SYNOPKG_PKGDEST="${SYNOPKG_PKGDEST:-$(dirname "$PKG_DIR")/target}"
SYNOPKG_PKGVAR="${SYNOPKG_PKGVAR:-$(dirname "$PKG_DIR")/var}"
DATA="$SYNOPKG_PKGVAR"
PID_FILE="$DATA/PIDNAME"
LOG_FILE="$DATA/DAEMONNAME.log"
RUNNER="$SYNOPKG_PKGDEST/bin/DAEMONRUNNER"

start_daemon() {
    mkdir -p "$DATA"
    touch "$LOG_FILE"
    cd "$SYNOPKG_PKGDEST" || exit 1
    "$RUNNER" "$DATA" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 3
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        return 0
    fi
    return 1
}
stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        kill -TERM "$PID" 2>/dev/null
        sleep 3
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    # 兜底清理残留进程
    pkill -f "$SYNOPKG_PKGDEST/PROCPATH" 2>/dev/null || true
    return 0
}
status_daemon() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        return 0
    fi
    return 3
}

case "$1" in
    start)
        if status_daemon; then echo "$DAEMON_NAME is already running"; exit 0; fi
        start_daemon && exit 0 || { echo "Failed to start $DAEMON_NAME, see $LOG_FILE"; exit 1; }
        ;;
    stop)
        stop_daemon; exit 0 ;;
    status)
        if status_daemon; then echo "$DAEMON_NAME is running"; exit 0; else echo "$DAEMON_NAME is not running"; exit 3; fi ;;
    restart)
        stop_daemon; sleep 1; start_daemon && exit 0 || exit 1 ;;
    log)
        LINES="${2:-100}"; [ -f "$LOG_FILE" ] && tail -n "$LINES" "$LOG_FILE" || echo "no log"; exit 0 ;;
    *) echo "Usage: $0 {start|stop|status|restart|log}"; exit 1 ;;
esac
SSEOF
if [ -z "$PROCPATH" ]; then
  if [ "$APPTYPE" = "jellyfin" ]; then PROCPATH="program/jellyfin"; else PROCPATH="program/system/EmbyServer"; fi
fi
python3 - "$ROOT/scripts/start-stop-status" "$PIDFILE_NAME" "$DAEMON_NAME" "$PKG-server" "$PROCPATH" <<'PY'
import sys
p,pid,daemon,runner,procpath=sys.argv[1:6]
s=open(p).read().replace('PIDNAME',pid).replace('DAEMONNAME',daemon).replace('DAEMONRUNNER',runner).replace('PROCPATH',procpath)
open(p,'w').write(s)
PY

# preinst：DSM 7 由套件框架以 package 用户运行，这里只做目录准备
cat > "$ROOT/scripts/preinst" <<EOF
#!/bin/sh
set -e
echo "Pre-install $DISPLAY $VERSION"
exit 0
EOF

# postinst：初始化持久目录并修正权限
cat > "$ROOT/scripts/postinst" <<EOF
#!/bin/sh
set -e
echo "Post-install $DISPLAY $VERSION"
mkdir -p "\$SYNOPKG_PKGVAR/data" "\$SYNOPKG_PKGVAR/config" "\$SYNOPKG_PKGVAR/cache" "\$SYNOPKG_PKGVAR/log"
chown -R "\$SYNOPKG_PKGUSER:\$SYNOPKG_PKGGROUP" "\$SYNOPKG_PKGVAR" 2>/dev/null || true
exit 0
EOF

cat > "$ROOT/scripts/preuninst" <<'EOF'
#!/bin/sh
set -e
echo "Pre-uninstall: stopping service"
exit 0
EOF

cat > "$ROOT/scripts/postuninst" <<'EOF'
#!/bin/sh
set -e
echo "Post-uninstall: data in var/ is preserved by default"
exit 0
EOF

cat > "$ROOT/scripts/preupgrade" <<'EOF'
#!/bin/sh
set -e
echo "Pre-upgrade"
exit 0
EOF

cat > "$ROOT/scripts/postupgrade" <<'EOF'
#!/bin/sh
set -e
echo "Post-upgrade: var/ data preserved"
exit 0
EOF

chmod +x "$ROOT/scripts/"*

###############################################################################
# 4. conf：privilege + resource（DSM 7 强制 package 用户运行）
###############################################################################
cat > "$ROOT/conf/privilege" <<EOF
{
    "defaults": { "run-as": "package" },
    "username": "$PKG",
    "groupname": "users",
    "ctrl-script": [
        { "action": "start", "run-as": "package" },
        { "action": "stop", "run-as": "package" },
        { "action": "status", "run-as": "package" }
    ]
}
EOF

cat > "$ROOT/conf/resource" <<EOF
{
    "port-config": [
        { "protocol-file": "$PKG.sc" }
    ]
}
EOF

cat > "$ROOT/$PKG.sc" <<EOF
[$PKG]
title="$DISPLAY"
desc="$DISPLAY Web UI"
port_forward="yes"
src.ports="$PORT/tcp"
dst.ports="$PORT/tcp"
EOF

###############################################################################
# 5. INFO（DSM 7 必需字段）
###############################################################################
cat > "$ROOT/INFO" <<EOF
package="$PKG"
version="$VERSION"
displayname="$DISPLAY"
description="$DESC"
maintainer="$MAINTAINER"
maintainer_url="$MAINTAINER_URL"
distributor="nanxi9899"
distributor_url="https://github.com/nanxi9899"
arch="x86_64"
os_min_ver="7.0-40000"
thirdparty="yes"
startable="yes"
support_conf_folder="yes"
silent_install="yes"
silent_uninstall="yes"
silent_upgrade="yes"
dsmuidir="ui"
dsmappname="SYNO.SDS.$PKG.Application"
adminport="$PORT"
adminprotocol="http"
adminurl="/"
EOF

# 图标
cp "$ICONS/${APP}_64.png"  "$ROOT/PACKAGE_ICON.PNG"
cp "$ICONS/${APP}_256.png" "$ROOT/PACKAGE_ICON_256.PNG"

###############################################################################
# 6. 打包 package.tgz -> 计算 checksum -> 生成最终 .spk
###############################################################################
cd "$PKGDIR"
tar -czf "$ROOT/package.tgz" .
cd "$ROOT"
MD5=$(md5sum package.tgz | awk '{print $1}')
# 将 checksum 写回 INFO（Synology 可选字段，增强完整性校验）
echo "checksum=\"$MD5\"" >> INFO

# spk 就是 tar 包；按官方顺序打包
cd "$ROOT"
tar -cf "$OUT" INFO PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG package.tgz scripts conf "$PKG.sc"

echo "BUILT: $OUT"
ls -lh "$OUT"
