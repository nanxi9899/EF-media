#!/bin/bash
# 自研 Jellyfin TOS tpk 构建脚本（与 build_emby_tpk.sh 对称）
# 用法: build_jellyfin_tpk.sh <ID> <VERSION> <PAY> <OUT> <BETA>
set -e
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
WORKDIR="${WORKDIR:-/tmp/fnos-build}"
TPKSRC=$WORKDIR/tpk_src
ID="$1"; VERSION="$2"; PAY="$3"; OUT="$4"; BETA="$5"
D=$TPKSRC/$ID
rm -rf "$D" && mkdir -p "$D/bin/program" "$D/images/icons" "$D/init.d" "$D/functions" "$D/sysroot/usr/local/bin" "$D/sysroot/var/lib" "$D/update"
cp -a "$PAY"/. "$D/bin/program/"
find "$D" \( -name '.DS_Store' -o -name 'Thumbs.db' \) -delete 2>/dev/null || true
cp "$REPO_ROOT/assets/icons/jellyfin_256.png" "$D/images/icons/icon.png"

cat > "$D/config.ini" <<EOF
{
  "id": "$ID",
  "md5": "",
  "path": "/$ID/",
  "icon": "/images/icons/icon.png",
  "name": "",
  "publisher": "nanxi9899",
  "exec": true,
  "user": "",
  "group": "",
  "open_path": false,
  "resize": true,
  "state": false,
  "type": "iframe",
  "help": "https://github.com/nanxi9899/fnos-media-fpk",
  "version": "$VERSION",
  "recommend": false,
  "relation": ["", ""],
  "release_note": "",
  "beta": $BETA,
  "category": "Multimedia",
  "depend": [],
  "platform": "x86_64",
  "low_version": "7.0",
  "reset": false,
  "official": "/$ID/",
  "maxmin": true
}
EOF

cat > "$D/$ID.lang" <<'EOF'
[chs]
name = "Jellyfin"
auth = "Jellyfin Contributors"
descript = "Jellyfin 是一款免费开源的媒体服务器，可管理并流式播放电影、电视剧与音乐。"

[en-us]
name = "Jellyfin"
auth = "Jellyfin Contributors"
descript = "Jellyfin is a free and open-source media server for managing and streaming your media."
EOF
echo "$VERSION" > "$D/version"

# Jellyfin 启动器：数据落在应用 config 目录（升级保留），固定端口 8097
cat > "$D/bin/program/launcher" <<'EOF'
#!/bin/sh
ROOT="$(cd "$(dirname "$0")" && pwd)"
DATA="${SYNOPKG_PKGVAR:-$ROOT/../config}"
[ -d "$ROOT/../config" ] && DATA="$ROOT/../config"
mkdir -p "$DATA/data" "$DATA/config" "$DATA/cache" "$DATA/log"
export JELLYFIN_DATA_DIR="$DATA/data"
export JELLYFIN_CONFIG_DIR="$DATA/config"
export JELLYFIN_CACHE_DIR="$DATA/cache"
export JELLYFIN_LOG_DIR="$DATA/log"
export JELLYFIN_WEB_DIR="$ROOT/jellyfin-web"
export XDG_CACHE_HOME="$JELLYFIN_CACHE_DIR"
FFDIR="$ROOT/jellyfin-ffmpeg"
[ -x "$FFDIR/ffmpeg" ] && export LD_LIBRARY_PATH="$FFDIR:$FFDIR/lib:${LD_LIBRARY_PATH:-}" && FFMPEG_ARG="--ffmpeg=$FFDIR/ffmpeg" || FFMPEG_ARG=""
NET="$JELLYFIN_CONFIG_DIR/network.xml"
if [ ! -f "$NET" ]; then
cat > "$NET" <<XML
<?xml version="1.0" encoding="utf-8"?>
<NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <InternalHttpPort>8097</InternalHttpPort><PublicHttpPort>8097</PublicHttpPort><EnableHttps>false</EnableHttps>
</NetworkConfiguration>
XML
fi
cd "$ROOT" || exit 1
exec "$ROOT/jellyfin" --datadir "$JELLYFIN_DATA_DIR" --configdir "$JELLYFIN_CONFIG_DIR" \
  --cachedir "$JELLYFIN_CACHE_DIR" --logdir "$JELLYFIN_LOG_DIR" --webdir "$JELLYFIN_WEB_DIR" \
  --package-name synology $FFMPEG_ARG
EOF
chmod +x "$D/bin/program/launcher"

cat > "$D/functions/dependapps.sh" <<'EOF'
AddConfigFolder(){
  MODCONFIGHOME="/home/$(id -un)/MOD_CONFIG"
  [ ! -d "$MODCONFIGHOME" ] && mkdir -p "$MODCONFIGHOME"
  [ ! -d /usr/local/@APP_CONFIG ] && mkdir -p /usr/local/@APP_CONFIG
  chmod 755 /usr/local/@APP_CONFIG 2>/dev/null || true
  if ! mount | grep -q '/usr/local/@APP_CONFIG'; then
    mount --bind "$MODCONFIGHOME" /usr/local/@APP_CONFIG 2>/dev/null || true
  fi
}
EOF

cat > "$D/init.d/service" <<EOF
#!/bin/bash
MOD_NAME="$ID"
APP_ROOT="\$(cd "\$(dirname "\$(dirname "\$(readlink -f \$0)")")" && pwd)"
PROGRAM="\$APP_ROOT/bin/program"
DAEMON="\$PROGRAM/launcher"
LOGFILE="\$APP_ROOT/app.log"
PIDFILE="\$APP_ROOT/app.pid"
export depend=()
. "\$APP_ROOT/functions/dependapps.sh"
start(){
  echo "Starting \$MOD_NAME..."
  AddConfigFolder >> "\$LOGFILE" 2>&1
  if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then echo "already running"; return 0; fi
  start-stop-daemon --start --make-pidfile --pidfile "\$PIDFILE" -b \\
    --startas /bin/sh -- -c "exec '\$DAEMON' >> '\$LOGFILE' 2>&1"
  sleep 3
  kill -0 "\$(cat \$PIDFILE 2>/dev/null)" 2>/dev/null && echo OK || echo FAILED
}
stop(){
  echo "Stopping \$MOD_NAME..."
  [ -f "\$PIDFILE" ] && start-stop-daemon --stop --pidfile "\$PIDFILE" --oknodo --retry 10
  rm -f "\$PIDFILE"; pkill -f "\$PROGRAM/jellyfin" 2>/dev/null || true
}
status(){ if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then echo running; else echo stopped; fi; }
case "\$1" in
  start) start;; stop) stop;; status) status;; restart) stop; sleep 1; start;;
  *) echo "Usage: \$0 {start|stop|status|restart}"; exit 1;;
esac
EOF
chmod +x "$D/init.d/service"
printf '#!/bin/sh\nexit 0\n' > "$D/install"; chmod +x "$D/install"

python3 "$REPO_ROOT/tpk/build_tpk.py" --src "$D" --out "$OUT" --app jellyfin --id "$ID" --version "$VERSION" --port 8097 --beta "$BETA"
