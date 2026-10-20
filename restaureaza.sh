#!/bin/bash
# restaureaza.sh - restaureaza programele si setarile Raspberry Pi-ului bisericii (rpi4) pe un Raspberry Pi OS proaspat
# (Raspberry Pi OS 64-bit CU DESKTOP, Debian 12 bookworm = in Imager "Raspberry Pi OS (Legacy, 64-bit)").
# Fara secrete in acest script: arhiva privata se descarca printr-un link temporar semnat, dat ca argument,
# sau se foloseste direct dintr-un fisier local (ex. de pe un stick USB), fara Slack.
#
# Folosire (varianta 1, link primit pe Slack):
#   curl -fsSL https://raw.githubusercontent.com/rubikmm/rpi4-restaurare/main/restaureaza.sh \
#     | sudo bash -s -- [--fara-repornire] 'LINK' [SHA256]
# Folosire (varianta 2, fisier local, ex. stick USB; SHA256 optional - altfel se foloseste fisierul
# vecin 'FISIER.sha256' daca exista, iar daca nu exista se da doar un avertisment):
#   curl -fsSL https://raw.githubusercontent.com/rubikmm/rpi4-restaurare/main/restaureaza.sh \
#     | sudo bash -s -- [--fara-repornire] /media/pi/NUME-STICK/rpi4-setari-ultima.tar.zst [SHA256]
#
# Se poate rula de mai multe ori (idempotent). Jurnal: /var/log/rpi4-restaurare.log
# Tot scriptul e in functia main, apelata pe ultimul rand: o descarcare intrerupta nu executa nimic pe jumatate.

R_WORK=""; R_POLICY=""
r_cleanup() {
  [ -n "$R_WORK" ] && rm -rf "$R_WORK"
  [ -n "$R_POLICY" ] && rm -f "$R_POLICY"
}

main() {
  set -u
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  local LOG=/var/log/rpi4-restaurare.log REBOOT=1 URL="" SHA="" WARN=0 CHROOT=0
  local FAILED=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --fara-repornire) REBOOT=0 ;;
      -h|--help) echo "Folosire: restaureaza.sh [--fara-repornire] 'LINK' | /cale/spre/arhiva.tar.zst [SHA256]"; return 0 ;;
      -*) echo "Optiune necunoscuta: $1"; return 2 ;;
      *) if [ -z "$URL" ]; then URL="$1"; elif [ -z "$SHA" ]; then SHA="$1"; fi ;;
    esac
    shift
  done

  [ "$(id -u)" -eq 0 ] || { echo "EROARE: ruleaza ca root (comanda cu sudo)."; return 1; }
  touch "$LOG" && chmod 600 "$LOG"
  exec > >(tee -a "$LOG") 2>&1
  say()  { echo "[$(date +%H:%M:%S)] $*"; }
  warn() { WARN=$((WARN+1)); echo "[$(date +%H:%M:%S)] ATENTIE: $*"; }
  die()  { echo "[$(date +%H:%M:%S)] EROARE: $*"; echo "Nimic nu a fost repornit. Jurnal: $LOG"; exit 1; }
  trap r_cleanup EXIT

  say "=== Restaurare rpi4 ==="
  # ---------- 0. verificari ----------
  local LOCAL=""
  [ -n "$URL" ] || die "lipseste linkul sau fisierul cu arhiva. Ai doua variante:
       1) link primit pe Slack: ... | sudo bash -s -- 'LINK' SHA256
       2) fisier cu arhiva (descarcat din Cloudflare dashboard, de pe un stick USB):
          ... | sudo bash -s -- /media/pi/NUME-STICK/rpi4-setari-ultima.tar.zst"
  case "$URL" in
    https://*) ;;
    *) if [ -f "$URL" ]; then LOCAL="$URL"; URL=""
       else die "'$URL' nu e nici link https:// (pune-l intre ghilimele simple), nici fisier existent.
       Daca e fisier pe stick: nu l-am gasit. Cauta stickul cu: ls /media/pi/  (apoi ls /media/pi/NUME-STICK/)."
       fi ;;
  esac
  if [ -n "$SHA" ]; then
    SHA=$(echo "$SHA" | tr 'A-F' 'a-f')
    [[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "suma sha256 data nu arata bine (trebuie 64 de caractere 0-9 a-f)."
  fi
  . /etc/os-release
  case "${VERSION_CODENAME:-}" in
    bookworm) ;;
    trixie|forky) die "cardul are ${PRETTY_NAME:-o versiune noua}. E nevoie de bookworm (Debian 12): in Raspberry Pi Imager alege
       'Raspberry Pi OS (other)' -> 'Raspberry Pi OS (Legacy, 64-bit)' si scrie cardul din nou." ;;
    *) die "e nevoie de Raspberry Pi OS bookworm (Debian 12), 64-bit; gasit: ${PRETTY_NAME:-necunoscut}." ;;
  esac
  [ "$(dpkg --print-architecture)" = "arm64" ] || die "e nevoie de varianta 64-bit (arm64): 'Raspberry Pi OS (Legacy, 64-bit)'."
  id pi >/dev/null 2>&1 || die "utilizatorul 'pi' nu exista (il creezi in Raspberry Pi Imager, la Editare setari)."
  if systemd-detect-virt --chroot >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    CHROOT=1; REBOOT=0
    say "    mod chroot/offline: fara daemon-reload, fara pornire de servicii, fara repornire"
    if [ ! -e /usr/sbin/policy-rc.d ]; then   # nu porni servicii din chroot (ar lovi serviciile gazdei)
      printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d && R_POLICY=/usr/sbin/policy-rc.d
      say "    policy-rc.d temporar (sters la final): pachetele nu pornesc servicii"
    fi
  fi
  getent hosts archive.raspberrypi.com >/dev/null 2>&1 || getent hosts deb.debian.org >/dev/null 2>&1 \
    || die "nu am internet (verifica cablul Ethernet)."
  local freek; freek=$(df -Pk / | awk 'NR==2{print $4}')
  [ "${freek:-0}" -ge 1000000 ] || die "prea putin loc liber pe card ($((freek/1024)) MB); e nevoie de cel putin 1 GB."
  if ! dpkg-query -W -f='${Status}' raspberrypi-ui-mods 2>/dev/null | grep -q 'ok installed'; then
    warn "pare Raspberry Pi OS Lite (fara desktop): se vor descarca si instala in plus ~1 GB (interfata grafica)."
  fi

  R_WORK=$(mktemp -d /var/tmp/rpi4-restaurare.XXXXXX) || die "nu pot crea directorul de lucru."
  local W="$R_WORK" A="$R_WORK/arhiva.tar.zst"
  local APTO=(-o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

  # ---------- 1. unelte + descarcare ----------
  say "1/8 Unelte de baza (curl, zstd)..."
  if ! command -v zstd >/dev/null || ! command -v curl >/dev/null; then
    apt-get "${APTO[@]}" update -qq || warn "apt-get update a esuat"
    apt-get "${APTO[@]}" install -y -qq curl zstd ca-certificates || die "nu pot instala curl/zstd."
  fi
  if [ -n "$LOCAL" ]; then
    # fisier local: se citeste direct de unde e (nu se copiaza, nu se sterge; cleanup-ul atinge doar $R_WORK)
    A="$LOCAL"
    say "2/8 Folosesc arhiva locala: $A"
    [ -r "$A" ] || die "nu pot citi fisierul $A."
    say "    marime: $(( $(stat -c %s "$A") / 1024 / 1024 )) MB"
    if [ -z "$SHA" ] && [ -f "$A.sha256" ]; then
      SHA=$(awk 'NR==1{print tolower($1)}' "$A.sha256")
      [[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "fisierul $A.sha256 nu are formatul asteptat ('<suma>  <nume>')."
      say "    suma sha256 luata din $A.sha256"
    fi
  else
    say "2/8 Descarc arhiva (cu reincercari)..."
    local n ok=0
    for n in 1 2 3 4 5; do
      rm -f "$A"
      if curl -fL -sS --retry 3 --retry-delay 5 --connect-timeout 30 -o "$A" "$URL"; then ok=1; break; fi
      warn "descarcarea a esuat (incercarea $n/5)"; sleep 10
    done
    [ "$ok" = 1 ] || die "nu am putut descarca arhiva. Linkul poate fi expirat: cere unul nou pe Slack."
    say "    descarcat: $(( $(stat -c %s "$A") / 1024 / 1024 )) MB"
  fi

  # ---------- 2. verificare ----------
  say "3/8 Verific arhiva..."
  if [ -n "$SHA" ]; then
    [ "$(sha256sum "$A" | cut -d' ' -f1)" = "$SHA" ] || die "suma sha256 nu corespunde (arhiva alterata sau incompleta)."
    say "    sha256 OK"
  else
    warn "nu am suma sha256 (nici argument, nici fisier .sha256 vecin); verific doar ca arhiva se poate citi"
  fi
  zstd -t -q "$A" || die "arhiva nu e un fisier zstd valid (linkul expirat intoarce de obicei o pagina de eroare)."
  zstd -dc "$A" | tar -tf - >"$W/lista.txt" || die "arhiva tar este corupta."
  grep -qx '__rpi4/VERSION' "$W/lista.txt" || die "arhiva nu contine __rpi4/ (nu e o arhiva de setari rpi4)."
  mkdir -p "$W/meta"
  zstd -dc "$A" | tar -xf - -C "$W/meta" __rpi4 || die "nu pot extrage __rpi4/ din arhiva."
  local M="$W/meta/__rpi4"
  say "    arhiva: $(grep -E '^data=' "$M/VERSION" | cut -d= -f2), creata $(grep -E '^creat=' "$M/VERSION" | cut -d= -f2)"

  # ---------- 3. apt: surse + pachete ----------
  say "4/8 Adaug sursele apt si cheile (ex. Caddy)..."
  local srcs=()
  mapfile -t srcs < <(grep -E '^(etc/apt/sources\.list\.d/[^/]+\.(list|sources)|usr/share/keyrings/[^/]+|etc/apt/keyrings/[^/]+)$' "$W/lista.txt")
  if [ "${#srcs[@]}" -gt 0 ]; then
    zstd -dc "$A" | tar -xf - -C / --no-same-owner "${srcs[@]}" || warn "nu am putut pune sursele apt din arhiva"
  fi
  apt-get "${APTO[@]}" update -qq || { sleep 20; apt-get "${APTO[@]}" update -qq; } || warn "apt-get update a raportat erori (vezi mai sus)"
  apt-cache policy bash 2>/dev/null | grep -q 'Candidate: [^(]' || die "listele de pachete apt nu se pot citi (internet? ora sistemului?)."

  say "5/8 Instalez pachetele (dureaza; 5-30 min)..."
  local want="$W/pachete-dorite.txt" avail="$W/pachete-disponibile.txt" p
  grep -vE '^(linux-image-|linux-headers-|raspi-firmware$|$)' "$M/packages-manual.txt" | sort -u >"$want"
  # o singura interogare apt-cache (in C locale): pachetele cu versiune candidata
  xargs -r -a "$want" apt-cache policy 2>/dev/null \
    | awk '/^[^ ]/{p=$1; sub(/:$/,"",p)} /^  Candidate:/{ if ($2!="(none)") print p }' | sort -u >"$avail"
  while read -r p; do
    grep -qxF "$p" "$avail" || { warn "pachet indisponibil, sar peste: $p"; FAILED+=("$p"); }
  done <"$want"
  local ninst; ninst=$(xargs -r -a "$avail" dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | grep -c ' ok installed$')
  say "    $(wc -l <"$avail") pachete din lista; deja instalate: $ninst"
  # --no-remove: daca un pachet ar cere stergerea altora, apt se opreste (nu sterge nimic din sistemul proaspat)
  if ! xargs -r -a "$avail" apt-get "${APTO[@]}" install -y --no-remove; then
    warn "instalarea in bloc a esuat; incerc pachet cu pachet"
    while read -r p; do
      dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' && continue
      apt-get "${APTO[@]}" install -y --no-remove "$p" >>"$W/apt-unul-cate-unul.log" 2>&1 \
        || { warn "nu am putut instala: $p"; FAILED+=("$p"); }
    done <"$avail"
  fi
  dpkg --configure -a >/dev/null 2>&1 || warn "dpkg --configure -a a raportat erori"
  apt-get clean >/dev/null 2>&1

  # ---------- 4. fisiere ----------
  say "6/8 Restaurez fisierele (programe + setari)..."
  local AK=/home/pi/.ssh/authorized_keys
  [ -f "$AK" ] && cp "$AK" "$W/authorized_keys.pre"
  # identitatea sistemului proaspat NU se suprascrie, chiar daca o arhiva viitoare ar contine-o
  local KEEP=(--exclude='__rpi4' --exclude='etc/machine-id' --exclude='var/lib/dbus/machine-id'
    --exclude='etc/ssh/ssh_host_*' --exclude='etc/fstab' --exclude='etc/hostname' --exclude='etc/hosts'
    --exclude='etc/passwd' --exclude='etc/shadow' --exclude='etc/group' --exclude='etc/gshadow'
    --exclude='etc/passwd-' --exclude='etc/shadow-' --exclude='etc/group-' --exclude='etc/gshadow-'
    --exclude='etc/sudoers' --exclude='etc/sudoers.d' --exclude='boot' --exclude='etc/apt/sources.list')
  zstd -dc "$A" | tar -xpf - -C / --xattrs --acls --keep-directory-symlink --anchored "${KEEP[@]}" || die "extragerea fisierelor a esuat."
  # proprietari: in arhiva sunt numerice; pe sistemul nou utilizatorii din pachete pot avea alte numere
  local puid pgid; puid=$(id -u pi); pgid=$(id -g pi)
  if [ "$puid" != 1000 ] || [ "$pgid" != 1000 ]; then
    say "    pi are uid/gid $puid/$pgid (nu 1000): corectez proprietarii"
    find /home/pi /opt/mopidy-venv -xdev \( -uid 1000 -o -gid 1000 \) -exec chown -h pi:pi {} + 2>/dev/null
  fi
  if [ -f "$W/authorized_keys.pre" ]; then   # pastreaza si cheia pusa de Imager
    cat "$W/authorized_keys.pre" "$AK" 2>/dev/null | awk 'NF && !s[$0]++' >"$W/ak.new" && cat "$W/ak.new" >"$AK"
  fi
  [ -d /home/pi/.ssh ] && { chown -R pi:pi /home/pi/.ssh; chmod 700 /home/pi/.ssh; chmod 600 /home/pi/.ssh/authorized_keys /home/pi/.ssh/id_* 2>/dev/null; chmod 644 /home/pi/.ssh/*.pub 2>/dev/null; }
  mkdir -p /home/pi/aparat-nou/log /home/pi/Music /home/pi/onedrive-mp3player
  chown pi:pi /home/pi/Music /home/pi/onedrive-mp3player /home/pi/aparat-nou/log
  getent passwd caddy >/dev/null && [ -d /var/lib/caddy ] && chown -R caddy:caddy /var/lib/caddy
  getent group icecast >/dev/null && [ -f /etc/icecast2/icecast.xml ] && chown root:icecast /etc/icecast2/icecast.xml && chmod 640 /etc/icecast2/icecast.xml
  getent passwd mopidy >/dev/null && [ -f /etc/mopidy/mopidy.conf ] && chown mopidy:root /etc/mopidy/mopidy.conf
  local nm
  for nm in /etc/NetworkManager/system-connections/*.nmconnection; do   # NM ignora fisierele care nu sunt 600 root
    [ -f "$nm" ] && chown root:root "$nm" && chmod 600 "$nm"
  done

  # grupuri
  local g
  while read -r g; do
    [ -n "$g" ] && [ "$g" != pi ] || continue
    if getent group "$g" >/dev/null; then usermod -aG "$g" pi; else warn "grupul '$g' nu exista, sar peste"; fi
  done <"$M/groups-pi.txt"

  # config.txt: pastrez fisierul imaginii noi si adaug la final doar liniile din backup care lipsesc (pe sectiuni)
  local CT=/boot/firmware/config.txt
  if [ -f "$M/config.txt" ] && [ -f "$CT" ]; then
    [ -f "$CT.orig" ] || cp -p "$CT" "$CT.orig"
    awk '
      function trim(s){ gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
      FNR==1 { sec="all" }
      { l=trim($0) }
      l=="" || l ~ /^#/ { if (FNR==NR) base[++nb]=$0; next }
      l ~ /^\[.*\]$/ { sec=l; gsub(/^\[|\]$/, "", sec); if (FNR==NR) base[++nb]=$0; next }
      FNR==NR { have[sec SUBSEP l]=1; base[++nb]=$0; next }
      !((sec SUBSEP l) in have) && !((sec SUBSEP l) in added) { added[sec SUBSEP l]=1; add[++na]=l; asec[na]=sec }
      END {
        for (i=1;i<=nb;i++) print base[i]
        if (na==0) exit
        print ""; print "# --- adaugat de restaureaza.sh din backup-ul rpi4 ---"
        cur=""
        for (i=1;i<=na;i++) { if (asec[i]!=cur) { print "[" asec[i] "]"; cur=asec[i] } print add[i] }
        if (cur!="all") print "[all]"
      }' "$CT.orig" "$M/config.txt" >"$W/config.txt.nou" || die "nu pot combina config.txt"
    if cmp -s "$W/config.txt.nou" "$CT"; then
      say "    config.txt: nimic de schimbat"
    else
      cat "$W/config.txt.nou" >"$CT"
      say "    config.txt: adaugat din backup (originalul in config.txt.orig):"
      sed -n '/^# --- adaugat de restaureaza.sh/,$p' "$CT" | sed 's/^/      /'
    fi
  else
    warn "config.txt nu a fost combinat (lipseste $CT sau copia din arhiva)"
  fi

  # fus orar + limba (offline, functioneaza si fara systemd pornit)
  local tz loc
  tz=$(grep -E '^timezone=' "$M/VERSION" | cut -d= -f2); loc=$(grep -E '^locale=' "$M/VERSION" | cut -d= -f2)
  if [ -n "$tz" ] && [ -f "/usr/share/zoneinfo/$tz" ]; then
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime && echo "$tz" >/etc/timezone
  else
    warn "nu am putut seta fusul orar ($tz)"
  fi
  if [ -n "$loc" ] && [ "$loc" != "C.UTF-8" ] && [ "$loc" != "C" ]; then
    sed -i "s/^# *\(${loc//./\\.} \)/\1/" /etc/locale.gen 2>/dev/null
    { locale-gen >/dev/null 2>&1 && update-locale LANG="$loc"; } || warn "nu am putut seta limba $loc"
  fi

  # ---------- 5. servicii ----------
  say "7/8 Activez serviciile..."
  [ "$CHROOT" = 1 ] || systemctl daemon-reload || warn "systemctl daemon-reload a esuat"
  local u f d x
  while read -r u; do
    case "$u" in ""|*@.service|*.target) continue ;; esac
    f=""
    for d in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
      [ -f "$d/$u" ] && { f="$d/$u"; break; }
    done
    if [ -z "$f" ]; then warn "unitate lipsa (pachetul ei nu s-a instalat?), sar peste: $u"; continue; fi
    # programul pornit de serviciu trebuie sa existe (ex. un pachet care a esuat)
    x=$(sed -n 's/^ExecStart=[-@:+!]*\([^ ]*\).*/\1/p' "$f" | head -1)
    if [ -n "$x" ] && [[ "$x" == /* ]] && [[ "$x" != *[%\$]* ]] && [ ! -x "$x" ]; then
      warn "nu activez $u: lipseste programul $x"; continue
    fi
    systemctl enable "$u" >/dev/null 2>&1 || warn "nu am putut activa $u"
  done <"$M/enabled-units.txt"
  # servicii doar SysV (fara unitate systemd) nu apar in enabled-units.txt; pachetul icecast2 se instaleaza dezactivat
  local sv
  for sv in icecast2; do
    if [ -x "/etc/init.d/$sv" ]; then
      { update-rc.d "$sv" defaults && update-rc.d "$sv" enable; } >/dev/null 2>&1 || warn "nu am putut activa $sv"
    else
      warn "$sv nu e instalat; nu il pot activa"
    fi
  done
  local dt; dt=$(grep -E '^default_target=' "$M/VERSION" | cut -d= -f2)
  if [ "$dt" = "graphical.target" ] && [ -f /lib/systemd/system/lightdm.service ]; then
    systemctl set-default graphical.target >/dev/null 2>&1 || warn "nu am putut seta pornirea in mod grafic"
  fi
  if ! runuser -u pi -- bash -c 'cd /home/pi/aparat-nou && python3 -c "import aparat"' >/dev/null 2>&1; then
    warn "modulul python 'aparat' nu se importa (lipsesc dependente?). Verifica: journalctl -u aparat"
  fi

  # ---------- 6. rezumat ----------
  say "8/8 Gata."
  echo "------------------------------------------------------------"
  echo " Restaurare terminata. Avertismente: $WARN (vezi mai sus / $LOG)"
  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo " Pachete neinstalate (${#FAILED[@]}): ${FAILED[*]}"
  else
    echo " Toate pachetele din lista sunt instalate."
  fi
  echo " Muzica (mp3player) se sincronizeaza singura din R2 dupa repornire."
  echo " Dupa repornire verifica:  systemctl status aparat"
  echo "------------------------------------------------------------"
  if [ "$REBOOT" = 1 ]; then
    say "Repornesc in 10 secunde (Ctrl+C anuleaza)..."
    sleep 10
    systemctl reboot
  elif [ "$CHROOT" = 1 ]; then
    say "Mod chroot: nu repornesc."
  else
    say "Nu repornesc (--fara-repornire). Ruleaza 'sudo reboot' cand esti gata."
  fi
}

main "$@" </dev/null
