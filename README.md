# rpi4-restaurare

Restaurarea Raspberry Pi 4 al bisericii (aparatul de transmisiuni si radio) pe un card nou.
Repo-ul contine doar scriptul de restaurare, fara secrete. Arhiva cu programele si setarile
(fara sistemul de operare si fara muzica) sta intr-un loc privat si se descarca printr-un
**link temporar semnat**, valabil cateva ore.

## Pasii (minimi)

1. **Pregateste cardul** cu *Raspberry Pi Imager*:
   - Dispozitiv: *Raspberry Pi 4*.
   - Sistem: *Raspberry Pi OS (other)* → **Raspberry Pi OS (Legacy, 64-bit)**
     (Debian 12 bookworm, **cu desktop**).
     Atentie: primul rand din lista, *Raspberry Pi OS (64-bit)*, este acum Debian 13 (trixie) si
     **nu** merge; nici varianta *Lite* (ar trebui descarcat ~1 GB de interfata grafica).
   - La *Editare setari*: hostname `rpi4`, utilizator `pi` + parola, fus orar, **SSH activat**.
2. **Porneste Pi-ul**: pune cardul, conecteaza cablul Ethernet, da curent. Asteapta 2-3 minute
   (la prima pornire se reporneste singur o data).
3. **Cere linkul** pe Slack, agentului (de exemplu pe #proj-biserica-audio):
   *da-mi linkul de restaurare pentru rpi4*. Primesti o comanda completa, gata de lipit.
4. **Conecteaza-te** la Pi (`ssh pi@rpi4.local` sau tastatura + monitor, Terminal) si **lipeste comanda**:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/rubikmm/rpi4-restaurare/main/restaureaza.sh | sudo bash -s -- 'LINK-PRIMIT-PE-SLACK' SHA256
   ```

   (Linkul se pune intre ghilimele simple; dupa el, suma sha256 primita odata cu linkul.)
5. **Asteapta**: scriptul instaleaza pachetele lipsa (5-30 min), pune fisierele la loc, activeaza
   serviciile si **reporneste singur**. La final afiseaza cate avertismente au fost si ce pachete
   nu s-au putut instala. Dupa repornire verifica:

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
cheile SSH si configul rclone, `ffmpeg`/`ffprobe` din `/usr/local/bin`, pachetele instalate manual,
liniile proprii din `config.txt` (adaugate la final; originalul ramane in `config.txt.orig`),
fus orar, limba, grupurile lui `pi`.

## Ce NU se restaureaza

Sistemul de operare, muzica si inregistrarile audio (orice `*.mp3`, `*.wav`, `*.flac`), cache-uri, jurnale,
identitatea cardului nou (cheile gazdei SSH - Pi-ul nou are alte amprente SSH -, machine-id, parole,
`fstab`, `cmdline.txt`), profilul Chromium.
