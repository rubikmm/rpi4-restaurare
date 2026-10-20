# rpi4-restaurare

Restaurarea Raspberry Pi 4 al bisericii (aparatul de transmisiuni si radio) pe un card nou.
Repo-ul contine doar scriptul de restaurare, fara secrete. Arhiva cu programele si setarile
(fara sistemul de operare si fara muzica) sta intr-un loc privat si se descarca printr-un
**link temporar semnat**, valabil cateva ore.

## Pasii (minimi)

1. **Pregateste cardul** cu *Raspberry Pi Imager*:
   - Sistem: *Raspberry Pi OS Lite (64-bit)* (Debian 12 bookworm).
   - La *Customisation / Editare setari*: hostname `rpi4`, utilizator `pi` + parola, **SSH activat**.
2. **Porneste Pi-ul**: pune cardul, conecteaza cablul Ethernet, da curent. Asteapta 1-2 minute.
3. **Cere linkul**: pe Slack, agentului, scrie: „cere pe Slack agentului linkul de restaurare”
   (de exemplu pe canalul #proj-biserica-audio: *da-mi linkul de restaurare pentru rpi4*).
   Primesti o comanda completa, gata de lipit, cu linkul inclus.
4. **Conecteaza-te** la Pi (`ssh pi@rpi4.local` sau tastatura + monitor) si **lipeste comanda**:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/rubikmm/rpi4-restaurare/main/restaureaza.sh | sudo bash -s -- 'LINK-PRIMIT-PE-SLACK'
   ```

   (Linkul se pune intre ghilimele simple. Optional, dupa link, suma sha256 primita.)
5. **Asteapta**: scriptul instaleaza pachetele (10-30 min), pune fisierele la loc, activeaza serviciile
   si **reporneste singur**. Dupa repornire verifica:

   ```bash
   systemctl status aparat
   ```

   Muzica se sincronizeaza singura din R2 dupa repornire (poate dura).

## Optiuni

- `--fara-repornire` (inaintea linkului): nu reporneste la final.
- Scriptul poate fi rulat din nou in siguranta (idempotent). Jurnal: `/var/log/rpi4-restaurare.log`.
- Linkul expirat (eroare la descarcare): cere altul pe Slack.

## Ce se restaureaza

Aplicatia `aparat-nou` (inclusiv starea din `date/`), serviciile systemd proprii (aparat, segmente,
slujbe/melodii R2, radio-mic, mopidy, backup), Caddy, Icecast, Mopidy, ALSA, conexiunile de retea,
cheile SSH si configul rclone, `ffmpeg`/`ffprobe` din `/usr/local/bin`, lista de pachete instalate manual,
`config.txt` (audio overlays; originalul ramane in `config.txt.orig`), fus orar, limba, grupurile lui `pi`.

## Ce NU se restaureaza

Sistemul de operare, muzica si inregistrarile audio (orice `*.mp3`, `*.wav`, `*.flac`), cache-uri, jurnale,
cheile gazdei SSH (Pi-ul nou are alte amprente SSH), profilul Chromium.
