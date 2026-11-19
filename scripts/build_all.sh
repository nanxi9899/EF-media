#!/bin/bash
# 统一构建入口：下载官方二进制 -> 组装 payload -> 调用三平台自研脚本 -> 产出 12 个套件
# 上游更新触发时由 GitHub Actions 调用；也可本地运行。
# 用法:
#   build_all.sh [版本配置文件 versions.json]
# 环境变量:
#   WORKDIR   临时工作目录（默认 /tmp/fnos-build）
#   OUTDIR    产物输出目录（默认 <repo>/dist）
#   FNPACK    fnpack 工具路径（默认下载到 $WORKDIR/fnpack）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS_FILE="${1:-$REPO_ROOT/versions.json}"
WORKDIR="${WORKDIR:-/tmp/fnos-build}"
OUTDIR="${OUTDIR:-$REPO_ROOT/dist}"
FNPACK="${FNPACK:-$WORKDIR/fnpack}"
DL="$WORKDIR/dl"
PAYLOAD="$WORKDIR/payload"

log(){ echo "[build_all] $*"; }
die(){ echo "[build_all] ERROR: $*" >&2; exit 1; }

mkdir -p "$WORKDIR" "$DL" "$PAYLOAD" "$OUTDIR"

# ---------- 工具准备 ----------
command -v jq >/dev/null || die "缺少 jq"
command -v curl >/dev/null || die "缺少 curl"
command -v tar >/dev/null || die "缺少 tar"
command -v ar >/dev/null || die "缺少 ar (binutils)"

if [ ! -x "$FNPACK" ]; then
  log "下载 fnpack 工具..."
  curl -fL --retry 3 --connect-timeout 20 -o "$FNPACK" \
    "https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-amd64"
  chmod +x "$FNPACK"
fi

# ---------- 读取版本 ----------
JF_STABLE=$(jq -r '.jellyfin_stable // empty' "$VERSIONS_FILE")
JF_TEST=$(jq -r '.jellyfin_test // empty' "$VERSIONS_FILE")
EMBY_STABLE=$(jq -r '.emby_stable // empty' "$VERSIONS_FILE")
EMBY_TEST=$(jq -r '.emby_test // empty' "$VERSIONS_FILE")
log "版本: JF稳定=$JF_STABLE JF测试=$JF_TEST Emby稳定=$EMBY_STABLE Emby测试=$EMBY_TEST"

# Jellyfin 测试版带 -unstable 后缀时，下载用纯数字版本
jf_dl_ver(){ echo "${1%-unstable}"; }

# ---------- 下载 Jellyfin ----------
# 尝试多个候选 URL，返回第一个可用的
fetch_jf_tarball(){
  local ver="$1" channel="$2" out="$3" url
  local vclean; vclean=$(jf_dl_ver "$ver")
  for url in \
    "https://repo.jellyfin.org/files/server/linux/${channel}/amd64/jellyfin_${vclean}-amd64.tar.gz" \
    "https://repo.jellyfin.org/files/server/linux/${channel}/v${vclean}/amd64/jellyfin_${vclean}-amd64.tar.gz"; do
    log "尝试下载: $url"
    if curl -fL --retry 2 --connect-timeout 20 -o "$out" "$url"; then
      log "下载成功: $out ($(du -h "$out" | cut -f1))"
      return 0
    fi
  done
  return 1
}

fetch_ffmpeg(){
  local out="$1" url
  # 优先从 latest 目录列表动态取最新版本文件名
  local listing
  listing=$(curl -fsL --connect-timeout 20 "https://repo.jellyfin.org/files/ffmpeg/linux/7.x/" 2>/dev/null || true)
  local fname
  fname=$(echo "$listing" | grep -oE 'jellyfin-ffmpeg_[0-9][^"/]*_portable_linux64-gpl\.tar\.xz' | sort -u | tail -1)
  if [ -n "$fname" ]; then
    # 再探测版本目录
    local verdir
    verdir=$(echo "$fname" | sed -E 's/jellyfin-ffmpeg_([0-9][^-]*_portable).*/\1/' | sed 's/_portable//')
    for url in \
      "https://repo.jellyfin.org/files/ffmpeg/linux/7.x/latest/amd64/$fname" \
      "https://repo.jellyfin.org/files/ffmpeg/linux/7.x/$verdir/amd64/$fname" \
      "https://sgp1.mirror.jellyfin.org/files/ffmpeg/linux/7.x/$verdir/amd64/$fname"; do
      if curl -fL --retry 2 --connect-timeout 20 -o "$out" "$url"; then
        log "ffmpeg 下载成功: $out ($(du -h "$out" | cut -f1))"
        return 0
      fi
    done
  fi
  return 1
}

# 组装 Jellyfin payload：解包 server tarball + 放入 jellyfin-web + jellyfin-ffmpeg
build_jf_payload(){
  local tag="$1" ver="$2" channel="$3" dest="$PAYLOAD/$tag"
  local tgz="$DL/jf_${tag}.tar.gz" ffxz="$DL/ffmpeg_${tag}.tar.xz"
  rm -rf "$dest" "$DL/jf_extract_${tag}" "$DL/ffmpeg_extract_${tag}"
  mkdir -p "$dest"
  fetch_jf_tarball "$ver" "$channel" "$tgz" || die "Jellyfin $ver 下载失败"
  [ -f "$DL/ffmpeg.tar.xz" ] || fetch_ffmpeg "$DL/ffmpeg.tar.xz" || die "ffmpeg 下载失败"
  cp "$DL/ffmpeg.tar.xz" "$ffxz"
  log "解包 Jellyfin $ver ..."
  tar -xzf "$tgz" -C "$DL"
  mkdir -p "$DL/ffmpeg_extract_${tag}"
  tar -xf "$ffxz" -C "$DL/ffmpeg_extract_${tag}"
  cp -a "$DL/jellyfin"/. "$dest"/
  local ffmpeg_bin ffmpeg_src
  ffmpeg_bin=$(find "$DL/ffmpeg_extract_${tag}" -name ffmpeg -type f -print -quit)
  [ -n "$ffmpeg_bin" ] || die "ffmpeg 二进制未找到"
  ffmpeg_src=$(dirname "$ffmpeg_bin")
  cp -a "$ffmpeg_src" "$dest/jellyfin-ffmpeg"
  chmod +x "$dest/jellyfin-ffmpeg/ffmpeg" 2>/dev/null || true
  chmod +x "$dest/jellyfin-ffmpeg/ffprobe" 2>/dev/null || true
  chmod +x "$dest/jellyfin" 2>/dev/null || true
  log "Jellyfin payload 就绪: $dest ($(du -sh "$dest" | cut -f1))"
}

# ---------- 下载 Emby ----------
build_emby_payload(){
  local tag="$1" ver="$2" beta="$3" dest="$PAYLOAD/$tag"
  local deb="$DL/emby_${tag}.deb"
  # beta 版本号可能带 -beta 后缀；deb 文件名用纯数字，release tag 兼容带/不带 -beta 两种
  local vclean="${ver%-beta}"
  rm -rf "$dest" "$DL/emby_ex_${tag}"
  mkdir -p "$dest"
  local url ok=false
  for url in \
    "https://github.com/MediaBrowser/Emby.Releases/releases/download/${vclean}/emby-server-deb_${vclean}_amd64.deb" \
    "https://github.com/MediaBrowser/Emby.Releases/releases/download/${ver}/emby-server-deb_${vclean}_amd64.deb"; do
    log "尝试下载 Emby: $url"
    if curl -fL --retry 2 --connect-timeout 20 -o "$deb" "$url"; then ok=true; break; fi
  done
  $ok || die "Emby $ver 下载失败"
  log "解包 Emby deb ..."
  mkdir -p "$DL/emby_ex_${tag}"
  (cd "$DL/emby_ex_${tag}" && ar -x "$deb" && tar -xf data.tar.xz)
  local src="$DL/emby_ex_${tag}/opt/emby-server"
  [ -d "$src" ] || die "deb 结构异常: 未找到 opt/emby-server"
  cp -a "$src"/bin "$src"/etc "$src"/lib "$src"/licenses "$src"/share "$src"/system "$dest"/
  chmod +x "$dest/system/EmbyServer" 2>/dev/null || true
  log "Emby payload 就绪: $dest ($(du -sh "$dest" | cut -f1))"
}

# ---------- 打包三平台 ----------
pack_one(){
  local app="$1" ver="$2" payload="$3" port="$4" beta="$5" prefix="$6"
  local out
  log "打包 $prefix $ver -> fpk/spk/tpk"
  out="$OUTDIR/${prefix}_${ver}_x86.fpk"
  "$REPO_ROOT/fpk/build_fpk.sh" "$app" "$ver" "$payload" "$port" "$beta" "$out"
  out="$OUTDIR/${prefix}_${ver}_x86.spk"
  "$REPO_ROOT/spk/build_spk.sh" "$app" "$ver" "$payload" "$port" "$out"
  out="$OUTDIR/${prefix}_${ver}_x86.tpk"
  if [ "$app" = jellyfin ]; then
    "$REPO_ROOT/tpk/build_jellyfin_tpk.sh" "Jellyfin" "$ver" "$payload" "$out" "$beta"
  else
    "$REPO_ROOT/tpk/build_emby_tpk.sh" "EmbyServer" "$ver" "$payload" "$out" "$beta"
  fi
}

log "========== 构建 12 个套件 =========="
# Jellyfin 正式版
[ -n "$JF_STABLE" ] && {
  build_jf_payload jf_stable "$JF_STABLE" latest-stable
  pack_one jellyfin "$JF_STABLE" "$PAYLOAD/jf_stable" 8097 false jellyfin
}
# Jellyfin 测试版
[ -n "$JF_TEST" ] && {
  build_jf_payload jf_test "$JF_TEST" latest-unstable
  pack_one jellyfin "$JF_TEST" "$PAYLOAD/jf_test" 8097 true jellyfin
}
# Emby 正式版
[ -n "$EMBY_STABLE" ] && {
  build_emby_payload emby_stable "$EMBY_STABLE" false
  pack_one emby "$EMBY_STABLE" "$PAYLOAD/emby_stable" 8096 false emby
}
# Emby 测试版
[ -n "$EMBY_TEST" ] && {
  build_emby_payload emby_test "$EMBY_TEST" true
  pack_one emby "$EMBY_TEST" "$PAYLOAD/emby_test" 8096 true emby
}

log "========== 完成，产物在 $OUTDIR =========="
ls -lh "$OUTDIR"/*.fpk "$OUTDIR"/*.spk "$OUTDIR"/*.tpk 2>/dev/null || true
