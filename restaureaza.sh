#!/bin/bash
# restaureaza.sh - restaureaza programele si setarile Raspberry Pi-ului bisericii (rpi4) pe un Raspberry Pi OS proaspat.
# Fara secrete in acest script: arhiva privata se descarca printr-un link temporar semnat, dat ca argument.
#
# Folosire:
#   curl -fsSL https://raw.githubusercontent.com/rubikmm/rpi4-restaurare/main/restaureaza.sh \
#     | sudo bash -s -- [--fara-repornire] 'LINK' [SHA256]
#
# Se poate rula de mai multe ori (idempotent). Jurnal: /var/log/rpi4-restaurare.log

main() {
  set -u
  export DEBIAN_FRONTEND=noninteractive
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  local LOG=/var/log/rpi4-restaurare.log REBOOT=1 URL="" SHA="" WARN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --fara-repornire) REBOOT=0 ;;
      -h|--help) echo "Folosire: restaureaza.sh [--fara-repornire] 'LINK' [SHA256]"; return 0 ;;
      *) if [ -z "$URL" ]; then URL="$1"; elif [ -z "$SHA" ]; then SHA="$1"; fi ;;
    esac
    shift
  done

  exec > >(tee -a "$LOG") 2>&1
  say()  { echo "[$(date +%H:%M:%S)] $*"; }
  warn() { WARN=$((WARN+1)); echo "[$(date +%H:%M:%S)] ATENTIE: $*"; }
  die()  { echo "[$(date +%H:%M:%S)] EROARE: $*"; echo "Nimic nu a fost repornit. Jurnal: $LOG"; exit 1; }

  say "=== Restaurare rpi4 ==="
  # ---------- 0. verificari ----------
  [ "$(id -u)" -eq 0 ] || die "ruleaza ca root (comanda cu sudo)."
  [ -n "$URL" ] || die "lipseste linkul. Cere pe Slack agentului linkul de restaurare."
  . /etc/os-release
  [ "${VERSION_CODENAME:-}" = "bookworm" ] || die "e nevoie de Raspberry Pi OS bookworm (Debian 12); gasit: ${PRETTY_NAME:-necunoscut}."
  [ "$(dpkg --print-architecture)" = "arm64" ] || die "e nevoie de varianta 64-bit (arm64)."
  id pi >/dev/null 2>&1 || die "utilizatorul 'pi' nu exista (il creezi in Raspberry Pi Imager)."
  getent hosts archive.raspberrypi.com >/dev/null 2>&1 || getent hosts deb.debian.org >/dev/null 2>&1 || die "nu am internet (verifica cablul Ethernet)."

  local W; W=$(mktemp -d /var/tmp/rpi4-restaurare.XXXXXX)
  trap 'rm -rf "$W"' EXIT
  local A="$W/arhiva.tar.zst"

  # ---------- 1. unelte + descarcare ----------
  say "1/8 Instalez uneltele de baza (curl, zstd)..."
  if ! command -v zstd >/dev/null || ! command -v curl >/dev/null; then
    apt-get update -qq || warn "apt-get update a esuat"
    apt-get install -y -qq curl zstd ca-certificates || die "nu pot instala curl/zstd."
  fi
  say "2/8 Descarc arhiva (cu reincercari)..."
  local n ok=0
  for n in 1 2 3 4 5; do
    if curl -fL --retry 3 --retry-delay 5 -C - -o "$A" "$URL"; then ok=1; break; fi
    warn "descarcarea a esuat (incercarea $n/5)"; sleep 10
  done
  [ "$ok" = 1 ] || die "nu am putut descarca arhiva. Linkul poate fi expirat: cere unul nou pe Slack."

  # ---------- 2. verificare ----------
  say "3/8 Verific arhiva..."
  if [ -n "$SHA" ]; then
    [ "$(sha256sum "$A" | cut -d' ' -f1)" = "$SHA" ] || die "suma sha256 nu corespunde (arhiva alterata sau incompleta)."
    say "    sha256 OK"
  fi
  zstd -t -q "$A" || die "arhiva nu e un fisier zstd valid (linkul expirat intoarce de obicei o pagina de eroare)."
  zstd -dc "$A" | tar -tf - >/dev/null || die "arhiva tar este corupta."
  mkdir -p "$W/meta"
  zstd -dc "$A" | tar -xf - -C "$W/meta" __rpi4 || die "arhiva nu contine __rpi4/ (nu e o arhiva de setari rpi4)."
  local M="$W/meta/__rpi4"
  say "    arhiva: $(grep -E '^data=' "$M/VERSION" | cut -d= -f2), creata $(grep -E '^creat=' "$M/VERSION" | cut -d= -f2)"

  # ---------- 3. apt: surse + pachete ----------
  say "4/8 Adaug sursele apt si cheile (ex. Caddy)..."
  zstd -dc "$A" | tar -xpf - -C / --wildcards 'etc/apt/sources.list.d/*' 'usr/share/keyrings/*' 'etc/apt/keyrings/*' 2>/dev/null || true
  apt-get update -qq || warn "apt-get update a esuat"

  say "5/8 Instalez pachetele (dureaza; poate 10-30 min)..."
  local avail="$W/pachete-disponibile.txt" p
  : >"$avail"
  while read -r p; do
    [ -n "$p" ] || continue
    case "$p" in linux-image-*|linux-headers-*|raspi-firmware) continue ;; esac
    if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [^(]'; then echo "$p" >>"$avail"
    else warn "pachet indisponibil, sar peste: $p"; fi
  done <"$M/packages-manual.txt"
  local OPT=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)
  if ! xargs -a "$avail" apt-get install "${OPT[@]}"; then
    warn "instalarea in bloc a esuat; incerc pachet cu pachet"
    while read -r p; do apt-get install "${OPT[@]}" "$p" >/dev/null 2>&1 || warn "nu am putut instala: $p"; done <"$avail"
  fi

  # ---------- 4. fisiere ----------
  say "6/8 Restaurez fisierele (programe + setari)..."
  local AK=/home/pi/.ssh/authorized_keys
  [ -f "$AK" ] && cp "$AK" "$W/authorized_keys.pre"
  zstd -dc "$A" | tar -xpf - -C / --xattrs --acls --exclude='__rpi4' --exclude='__rpi4/*' || die "extragerea fisierelor a esuat."
  if [ -f "$W/authorized_keys.pre" ]; then   # pastreaza si cheia pusa de Imager
    cat "$W/authorized_keys.pre" "$AK" 2>/dev/null | awk 'NF && !s[$0]++' >"$W/ak.new" && cat "$W/ak.new" >"$AK"
    chown pi:pi "$AK"; chmod 600 "$AK"
  fi
  mkdir -p /home/pi/aparat-nou/log /home/pi/Music /home/pi/onedrive-mp3player
  chown pi:pi /home/pi/Music /home/pi/onedrive-mp3player /home/pi/aparat-nou/log
  chmod 700 /home/pi/.ssh 2>/dev/null
  # fisiere de sistem cu proprietar dupa nume (utilizatorii din pachete pot avea alt uid)
  chown -R caddy:caddy /var/lib/caddy 2>/dev/null || true

  # grupuri
  local g
  while read -r g; do
    [ -n "$g" ] && [ "$g" != pi ] || continue
    if getent group "$g" >/dev/null; then usermod -aG "$g" pi; else warn "grupul '$g' nu exista, sar peste"; fi
  done <"$M/groups-pi.txt"

  # config.txt (audio overlays etc.): versiunea din backup, cu copie .orig
  local CT=/boot/firmware/config.txt
  if [ -f "$M/config.txt" ] && [ -d /boot/firmware ]; then
    [ -f "$CT.orig" ] || cp -p "$CT" "$CT.orig"
    cp "$M/config.txt" "$CT"
    say "    config.txt inlocuit (original pastrat in config.txt.orig)"
  fi

  # fus orar + limba
  local tz loc
  tz=$(grep -E '^timezone=' "$M/VERSION" | cut -d= -f2); loc=$(grep -E '^locale=' "$M/VERSION" | cut -d= -f2)
  [ -n "$tz" ] && timedatectl set-timezone "$tz" 2>/dev/null || warn "nu am putut seta fusul orar"
  if [ -n "$loc" ] && [ "$loc" != "C.UTF-8" ]; then
    sed -i "s/^# *\(${loc//./\\.} \)/\1/" /etc/locale.gen 2>/dev/null
    locale-gen >/dev/null 2>&1 && update-locale LANG="$loc" || warn "nu am putut seta limba $loc"
  fi

  # ---------- 5. servicii ----------
  say "7/8 Activez serviciile..."
  systemctl daemon-reload
  local u
  while read -r u; do
    case "$u" in ""|*@.service|*.target) continue ;; esac
    if systemctl cat "$u" >/dev/null 2>&1; then
      systemctl enable "$u" >/dev/null 2>&1 || warn "nu am putut activa $u"
    else
      warn "unitate lipsa, sar peste: $u"
    fi
  done <"$M/enabled-units.txt"
  local dt; dt=$(grep -E '^default_target=' "$M/VERSION" | cut -d= -f2)
  if [ "$dt" = "graphical.target" ] && systemctl cat lightdm.service >/dev/null 2>&1; then
    systemctl set-default graphical.target >/dev/null 2>&1
  fi
  if ! runuser -u pi -- bash -c 'cd /home/pi/aparat-nou && python3 -c "import aparat"' >/dev/null 2>&1; then
    warn "modulul python 'aparat' nu se importa (lipsesc dependente?). Verifica: journalctl -u aparat"
  fi

  # ---------- 6. rezumat ----------
  say "8/8 Gata."
  echo "------------------------------------------------------------"
  echo " Restaurare terminata. Avertismente: $WARN (vezi mai sus / $LOG)"
  echo " Muzica (mp3player) se sincronizeaza singura din R2 dupa repornire."
  echo " Dupa repornire verifica:  systemctl status aparat"
  echo "------------------------------------------------------------"
  if [ "$REBOOT" = 1 ]; then
    say "Repornesc in 10 secunde (Ctrl+C anuleaza)..."
    sleep 10
    systemctl reboot
  else
    say "Nu repornesc (--fara-repornire). Ruleaza 'sudo reboot' cand esti gata."
  fi
}

main "$@" </dev/null
