#!/bin/bash
set -e
ART=/root/.codebuddy/artifact/2f8a7d30-9c21-4f0b-1d77-0a8f8d5eb000
TPKSRC=$ART/tpk_src
ID="$1"; VERSION="$2"; PAY="$3"; OUT="$4"; BETA="$5"
D=$TPKSRC/$ID
rm -rf "$D" && mkdir -p "$D/bin/program" "$D/images/icons" "$D/init.d" "$D/functions" "$D/update"
cp -a "$PAY"/. "$D/bin/program/"
find "$D" \( -name '.DS_Store' -o -name 'Thumbs.db' \) -delete 2>/dev/null || true
cp "$ART/spk_icons/emby_256.png" "$D/images/icons/icon.png"

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

cat > "$D/$ID.lang" <<EOF
[chs]
name = "Emby"
auth = "Emby LLC"
descript = "Emby Server 是一款媒体服务器，可管理并将媒体内容流式传输到各种终端设备。"

[en-us]
name = "Emby"
auth = "Emby LLC"
descript = "Emby Server is a media server that organizes and streams your media to any device."
EOF
echo "$VERSION" > "$D/version"

# Emby 启动器
cat > "$D/bin/program/launcher" <<'EOF'
#!/bin/sh
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT"
DATA="$ROOT/../config"
mkdir -p "$DATA"
export EMBY_DATA="$DATA"
export FONTCONFIG_PATH="$APP/etc/fonts"
export LD_LIBRARY_PATH="$APP/lib"
[ -d "$APP/lib/dri" ] && export LIBVA_DRIVERS_PATH="$APP/lib/dri"
[ -d "$APP/etc/OpenCL/vendors" ] && export OCL_ICD_VENDORS="$APP/etc/OpenCL/vendors"
export PATH="$APP/bin:$PATH"
export PCI_IDS_PATH="$APP/share/hwdata/pci.ids"
export SSL_CERT_FILE="$APP/etc/ssl/certs/ca-certificates.crt"
export XDG_CACHE_HOME="$DATA/cache"
export NEOReadDebugKeys=1
export OverrideGpuAddressSpace=48
cd "$APP" || exit 1
exec "$APP/system/EmbyServer" \
  -programdata "$DATA" \
  -ffdetect "$APP/bin/ffdetect" \
  -ffmpeg "$APP/bin/ffmpeg" \
  -ffprobe "$APP/bin/ffprobe" \
  -restartexitcode 3 -nolocalportconfig -ignore_vaapi_enabled_flag \
  -pidfile "$DATA/emby.pid"
EOF
chmod +x "$D/bin/program/launcher"

cat > "$D/functions/dependapps.sh" <<'EOF'
# TOS app helper (self-contained)
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
  rm -f "\$PIDFILE"; pkill -f "\$PROGRAM/system/EmbyServer" 2>/dev/null || true
}
status(){ if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then echo running; else echo stopped; fi; }
case "\$1" in
  start) start;; stop) stop;; status) status;; restart) stop; sleep 1; start;;
  *) echo "Usage: \$0 {start|stop|status|restart}"; exit 1;;
esac
EOF
chmod +x "$D/init.d/service"
printf '#!/bin/sh\nexit 0\n' > "$D/install"; chmod +x "$D/install"
mkdir -p "$D/sysroot/usr/local/bin" "$D/sysroot/var/lib" "$D/update"

python3 "$ART/build_tpk.py" --src "$D" --out "$OUT" --app emby --id "$ID" --version "$VERSION" --port 8096 --beta "$BETA"
