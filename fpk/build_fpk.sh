#!/bin/bash
# 自研 FPK 打包脚本（飞牛 fnOS，使用官方 fnpack 工具 + 自写配置）
# 用法: build_fpk.sh <jellyfin|emby> <version> <payload_dir> <port> <beta> <out.fpk>
set -e
# 自包含：仓库根目录由脚本位置推导，工作目录 / fnpack 工具可通过环境变量覆盖
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WORKDIR="${WORKDIR:-/tmp/fnos-build}"
FNPACK="${FNPACK:-$WORKDIR/fnpack}"
APP="$1"; VERSION="$2"; PAY="$3"; PORT="$4"; BETA="$5"; OUT="$6"
ICONS="$REPO_ROOT/assets/icons"
mkdir -p "$WORKDIR"

case "$APP" in
  jellyfin)
    PKG="jellyfin"; DISPLAY="Jellyfin"
    DESC="Jellyfin 是一款免费开源的媒体系统，让您管理和播放媒体内容，支持电影、电视剧、音乐等多种媒体类型的管理与流式传输。"
    MAINTAINER="Jellyfin Contributors"; MAINTAINER_URL="https://jellyfin.org"
    RUNNER="jellyfin-server"; DAEMON="jellyfin"; PROCPAT="program/jellyfin";;
  emby)
    PKG="embyserver"; DISPLAY="Emby"
    DESC="EmbyServer 是一款媒体系统，可让您控制媒体的管理和流式传输，将媒体内容提供给各种终端设备。"
    MAINTAINER="Emby LLC"; MAINTAINER_URL="https://emby.media"
    RUNNER="emby-server"; DAEMON="EmbyServer"; PROCPAT="program/system/EmbyServer";;
  *) echo "unknown"; exit 1;;
esac

ROOT=$WORKDIR/fpk_build/${APP}_${VERSION}
rm -rf "$ROOT" && mkdir -p "$ROOT" && cd "$ROOT"
"$FNPACK" create "$PKG" >/dev/null 2>&1
cd "$PKG"

# manifest
cat > manifest <<EOF
appname               = $PKG
version               = $VERSION
display_name          = $DISPLAY
desc                  = $DESC
platform              = x86
source                = thirdparty
maintainer            = $MAINTAINER
maintainer_url        = $MAINTAINER_URL
distributor           = nanxi9899
distributor_url       = https://github.com/nanxi9899
desktop_uidir         = ui
desktop_applaunchname = $PKG.Application
service_port          = $PORT
EOF

cat > config/privilege <<'EOF'
{
    "defaults": { "run-as": "user" },
    "username": "media",
    "groupname": "users",
    "join-groups": ["video", "render"]
}
EOF
cat > config/resource <<EOF
{
    "port-config": { "protocol-file": "$PKG.sc" },
    "data-share": { "shares": [ { "name": "$PKG", "permission": { "rw": ["media"] } } ] },
    "systemd-unit": {}
}
EOF
cat > "$PKG.sc" <<EOF
[$PKG]
title="$DISPLAY"
desc="$DISPLAY Web UI"
port_forward="yes"
src.ports="$PORT/tcp"
dst.ports="$PORT/tcp"
EOF
cat > app/ui/config <<EOF
{
    ".url": {
        "$PKG.Application": {
            "title": "$DISPLAY", "desc": "$DISPLAY", "icon": "images/{0}.png",
            "type": "url", "port": "$PORT", "protocol": "http", "url": "/", "allUsers": true
        }
    }
}
EOF
rm -f app/ui/images/*.png
cp "$ICONS/${APP}_64.png" app/ui/images/64.png
cp "$ICONS/${APP}_256.png" app/ui/images/256.png
cp "$ICONS/${APP}_64.png" ICON.PNG
cp "$ICONS/${APP}_256.png" ICON_256.PNG

# cmd 生命周期脚本（自研精简版）
cat > cmd/main <<'MAINEOF'
#!/bin/bash
COMMON=$(dirname $0)"/common"; [ -r "${COMMON}" ] && . "${COMMON}"
[ -r "$(dirname $0)/service-setup" ] && . "$(dirname $0)/service-setup"
case $1 in
  start)
    if daemon_status; then echo "already running" >> ${LOG_FILE}; exit 0;
    else echo "Starting ${DNAME} ..." >> ${LOG_FILE}; start_daemon; exit $?; fi ;;
  stop) echo "Stopping ${DNAME} ..." >> ${LOG_FILE}; stop_daemon; exit 0 ;;
  status) if daemon_status; then echo "${DNAME} is running"; exit 0; else echo "${DNAME} is not running"; exit 3; fi ;;
  *) exit 1 ;;
esac
MAINEOF
cat > cmd/common <<'COMMONEOF'
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ -z "${TRIM_PKGVAR:-}" ] && { echo "ERROR: TRIM_PKGVAR unset" >&2; exit 1; }
case "${TRIM_PKGVAR}" in /vol*|/usr/local/apps/@appdata/*) ;; *) echo "ERROR: TRIM_PKGVAR invalid" >&2; exit 1 ;; esac
mkdir -p "${TRIM_PKGVAR}" 2>/dev/null || true
LOG_FILE="${TRIM_PKGVAR}/${TRIM_APPNAME}.log"
PID_FILE="${TRIM_PKGVAR}/${TRIM_APPNAME}.pid"
SVC_WAIT_TIMEOUT=15; SVC_CWD="${TRIM_PKGVAR}"; SVC_BACKGROUND=y; SVC_WRITE_PID=y
DNAME="${TRIM_APPNAME}"; OUT="${LOG_FILE}"
call_func(){ F=$1; if type "${F}" 2>/dev/null | grep -q 'function'; then eval ${F} >> ${LOG_FILE} 2>&1; fi; }
validate_preinst(){ :; }; service_preinst(){ :; }; service_postinst(){ :; }
service_preuninst(){ :; }; service_postuninst(){ :; }; service_preupgrade(){ :; }
service_save(){ :; }; service_restore(){ :; }; service_postupgrade(){ :; }
fix_own(){ if [ -n "${TRIM_USERNAME:-}" ]; then for d in "${TRIM_PKGVAR}" "${TRIM_PKGDEST:-}"; do [ -d "$d" ] && chown -R "${TRIM_USERNAME}:${TRIM_GROUPNAME:-${TRIM_USERNAME}}" "$d" 2>/dev/null || true; done; fi; }
install_init(){ call_func validate_preinst; call_func service_preinst; exit 0; }
install_callback(){ call_func service_postinst; fix_own; exit 0; }
uninstall_init(){ stop_daemon; call_func service_preuninst; exit 0; }
uninstall_callback(){ call_func service_postuninst; exit 0; }
upgrade_init(){ stop_daemon; call_func service_preupgrade; call_func service_save; exit 0; }
upgrade_callback(){ fix_own; call_func service_restore; call_func service_postupgrade; exit 0; }
config_init(){ exit 0; }; config_callback(){ exit 0; }
start_daemon(){
  touch "${LOG_FILE}"; cd ${SVC_CWD} || exit 1
  ${SERVICE_COMMAND} >> ${OUT} 2>&1 &
  echo $! > ${PID_FILE}
  sleep 3
  if daemon_status; then return 0; else echo "ERROR: failed to start, see ${LOG_FILE}" >&2; return 1; fi
}
stop_daemon(){
  if [ -f "${PID_FILE}" ]; then
    for pid in $(cat "${PID_FILE}"); do kill -TERM ${pid} 2>/dev/null; done
    sleep 3
    for pid in $(cat "${PID_FILE}"); do kill -0 ${pid} 2>/dev/null && kill -KILL ${pid} 2>/dev/null; done
    rm -f "${PID_FILE}"
  fi
  pkill -f "${PROCPAT}" 2>/dev/null || true
}
daemon_status(){
  [ -f "${PID_FILE}" ] || return 1
  for pid in $(cat "${PID_FILE}"); do kill -0 ${pid} >/dev/null 2>&1 || { rm -f "${PID_FILE}"; return 1; }; done
  return 0
}
COMMONEOF
cat > cmd/service-setup <<SVC
#!/bin/bash
SERVICE_COMMAND="${TRIM_APPDEST}/bin/${RUNNER} ${TRIM_PKGVAR}"
PROCPAT="${TRIM_APPDEST}/${PROCPAT}"
SVC_BACKGROUND=y; SVC_WRITE_PID=y
SVC
chmod +x cmd/*

# bin 启动包装（复用自研逻辑）
mkdir -p bin app/bin
if [ "$APP" = "jellyfin" ]; then
cat > bin/jellyfin-server <<'BINEOF'
#!/bin/sh
APP_DIR="${TRIM_APPDEST}"; DATA=$1
export JELLYFIN_DATA_DIR="$DATA/data" JELLYFIN_CONFIG_DIR="$DATA/config"
export JELLYFIN_CACHE_DIR="$DATA/cache" JELLYFIN_LOG_DIR="$DATA/log"
export JELLYFIN_WEB_DIR="$APP_DIR/app/jellyfin-web" XDG_CACHE_HOME="$DATA/cache"
FFDIR="$APP_DIR/app/jellyfin-ffmpeg"
[ -x "$FFDIR/ffmpeg" ] && export LD_LIBRARY_PATH="$FFDIR:$FFDIR/lib:${LD_LIBRARY_PATH:-}" && FFMPEG_ARG="--ffmpeg=$FFDIR/ffmpeg" || FFMPEG_ARG=""
mkdir -p "$JELLYFIN_DATA_DIR" "$JELLYFIN_CONFIG_DIR" "$JELLYFIN_CACHE_DIR" "$JELLYFIN_LOG_DIR"
NET="$JELLYFIN_CONFIG_DIR/network.xml"
if [ ! -f "$NET" ]; then
cat > "$NET" <<XML
<?xml version="1.0" encoding="utf-8"?>
<NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <InternalHttpPort>PORT</InternalHttpPort><PublicHttpPort>PORT</PublicHttpPort><EnableHttps>false</EnableHttps>
</NetworkConfiguration>
XML
fi
cd "$APP_DIR/app" || exit 1
exec "$APP_DIR/app/jellyfin" --datadir "$JELLYFIN_DATA_DIR" --configdir "$JELLYFIN_CONFIG_DIR" \
 --cachedir "$JELLYFIN_CACHE_DIR" --logdir "$JELLYFIN_LOG_DIR" --webdir "$JELLYFIN_WEB_DIR" \
 --package-name synology $FFMPEG_ARG
BINEOF
sed -i "s/PORT/$PORT/g" bin/jellyfin-server
else
cat > bin/emby-server <<'BINEOF'
#!/bin/sh
APP_DIR="${TRIM_APPDEST}"; DATA=$1; APP="$APP_DIR/app"
export EMBY_DATA="$DATA" FONTCONFIG_PATH="$APP/etc/fonts" LD_LIBRARY_PATH="$APP/lib"
[ -d "$APP/lib/dri" ] && export LIBVA_DRIVERS_PATH="$APP/lib/dri"
[ -d "$APP/etc/OpenCL/vendors" ] && export OCL_ICD_VENDORS="$APP/etc/OpenCL/vendors"
export PATH="$APP/bin:$PATH" PCI_IDS_PATH="$APP/share/hwdata/pci.ids"
export SSL_CERT_FILE="$APP/etc/ssl/certs/ca-certificates.crt" XDG_CACHE_HOME="$DATA/cache"
export NEOReadDebugKeys=1 OverrideGpuAddressSpace=48
mkdir -p "$DATA"; cd "$APP" || exit 1
exec "$APP/system/EmbyServer" -programdata "$DATA" -ffdetect "$APP/bin/ffdetect" \
 -ffmpeg "$APP/bin/ffmpeg" -ffprobe "$APP/bin/ffprobe" -restartexitcode 3 \
 -nolocalportconfig -ignore_vaapi_enabled_flag -pidfile "$DATA/emby.pid"
BINEOF
fi
chmod +x bin/*

# 填入应用主体到 app/
cp -a "$PAY"/. app/
find app -name '.DS_Store' -delete 2>/dev/null || true
# 把 wrapper 也放进 app/bin（service-setup 引用 appdest/bin，fnpack 会把 bin/ 单独放，这里双份保险）
cp bin/* app/bin/ 2>/dev/null || true
chmod +x app/bin/* 2>/dev/null || true
chmod +x app/jellyfin 2>/dev/null || true
chmod +x app/system/EmbyServer 2>/dev/null || true

echo "=== building fpk: $PKG $VERSION ==="
"$FNPACK" build 2>&1 | tail -5
FPK=$(ls *.fpk | head -1)
mv "$FPK" "$OUT"
echo "BUILT: $OUT"
ls -lh "$OUT"
