#!/usr/bin/env bash
# @version 10
set -e
cd "$(dirname "$0")"
SCRIPT_DIR="$PWD"
INSTANCE_DIR="$SCRIPT_DIR"
if [ "$(basename "$SCRIPT_DIR")" = "_updater" ]; then
  INSTANCE_DIR="$(cd .. && pwd)"
fi

printf '\033]0;便携 Minecraft 玩家同步\007'
echo "============================================================"
echo "  便携 Minecraft 玩家同步"
echo "============================================================"
echo "实例目录: $INSTANCE_DIR"
echo

MANIFEST_URLS="${PORTABLE_MANIFEST_URL:-}"
append_manifest_url() {
  local value="$1"
  value="$(printf '%s' "$value" | tr -d '\r\n')"
  [ -z "$value" ] && return 0
  case "$MANIFEST_URLS" in
    *"$value"*) return 0 ;;
  esac
  if [ -z "$MANIFEST_URLS" ]; then
    MANIFEST_URLS="$value"
  else
    MANIFEST_URLS="${MANIFEST_URLS}"$'\x1f'"$value"
  fi
}
if [ -z "$MANIFEST_URLS" ]; then
  for candidate in "$INSTANCE_DIR/UPDATE-URL.txt" "$INSTANCE_DIR/PORTABLE-UPDATE-URL.txt" "$INSTANCE_DIR/TFCR-update-url.txt" "$SCRIPT_DIR/UPDATE-URL.txt" "$SCRIPT_DIR/PORTABLE-UPDATE-URL.txt" "$SCRIPT_DIR/TFCR-update-url.txt"; do
    if [ -f "$candidate" ]; then
      append_manifest_url "$(head -n 1 "$candidate")"
      break
    fi
  done
fi
for candidate in "$INSTANCE_DIR/UPDATE-URL-LAN.txt" "$INSTANCE_DIR/PORTABLE-UPDATE-URL-LAN.txt" "$SCRIPT_DIR/UPDATE-URL-LAN.txt" "$SCRIPT_DIR/PORTABLE-UPDATE-URL-LAN.txt"; do
  if [ -f "$candidate" ]; then
    append_manifest_url "$(head -n 1 "$candidate")"
  fi
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "[错误] 没找到 python3。请先安装 Python 3，或在 Windows 上运行 Windows-sync.bat 更新。"
  read -r -p "按回车关闭。"
  exit 1
fi

python_source_ok() {
  python3 -c 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8-sig"), sys.argv[1], "exec")' "$1" >/dev/null 2>&1
}
# 旧版本自更新曾经原地覆盖正在执行的 Python 文件，异常中断会留下半个文件。
# 完整包根目录保留一份同源副本；若 _updater 副本无法解析，先原子恢复它。
if [ "$SCRIPT_DIR" != "$INSTANCE_DIR" ] && [ -f "$SCRIPT_DIR/player-update-generic.py" ] && [ -f "$INSTANCE_DIR/player-update-generic.py" ]; then
  if ! python_source_ok "$SCRIPT_DIR/player-update-generic.py" && python_source_ok "$INSTANCE_DIR/player-update-generic.py"; then
    repair_tmp="$SCRIPT_DIR/.player-update-generic.py.repair.$$"
    if cp "$INSTANCE_DIR/player-update-generic.py" "$repair_tmp" 2>/dev/null; then
      chmod +x "$repair_tmp" 2>/dev/null || true
      mv -f "$repair_tmp" "$SCRIPT_DIR/player-update-generic.py"
      echo "[修复] 已从包内副本恢复损坏的 _updater/player-update-generic.py。"
    fi
  fi
fi

set +e
python3 - "$MANIFEST_URLS" "$SCRIPT_DIR" "$0" <<'PY'
import hashlib, http.client, ipaddress, os, pathlib, re, shutil, socket, stat, sys, tempfile, time, urllib.parse, urllib.request

# 更新源是家宽直连地址，绝不走系统代理：macOS 上 urllib 会自动读系统代理（Clash“设为系统
# 代理”），代理到不了 18088 就把自刷新请求整齐变成 503。空 ProxyHandler 强制直连、绕过代理。
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))

def fetch_bytes(url, timeout=12):
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname
    port = parsed.port or 80
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    last = None
    for family in (socket.AF_INET, socket.AF_INET6):
        try:
            infos = socket.getaddrinfo(host, port, family, socket.SOCK_STREAM)
        except Exception as exc:
            last = exc
            continue
        if not infos:
            continue
        ip = infos[0][4][0]
        try:
            conn = http.client.HTTPConnection(ip, port, timeout=timeout)
            try:
                conn.request("GET", path, headers={"Host": host, "User-Agent": "portable-server-kit-bootstrap/1.0"})
                resp = conn.getresponse()
                if resp.status != 200:
                    raise OSError(f"HTTP {resp.status} from {ip}")
                return resp.read()
            finally:
                conn.close()
        except Exception as exc:
            last = exc
    if last:
        raise last
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.read()

manifest_urls = [value for value in sys.argv[1].split("\x1f") if value.strip()]
def is_private_update_url(url):
    try:
        host = (urllib.parse.urlsplit(url).hostname or "").lower()
    except Exception:
        return False
    if host in ("localhost", "127.0.0.1", "::1") or host.endswith(".local"):
        return True
    try:
        return ipaddress.ip_address(host).is_private
    except ValueError:
        return False
manifest_urls = ([url for url in manifest_urls if is_private_update_url(url)] +
                 [url for url in manifest_urls if not is_private_update_url(url)])
script_dir = pathlib.Path(sys.argv[2]).resolve()
self_path = pathlib.Path(sys.argv[3]).resolve()
if not manifest_urls:
    print("[更新器] 未找到 UPDATE-URL.txt，将使用包内同步脚本。")
    raise SystemExit(0)
selected_manifest_url = None
manifest_errors = []
def mask_url(url):
    parsed = urllib.parse.urlsplit(url)
    parts = parsed.path.split("/")
    if len(parts) > 2 and parts[1]:
        parts[1] = "***"
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "/".join(parts), parsed.query, parsed.fragment))

for candidate in manifest_urls:
    try:
        # 先探测一次清单；成功后整轮自刷新复用这个地址，避免五个文件各自刷同一条错误。
        fetch_bytes(candidate, timeout=8)
        selected_manifest_url = candidate
        break
    except Exception as exc:
        manifest_errors.append(f"{mask_url(candidate)}: {exc}")
if not selected_manifest_url:
    print("[更新器] 更新源暂时不可达，跳过自刷新（已保留本地脚本）：" + "；".join(manifest_errors))
    raise SystemExit(0)
if selected_manifest_url != manifest_urls[0]:
    print("[更新器] 已切换到备用更新地址（通常是局域网地址）。")
base = selected_manifest_url.rsplit("/", 1)[0] + "/"

def version(path):
    try:
        text = pathlib.Path(path).read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return 0
    match = re.search(r"^# @version\s+(\d+)", text, re.MULTILINE)
    return int(match.group(1)) if match else 0

def sha1(path):
    try:
        return hashlib.sha1(pathlib.Path(path).read_bytes()).hexdigest()
    except Exception:
        return ""

def install(src, dest, executable=False):
    # 同目录临时文件 + os.replace 原子换入：运行中的 bash 持有旧 inode，
    # 自更新不会改写正在执行的脚本内容（v9 起废除字节偏移约束的关键）。
    tmp_new = dest.with_name(dest.name + ".portable-new")
    try:
        shutil.copy2(src, tmp_new)
        if executable:
            tmp_new.chmod(tmp_new.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        os.replace(tmp_new, dest)
    finally:
        if tmp_new.exists():
            try:
                tmp_new.unlink()
            except Exception:
                pass

restart = False
for name in ("player-update-generic.py", "player-update-generic.ps1", "portable-stage-daemon.py", "Windows-sync.bat", "macOS-sync.command"):
    url = urllib.parse.urljoin(base, "_updater/" + urllib.parse.quote(name)) + "?t=" + str(int(time.time() * 1000))
    dest = script_dir / name
    tmp = pathlib.Path(tempfile.gettempdir()) / f"portable-sync-{name}.tmp"
    try:
        tmp.write_bytes(fetch_bytes(url, timeout=12))
        if name == "macOS-sync.command":
            remote_version = version(tmp)
            local_tool_version = version(dest)
            self_version = version(self_path)
            if remote_version and remote_version > local_tool_version:
                install(tmp, dest, executable=True)
                print(f"[更新器] Mac 同步工具已更新：v{local_tool_version} -> v{remote_version}")
            else:
                print(f"[更新器] Mac 同步工具已是最新：v{local_tool_version}")
            if remote_version and remote_version > self_version:
                install(tmp, self_path, executable=True)
                print(f"[更新器] 当前启动脚本已更新：v{self_version} -> v{remote_version}")
                restart = True
        elif sha1(tmp) != sha1(dest):
            install(tmp, dest)
            print(f"[更新器] 已刷新 {name}")
        else:
            print(f"[更新器] 已是最新 {name}")
    except Exception as exc:
        print(f"[更新器] 跳过自刷新 {name}: {exc}")
    finally:
        try:
            tmp.unlink()
        except Exception:
            pass
if restart:
    raise SystemExit(42)
PY
status=$?
set -e
if [ "$status" = "42" ]; then
  echo "[更新器] 当前脚本已更新，正在自动重启..."
  exec "$0"
fi

set +e
# 落位上个会话后台预下载的文件（此时游戏未起、jar 未占用），再交给同步器统一校验。best-effort。
if [ -f "$SCRIPT_DIR/portable-stage-daemon.py" ]; then
  python3 "$SCRIPT_DIR/portable-stage-daemon.py" --instance-dir "$INSTANCE_DIR" --mode promote 2>/dev/null || true
fi
python3 "$SCRIPT_DIR/player-update-generic.py" --instance-dir "$INSTANCE_DIR"
status=$?
set -e
for script in "$INSTANCE_DIR/更新mod-Mac端.command" "$INSTANCE_DIR/启动游戏-Mac端.command" "$INSTANCE_DIR/macOS-sync.command" "$INSTANCE_DIR/_updater/macOS-sync.command"; do
  if [ -f "$script" ]; then
    chmod +x "$script" 2>/dev/null || true
  fi
done

echo
if [ "$status" = "0" ]; then
  echo "[同步] 完成。"
  LAUNCHER_DIR="$INSTANCE_DIR/_launchers"
  HMCL_JAR="$INSTANCE_DIR/HMCL.jar"
  if [ ! -f "$HMCL_JAR" ]; then
    HMCL_JAR="$LAUNCHER_DIR/HMCL.jar"
  fi
  if [ -f "$HMCL_JAR" ]; then
    # HMCL 默认把「工作目录/.minecraft」当游戏目录；实例目录本身是 .minecraft/versions/<名字>，
    # 必须从包含 .minecraft 的上层目录启动，HMCL 才能看到这个实例。
    HMCL_WORKDIR="$INSTANCE_DIR"
    _parent="$(dirname "$INSTANCE_DIR")"
    _grand="$(dirname "$_parent")"
    if [ "$(basename "$_parent")" = "versions" ] && [ "$(basename "$_grand")" = ".minecraft" ]; then
      HMCL_WORKDIR="$(dirname "$_grand")"
      echo "[启动器] 检测到 .minecraft/versions 结构，将从该目录启动 HMCL 以显示实例：$HMCL_WORKDIR"
    else
      echo "[提示] 实例不在 .minecraft/versions 目录下；若拉起的 HMCL 显示没有实例，请改用你导入整合包的那个 HMCL 启动。"
    fi
    echo "[启动器] 正在启动 HMCL..."
    if command -v java >/dev/null 2>&1; then
      (cd "$HMCL_WORKDIR" && nohup java -jar "$HMCL_JAR" >/dev/null 2>&1) &
      echo "[启动器] HMCL 已启动。"
    elif open "$HMCL_JAR" >/dev/null 2>&1; then
      echo "[启动器] HMCL 已启动。"
    else
      echo "[启动器] 找到 HMCL，但无法自动启动。请安装 Java，或手动打开：$HMCL_JAR"
    fi
  else
    echo "[启动器] 未找到 HMCL：$INSTANCE_DIR/HMCL.jar 或 $LAUNCHER_DIR/HMCL.jar"
  fi
  # 后台暂存 daemon：随游戏在线时预下载后续更新，玩家退出/超时后自退。先停掉上会话残留的，
  # 保证跑当前版本、不被过期锁挡住（与 Windows 端自愈一致）。
  if [ -f "$INSTANCE_DIR/.portable-staging/daemon.lock" ]; then
    OLDPID="$(tr -d ' \r\n' < "$INSTANCE_DIR/.portable-staging/daemon.lock" 2>/dev/null)"
    if [ -n "$OLDPID" ]; then kill "$OLDPID" 2>/dev/null || true; fi
    rm -f "$INSTANCE_DIR/.portable-staging/daemon.lock" 2>/dev/null || true
  fi
  if [ -f "$SCRIPT_DIR/portable-stage-daemon.py" ]; then
    nohup python3 "$SCRIPT_DIR/portable-stage-daemon.py" --instance-dir "$INSTANCE_DIR" --mode watch >/dev/null 2>&1 &
    echo "[更新] 后台预下载已启动：管理员发布更新后会自动下好，重开游戏即可用上（无需再等下载）。"
  fi
else
  echo "[同步] 失败，退出码 $status。"
fi
read -r -p "按回车关闭。"
exit "$status"

# 维护注意（新代 os.replace 版）：本文件自更新改为「同目录临时文件 + os.replace
# 原子换入」，运行中的 bash 持有旧 inode，替换不再影响正在执行的脚本；
# player-update-generic.py 的下载本来就是先落临时文件再 rename，同样安全。
# 因此运行本代代码的客户端更新到未来版本不再受「字节偏移/只能改尾部」限制，
# 但仍须保持 LF 换行 + UTF-8 无 BOM。
#
# 版本号头在 v9 过渡期曾暂时冻结，避免旧代 copy2 原地覆盖脚本后按旧字节偏移
# 继续解析而出现 unexpected EOF。当前自更新已改成同目录临时文件 + os.replace，
# v10 用于把“局域网备用源 + 单次预探测”安全推送到存量 Mac 客户端。
