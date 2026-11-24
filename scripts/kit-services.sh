#!/usr/bin/env bash
# Независимое управление TorrServer MatriX, Prowlarr и JacRed-FDB.
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
 local port=${1:-8090} a rel latest tag asset tmp dir
 valid_port "$port" || die "Порт должен быть от 1024 до 65535"
 need curl; need jq; need sha256sum; need ss
 a=$(torr_arch)
 port_free "$port"
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
 local port=${1:-9696} a meta latest asset tmp dir
 valid_port "$port" || die "Порт должен быть от 1024 до 65535"
 need curl; need jq; need sha256sum; need ss
 a=$(prowlarr_arch); port_free "$port"
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
 id prowlarr >/dev/null 2>&1 || useradd --system --home /var/lib/prowlarr --shell /usr/sbin/nologin prowlarr
 if [[ ! -f /var/lib/prowlarr/config.xml ]]; then
  cat >/var/lib/prowlarr/config.xml <<EOF
<Config><Port>$port</Port><BindAddress>*</BindAddress><UrlBase></UrlBase><InstanceName>Prowlarr</InstanceName><UpdateMechanism>BuiltIn</UpdateMechanism></Config>
EOF
 fi
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
 say "Prowlarr $latest работает: http://127.0.0.1/$(sed -n 's/.*<Port>\\([0-9]*\\)<\\/Port>.*/\\1/p' /var/lib/prowlarr/config.xml)"
}
install_jacred(){
 local installer=/opt/jacred/kit-jacred-installer.sh port=${1:-9117}
 valid_port "$port" || die "Порт должен быть от 1024 до 65535"
 need curl; need ss
 if systemctl is-active --quiet jacred 2>/dev/null; then
  say "JacRed уже запущен; обновляю через официальный установщик с сохранением данных"
  curl -fsSL https://raw.githubusercontent.com/jacred-fdb/jacred/main/jacred.sh -o "$installer"
  chmod 700 "$installer"; bash "$installer" --update
 else
  port_free "$port"
  mkdir -p /opt/jacred
  curl -fsSL https://raw.githubusercontent.com/jacred-fdb/jacred/main/jacred.sh -o "$installer"
  chmod 700 "$installer"; bash "$installer"
 fi
 systemctl is-active --quiet jacred || die "JacRed не запустился (journalctl -u jacred -n 80)"
 say "JacRed работает на http://127.0.0.1:9117; health: curl -fsS http://127.0.0.1:9117/health"
 say "Пустая FileDB не содержит торренты. Базу-снимок можно загрузить отдельным пунктом меню."
}
jacred_db(){
 [[ -x /opt/jacred/kit-jacred-installer.sh ]] || die "Сначала установите JacRed"
 bash /opt/jacred/kit-jacred-installer.sh --download-db
}
check_services(){
 local s
 for s in torrserver prowlarr jacred; do
  if systemctl list-unit-files "$s.service" --no-legend 2>/dev/null | grep -q "$s.service"; then
   if systemctl is-active --quiet "$s"; then echo "$s: работает"; else echo "$s: остановлен/ошибка"; fi
  else echo "$s: не установлен"; fi
 done
 [[ ! -f "$STATE/torrserver.port" ]] || echo "TorrServer: http://127.0.0.1/$(cat "$STATE/torrserver.port")"
 [[ ! -f /var/lib/prowlarr/config.xml ]] || echo "Prowlarr: порт $(sed -n 's/.*<Port>\\([0-9]*\\)<\\/Port>.*/\\1/p' /var/lib/prowlarr/config.xml)"
 [[ ! -d /opt/jacred ]] || echo "JacRed: http://127.0.0.1:9117"
}
service_control(){
 local svc=$1 act=$2
 case "$svc" in torrserver|prowlarr|jacred);; *) die "Неизвестный сервис";; esac
 case "$act" in start|stop|restart|status) systemctl "$act" "$svc" --no-pager;; *) die "Действие: start|stop|restart|status";; esac
}
remove_service(){
 local svc=$1 confirm
 case "$svc" in torrserver|prowlarr|jacred);; *) die "Неизвестный сервис";; esac
 read -r -p "Удалить $svc? Конфигурация и база данных сохраняются. [y/N] " confirm
 [[ ${confirm,,} == y ]] || { say "Отменено."; return; }
 systemctl disable --now "$svc" 2>/dev/null || true
 rm -f "/etc/systemd/system/$svc.service"; systemctl daemon-reload
 case "$svc" in
  torrserver) rm -f "$BASE/torrserver/TorrServer" "$STATE/torrserver.port";;
  prowlarr) rm -rf "$BASE/prowlarr/current" "$BASE/prowlarr/current.old";;
  jacred) say "Исполняемые файлы и БД JacRed оставлены для безопасного удаления вручную: /opt/jacred/kit-jacred-installer.sh --remove";;
 esac
 say "$svc остановлен; данные автоматически не удалены."
}
menu(){
 while :; do
  echo; echo "Торрент-сервисы"
  echo "1. Установить / обновить TorrServer MatriX"
  echo "2. Установить / обновить Prowlarr"
  echo "3. Установить / обновить JacRed-FDB"
  echo "4. Загрузить базу JacRed (снимок)"
  echo "5. Проверить сервисы и адреса"
  echo "6. Управление сервисом (запуск / остановка / перезапуск / статус)"
  echo "7. Удалить сервис (данные сохраняются)"
  echo "0. Назад"
  read -r -p "Выбор: " c
  case "$c" in
   1) read -r -p "Порт TorrServer [8090]: " p; install_torr "${p:-8090}";;
   2) read -r -p "Порт Prowlarr [9696]: " p; install_prowlarr "${p:-9696}";;
   3) read -r -p "Порт JacRed [9117]: " p; install_jacred "${p:-9117}";;
   4) jacred_db;;
   5) check_services;;
   6) read -r -p "Сервис (torrserver/prowlarr/jacred): " s; read -r -p "Действие: " a; service_control "$s" "$a";;
   7) read -r -p "Сервис (torrserver/prowlarr/jacred): " s; remove_service "$s";;
   0|"") return;;
   *) echo "Нет такого пункта";;
  esac
 done
}
case "${1:-menu}" in
 menu) menu;; torrserver) install_torr "${2:-8090}";; prowlarr) install_prowlarr "${2:-9696}";; jacred) install_jacred "${2:-9117}";;
 jacred-db) jacred_db;; check) check_services;; service) service_control "${2:-}" "${3:-status}";; remove) remove_service "${2:-}";;
 *) echo "kit services [menu|torrserver|prowlarr|jacred|jacred-db|check|service|remove]" >&2; exit 2;;
esac
