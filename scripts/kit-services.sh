#!/usr/bin/env bash
# Независимое управление TorrServer MatriX, Prowlarr, JacRed-FDB и FlareSolverr.
Torr_PORT=8091
PROWLARR_PORT=9696
JACRED_PORT=9118
FLARESOLVERR_PORT=8191
set -Eeuo pipefail
[[ ${EUID} -eq 0 ]] || { echo "Запустите от root." >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
BASE=/opt/kit-services
STATE=/etc/kit-services
mkdir -p "$BASE" "$STATE"
chmod 750 "$BASE" "$STATE"

say(){ printf '==> %s\n' "$*"; }
die(){ echo "ОШИБКА: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Не найдена команда $1"; }
valid_port(){ [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && ((10#$1>=1024 && 10#$1<=65535)); }
port_free(){
 local p=$1
 if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${p}$"; then
  die "TCP-порт $p уже занят. Ничего не изменено."
 fi
}
fetch_asset(){
 local api=$1 asset=$2 dest=$3 meta url digest got
 meta=$(curl -fsSL --retry 3 "$api") || die "Не удалось прочитать GitHub API релиза"
 url=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' <<<"$meta" | head -n1)
 digest=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .digest // empty' <<<"$meta" | head -n1)
 [[ -n "$url" && "$digest" == sha256:* ]] || die "Нет файла $asset или официальной SHA256 в GitHub Release"
 curl -fL --retry 3 "$url" -o "$dest" || die "Загрузка $asset не удалась"
 got="sha256:$(sha256sum "$dest" | awk '{print $1}')"
 [[ "$got" == "$digest" ]] || die "SHA256 не совпадает для $asset"
}
torr_arch(){
 case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; armv7l|armv6l) echo arm7;; i386|i686) echo 386;; *) die "TorrServer не поддерживает архитектуру $(uname -m)";; esac
}
prowlarr_arch(){
 case "$(uname -m)" in x86_64|amd64) echo x64;; aarch64|arm64) echo arm64;; armv7l|armv6l) echo arm;; *) die "Prowlarr не поддерживает архитектуру $(uname -m)";; esac
}
install_torr(){
 local port=${1:-$Torr_PORT} a rel latest tag asset tmp dir old_port
 valid_port "$port" || die "Порт должен быть от 1024 до 65535"
 need curl; need jq; need sha256sum; need ss
 a=$(torr_arch)
 old_port=$(cat "$STATE/torrserver.port" 2>/dev/null || true)
 if [[ -n "$old_port" && "$old_port" == "$port" ]]; then :; else port_free "$port"; fi
 rel=$(curl -fsSL --retry 3 'https://api.github.com/repos/YouROK/TorrServer/releases?per_page=100')
 latest=$(jq -r '[.[] | select(.draft==false and .prerelease==false and (.tag_name|startswith("MatriX.")))] | sort_by(.published_at) | last | .tag_name // empty' <<<"$rel")
 [[ "$latest" == MatriX.* ]] || die "Не удалось определить последнюю стабильную версию MatriX"
 tag="$latest"; asset="TorrServer-linux-$a"
 tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
 fetch_asset "https://api.github.com/repos/YouROK/TorrServer/releases/tags/$tag" "$asset" "$tmp/TorrServer"
 dir="$BASE/torrserver"; install -d -m 755 "$dir"
 if systemctl is-active --quiet torrserver 2>/dev/null; then systemctl stop torrserver; fi
 install -m 755 "$tmp/TorrServer" "$dir/TorrServer.new"
 mv -f "$dir/TorrServer.new" "$dir/TorrServer"
 printf '%s\n' "$port" >"$STATE/torrserver.port"
 cat >/etc/systemd/system/torrserver.service <<EOF
[Unit]
Description=TorrServer MatriX
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=$dir
ExecStart=$dir/TorrServer --port $port
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
 systemctl daemon-reload; systemctl enable --now torrserver
 systemctl is-active --quiet torrserver || die "TorrServer не запустился (journalctl -u torrserver -n 80)"
 say "TorrServer $tag работает: http://127.0.0.1:$port"
}
install_prowlarr(){
 local port=${1:-$PROWLARR_PORT} a meta latest asset tmp dir old_port
 valid_port "$port" || die "Порт должен быть от 1024 до 65535"
 need curl; need jq; need sha256sum; need ss
 a=$(prowlarr_arch)
 old_port=$(grep -oP '<Port>\K[0-9]+' /var/lib/prowlarr/config.xml 2>/dev/null || true)
 if [[ -n "$old_port" && "$old_port" == "$port" ]]; then :; else port_free "$port"; fi
 meta=$(curl -fsSL --retry 3 https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest)
 jq -e '.draft==false and .prerelease==false' <<<"$meta" >/dev/null || die "Последний релиз Prowlarr не стабильный"
 latest=$(jq -r '.tag_name' <<<"$meta")
 asset=$(jq -r --arg a "$a" '.assets[] | select(.name|test("linux-core-"+$a+"\\.tar\\.gz$")) | .name' <<<"$meta" | head -n1)
 [[ -n "$asset" ]] || die "Нет Linux-сборки Prowlarr для архитектуры $a"
 tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
 fetch_asset https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest "$asset" "$tmp/prowlarr.tar.gz"
 mkdir -p "$BASE/prowlarr" /var/lib/prowlarr
 tar -xzf "$tmp/prowlarr.tar.gz" -C "$tmp"
 [[ -x "$tmp/Prowlarr/Prowlarr" ]] || die "Неожиданное содержимое архива Prowlarr"
 if systemctl is-active --quiet prowlarr 2>/dev/null; then systemctl stop prowlarr; fi
 rm -rf "$BASE/prowlarr/current.new"
 mv "$tmp/Prowlarr" "$BASE/prowlarr/current.new"
 rm -rf "$BASE/prowlarr/current.old"
 [[ ! -d "$BASE/prowlarr/current" ]] || mv "$BASE/prowlarr/current" "$BASE/prowlarr/current.old"
 mv "$BASE/prowlarr/current.new" "$BASE/prowlarr/current"
 # Явно выставляем права на запуск бинарника, чтобы исключить systemd 203/EXEC из-за mode.
 # Сервисный пользователь должен проходить через все каталоги пути ExecStart.
 chmod 755 "$BASE" "$BASE/prowlarr" "$BASE/prowlarr/current" "$BASE/prowlarr/current/Prowlarr"
 id prowlarr >/dev/null 2>&1 || useradd --system --home /var/lib/prowlarr --shell /usr/sbin/nologin prowlarr
 # Всегда применяем выбранный порт: существующий config.xml не должен сохранять старый порт.
 need python3
 python3 - "$port" <<'PYCFG'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
path = Path("/var/lib/prowlarr/config.xml")
if path.exists():
    tree = ET.parse(path)
    root = tree.getroot()
else:
    root = ET.Element("Config")
    tree = ET.ElementTree(root)
for key, value in {
    "Port": sys.argv[1],
    "BindAddress": "127.0.0.1",
    "UrlBase": "",
    "InstanceName": "Prowlarr",
    "UpdateMechanism": "BuiltIn",
}.items():
    node = root.find(key)
    if node is None:
        node = ET.SubElement(root, key)
    node.text = value
tree.write(path, encoding="utf-8", xml_declaration=True)
PYCFG
 cat >/etc/systemd/system/prowlarr.service <<EOF
[Unit]
Description=Prowlarr Indexer Manager
After=network-online.target
Wants=network-online.target
[Service]
User=prowlarr
Group=prowlarr
Type=simple
ExecStart=$BASE/prowlarr/current/Prowlarr -nobrowser -data=/var/lib/prowlarr
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
 chown -R prowlarr:prowlarr "$BASE/prowlarr" /var/lib/prowlarr
 systemctl daemon-reload; systemctl enable --now prowlarr
 systemctl is-active --quiet prowlarr || die "Prowlarr не запустился (journalctl -u prowlarr -n 80)"
 say "Prowlarr $latest работает: http://127.0.0.1:$port"
}
install_jacred(){
 local installer=/opt/jacred/kit-jacred-installer.sh port=${1:-$JACRED_PORT} current_port=""
 valid_port "$port" || die "Порт должен быть от 1024 до 65535"
 need curl; need ss
 mkdir -p /opt/jacred
 need python3
 current_port=$(python3 - <<'PYPORT'
from pathlib import Path
import re, json
root=Path("/opt/jacred")
p=root/"init.yaml"
if p.exists():
    m=re.search(r"(?m)^listenport\s*:\s*(\d+)", p.read_text())
    print(m.group(1) if m else "")
else:
    p=root/"init.conf"
    if p.exists():
        try: print(json.loads(p.read_text()).get("listenport", ""))
        except Exception: print("")
PYPORT
)
 [[ "$current_port" == "$port" ]] || port_free "$port"
 if systemctl is-active --quiet jacred 2>/dev/null; then
  say "JacRed уже запущен; обновляю через официальный установщик с сохранением данных"
  curl -fsSL https://raw.githubusercontent.com/jacred-fdb/jacred/main/jacred.sh -o "$installer"
  chmod 700 "$installer"; bash "$installer" --update
 else
  curl -fsSL https://raw.githubusercontent.com/jacred-fdb/jacred/main/jacred.sh -o "$installer"
  chmod 700 "$installer"; bash "$installer"
 fi
 # JacRed поддерживает listenport в init.yaml; задаём выбранный порт и loopback явно.
 need python3
 python3 - "$port" <<'PYCFG'
import re, sys
from pathlib import Path
root = Path("/opt/jacred")
yaml = root / "init.yaml"
conf = root / "init.conf"
if yaml.exists():
    path = yaml
    text = path.read_text()
    for key, value in (("listenip", "127.0.0.1"), ("listenport", sys.argv[1])):
        pattern = rf"(?m)^{key}\s*:\s*.*$"
        line = f"{key}: {value}"
        text, count = re.subn(pattern, line, text, count=1)
        if not count:
            text = line + "\n" + text
    path.write_text(text)
elif conf.exists():
    import json
    data = json.loads(conf.read_text())
    data["listenip"] = "127.0.0.1"
    data["listenport"] = int(sys.argv[1])
    conf.write_text(json.dumps(data, indent=2) + "\n")
else:
    raise SystemExit("Не найден init.yaml или init.conf JacRed")
PYCFG
 chown jacred:jacred /opt/jacred/init.yaml /opt/jacred/init.conf 2>/dev/null || true
 systemctl restart jacred
 systemctl is-active --quiet jacred || die "JacRed не запустился (journalctl -u jacred -n 80)"
 say "JacRed работает на http://127.0.0.1:$port; health: curl -fsS http://127.0.0.1:$port/health"
 say "FileDB может быть пустой. Снимок загружается отдельным пунктом меню."
}
install_flaresolverr(){
 need curl
 if ! command -v docker >/dev/null 2>&1; then
  say "Docker отсутствует — устанавливаю из системного репозитория"
  if command -v apt-get >/dev/null 2>&1; then apt-get update -qq; apt-get install -y docker.io
  elif command -v dnf >/dev/null 2>&1; then dnf install -y docker
  else die "Автоустановка Docker поддерживается на Debian/Ubuntu и Fedora"; fi
 fi
 systemctl enable --now docker
 docker rm -f flaresolverr >/dev/null 2>&1 || true
 docker pull ghcr.io/flaresolverr/flaresolverr:latest
 docker run -d --name flaresolverr --restart unless-stopped -p 127.0.0.1:${FLARESOLVERR_PORT}:8191 -e LOG_LEVEL=info --tmpfs /tmp:size=256M,mode=1777 ghcr.io/flaresolverr/flaresolverr:latest >/dev/null
 for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${FLARESOLVERR_PORT}/" >/dev/null 2>&1; then say "FlareSolverr доступен только локально: http://127.0.0.1:${FLARESOLVERR_PORT}"; return 0; fi
  sleep 2
 done
 docker logs --tail 40 flaresolverr >&2 || true
 die "FlareSolverr запущен, но HTTP-проверка не прошла"
}
jacred_db(){
 local tmp archive data_dir backup
 [[ -x /opt/jacred/JacRed ]] || die "Сначала установите JacRed"
 need curl; need unzip; need zstd; need tar; need file; need chown
 systemctl stop jacred
 tmp=$(mktemp -d)
 trap 'rm -rf "$tmp"; systemctl start jacred >/dev/null 2>&1 || true' RETURN
 archive="$tmp/db.archive"
 data_dir="$tmp/Data"
 mkdir -p "$data_dir"
 say "Загружаю официальный снимок базы JacRed"
 curl -fL --retry 3 --retry-delay 2 -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36" -e "https://jacred.stream/" "https://sync.jacred.stream/latest.tar.zst.zip" -o "$archive" || die "Сервер снимков JacRed отказал в загрузке (в том числе HTTP 403). Это отказ удалённого sync.jacred.stream, а не ошибка распаковки. База не заменена; сервис будет запущен со старой/пустой БД."
 if file -b "$archive" | grep -qi 'zip archive'; then
  unzip -oq "$archive" -d "$tmp"
  local tar_zst
  tar_zst=$(find "$tmp" -maxdepth 1 -name '*.tar.zst' -print -quit)
  [[ -n "$tar_zst" && -f "$tar_zst" ]] || die "В архиве не найден .tar.zst"
 else
  tar_zst="$archive"
 fi
 zstd -d "$tar_zst" -c | tar -xf - -C "$data_dir" || die "Не удалось распаковать снимок базы"
 [[ -n "$(find "$data_dir" -mindepth 1 -print -quit)" ]] || die "Снимок базы пуст"
 backup="/opt/jacred/Data.backup.$(date +%Y%m%d-%H%M%S)"
 if [[ -d /opt/jacred/Data ]]; then cp -a /opt/jacred/Data "$backup"; fi
 mkdir -p /opt/jacred/Data
 cp -a "$data_dir"/. /opt/jacred/Data/
 chown -R jacred:jacred /opt/jacred/Data
 systemctl start jacred
 systemctl is-active --quiet jacred || die "JacRed не запустился после обновления базы; резервная копия: $backup"
 say "База загружена. Предыдущая Data сохранена: $backup"
}
check_services(){
 local s prowlarr_port jacred_port
 for s in torrserver prowlarr jacred; do
  if systemctl list-unit-files "$s.service" --no-legend 2>/dev/null | grep -q "$s.service"; then
   if systemctl is-active --quiet "$s"; then echo "$s: работает"; else echo "$s: остановлен/ошибка"; fi
  else echo "$s: не установлен"; fi
 done
 if [[ -f "$STATE/torrserver.port" ]]; then
  echo "TorrServer: http://127.0.0.1:$(cat "$STATE/torrserver.port")"
 fi
 if [[ -f /var/lib/prowlarr/config.xml ]]; then
  prowlarr_port=$(python3 - <<'PYPORT'
import xml.etree.ElementTree as ET
from pathlib import Path
try:
    root = ET.parse("/var/lib/prowlarr/config.xml").getroot()
    print((root.findtext("Port") or "").strip())
except (ET.ParseError, OSError):
    print("")
PYPORT
)
  if [[ "$prowlarr_port" =~ ^[0-9]{1,5}$ ]]; then
   echo "Prowlarr: http://127.0.0.1:$prowlarr_port"
  else
   echo "Prowlarr: порт не определён (проверьте /var/lib/prowlarr/config.xml)"
  fi
 fi
 if [[ -d /opt/jacred ]]; then
  jacred_port=$(python3 - <<'PYPORT'
from pathlib import Path
import json, re
root = Path("/opt/jacred")
yaml = root / "init.yaml"
conf = root / "init.conf"
port = ""
if yaml.is_file():
    try:
        text = yaml.read_text()
        match = re.search(r"(?m)^\\s*listenport\\s*:\\s*['\"]?(\\d+)", text)
        if match:
            port = match.group(1)
    except OSError:
        pass
elif conf.is_file():
    try:
        data = json.loads(conf.read_text())
        port = str(data.get("listenport", ""))
    except (OSError, json.JSONDecodeError, AttributeError):
        pass
print(port if port.isdigit() and 1024 <= int(port) <= 65535 else "")
PYPORT
)
  if [[ -n "$jacred_port" ]]; then
   echo "JacRed: http://127.0.0.1:$jacred_port"
  else
   echo "JacRed: установлен, порт не определён (проверьте init.yaml/init.conf)"
  fi
 fi
 if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -qx flaresolverr; then
  if docker inspect -f '{{.State.Running}}' flaresolverr 2>/dev/null | grep -qx true; then
   echo "FlareSolverr: работает — http://127.0.0.1:$FLARESOLVERR_PORT"
  else echo "FlareSolverr: остановлен"; fi
 else echo "FlareSolverr: не установлен"; fi
}
service_control(){
 local svc=$1 act=$2
 if [[ $svc == flaresolverr ]]; then
  case "$act" in start) docker start flaresolverr;; stop) docker stop flaresolverr;; restart) docker restart flaresolverr;; status) docker ps -a --filter name=^/flaresolverr$;; *) die "Действие: start|stop|restart|status";; esac
 else
  case "$act" in start|stop|restart|status) systemctl "$act" "$svc" --no-pager;; *) die "Действие: start|stop|restart|status";; esac
 fi
}
remove_service(){
 local svc=$1 confirm
 case "$svc" in torrserver|prowlarr|jacred|flaresolverr);; *) die "Неизвестный сервис";; esac
 read -r -p "Полностью удалить $svc вместе с настройками и базой данных? [y/N] " confirm
 [[ ${confirm,,} == y ]] || { say "Отменено."; return; }
 systemctl disable --now "$svc" 2>/dev/null || true
 case "$svc" in
  torrserver)
   rm -rf "$BASE/torrserver"; rm -f "$STATE/torrserver.port"
   rm -f /etc/systemd/system/torrserver.service
   ;;
  prowlarr)
   rm -rf "$BASE/prowlarr" /var/lib/prowlarr
   rm -f /etc/systemd/system/prowlarr.service
   userdel prowlarr 2>/dev/null || true
   ;;
  jacred)
   if [[ -x /opt/jacred/kit-jacred-installer.sh ]]; then
    bash /opt/jacred/kit-jacred-installer.sh --remove
   else
    rm -rf /opt/jacred
    rm -f /etc/systemd/system/jacred.service
   fi
   userdel jacred 2>/dev/null || true
   ;;
  flaresolverr)
   docker rm -f flaresolverr >/dev/null 2>&1 || true
   docker image rm ghcr.io/flaresolverr/flaresolverr:latest >/dev/null 2>&1 || true
   ;;
 esac
 systemctl daemon-reload
 rmdir "$STATE" "$BASE" 2>/dev/null || true
 say "$svc полностью удалён вместе с данными и конфигурацией."
}
menu(){
 while :; do
  echo; echo "Торрент-сервисы"
  echo "1. Установить / обновить TorrServer MatriX"
  echo "2. Установить / обновить Prowlarr"
  echo "3. Установить / обновить JacRed-FDB"
  echo "4. Установить / обновить FlareSolverr"
  echo "5. Загрузить базу JacRed (снимок)"
  echo "6. Проверить сервисы и адреса"
  echo "7. Управление сервисом (запуск / остановка / перезапуск / статус)"
  echo "8. Полностью удалить сервис (включая настройки и базу данных)"
  echo "0. Назад"
  read -r -p "Выбор: " c
  case "$c" in
   1) install_torr "$Torr_PORT";;
   2) install_prowlarr "$PROWLARR_PORT";;
   3) install_jacred "$JACRED_PORT";;
   4) install_flaresolverr;;
   5) jacred_db;;
   6) check_services;;
   7)
    echo "Сервис:"
    echo "1. TorrServer MatriX"
    echo "2. Prowlarr"
    echo "3. JacRed-FDB"
    echo "4. FlareSolverr"
    read -r -p "Номер сервиса: " n
    case "$n" in 1) s=torrserver;; 2) s=prowlarr;; 3) s=jacred;; 4) s=flaresolverr;;  *) echo "Нет такого номера"; continue;; esac
    echo "Действие:"
    echo "1. Запустить"
    echo "2. Остановить"
    echo "3. Перезапустить"
    echo "4. Статус"
    read -r -p "Номер действия: " n
    case "$n" in 1) a=start;; 2) a=stop;; 3) a=restart;; 4) a=status;; *) echo "Нет такого номера"; continue;; esac
    service_control "$s" "$a";;
   8)
    echo "Сервис для полного удаления:"
    echo "1. TorrServer MatriX"
    echo "2. Prowlarr"
    echo "3. JacRed-FDB"
    echo "4. FlareSolverr"
    read -r -p "Номер сервиса: " n
    case "$n" in 1) s=torrserver;; 2) s=prowlarr;; 3) s=jacred;; 4) s=flaresolverr;;  *) echo "Нет такого номера"; continue;; esac
    remove_service "$s";;
   0|"") return;;
   *) echo "Нет такого пункта";;
  esac
 done
}
case "${1:-menu}" in
 menu) menu;; torrserver) install_torr "$Torr_PORT";; prowlarr) install_prowlarr "$PROWLARR_PORT";; jacred) install_jacred "$JACRED_PORT";; flaresolverr) install_flaresolverr;;
 jacred-db) jacred_db;; check) check_services;; service) service_control "${2:-}" "${3:-status}";; remove) remove_service "${2:-}";;
 *) echo "kit services [menu|torrserver|prowlarr|jacred|jacred-db|check|service|remove]" >&2; exit 2;;
esac
