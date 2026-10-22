# Station on the Raspberry Pi

Three pieces run on each station:

1. **The station app and its updater**: `station_updater.py` serves the app at `http://localhost/` for Chromium (kiosk mode) and keeps it up to date by itself. The first version comes from the `deploy/dist/station` folder (`python3 deploy/build.py`); after that, new versions download on their own.
2. **The NFC reader service**: `nfc_reader.py`. Reads the PN532 board built into the case and sends each tap to the app (`127.0.0.1:8766`).
3. **The Wi-Fi helper**: `wifi_helper.py`. It lets the app list and join Wi-Fi networks during first-time setup and from Admin menu › Station. It listens only on `127.0.0.1:8765`.

Requires Raspberry Pi OS Bookworm or later (uses NetworkManager / `nmcli`).

## Install the app and the updater

Run these in the `deploy/dist/station` folder copied onto the Pi:

```bash
sudo useradd --system --home /opt/sp-station --shell /usr/sbin/nologin sp-station 2>/dev/null || true
VER=$(grep -o 'const VERSION = "[^"]*"' index.html | cut -d'"' -f2)
sudo mkdir -p "/opt/sp-station/releases/$VER"
sudo cp -r index.html brand "/opt/sp-station/releases/$VER/"
sudo ln -sfn "releases/$VER" /opt/sp-station/current
sudo chown -R sp-station: /opt/sp-station
sudo install -m 755 station_updater.py /usr/local/bin/station-updater
sudo tee /etc/systemd/system/station-updater.service >/dev/null <<'UNIT'
[Unit]
Description=Equipment station app server and updater
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/station-updater
Restart=always
User=sp-station
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl enable --now station-updater
curl -s http://127.0.0.1/update/status     # {"current": "station-0.2.0+…", ...}
```

Then point the kiosk at it (for example in `~/.config/labwc/autostart` or your autostart file):

```bash
chromium-browser --kiosk --noerrdialogs --disable-session-crashed-bubble --check-for-update-interval=31536000 http://localhost/
```

**How updates work.** Every 30 minutes the updater checks `https://app.sonoranpoint.com/station-release/latest.json`
(published by every deploy). A new version downloads in the background, is checked against its SHA-256 and kept
ready. The station switches to it the next time nobody is using it (it shows "Updating" for a second), and
taps saved while offline carry over. If the new version doesn't start properly within 5 minutes, the updater goes
back to the one before and skips that version. The console's Stations page shows which version each station runs.

`curl -X POST http://127.0.0.1/update/check` checks right away. `python3 test_station_updater.py` tests the updater
without a Pi.

**Moving a Pi that's already set up onto the updater:** the station keeps its setup only if the page's address stays
`http://localhost/`. If it was opened another way before (a file, or another port), it starts at the setup screen
once: give it a new activation code from the console or dashboard.

The updater only replaces the app (the page and its logos). The NFC reader and Wi-Fi helper below are installed by hand.

## Install the Wi-Fi helper

```bash
sudo install -m 755 wifi_helper.py /usr/local/bin/station-wifi-helper
sudo tee /etc/systemd/system/station-wifi-helper.service >/dev/null <<'EOF'
[Unit]
Description=Equipment station Wi-Fi helper
After=NetworkManager.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/station-wifi-helper
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now station-wifi-helper
curl -s http://127.0.0.1:8765/wifi/status   # quick check
```

It runs as root because changing Wi-Fi needs it. It only accepts connections from the Pi itself.

## Built-in NFC reader (PN532, e.g. HiLetgo PN532 NFC Module V3)

Reads NTAG213/215/216 stickers and MIFARE Classic / Ultralight cards and fobs (13.56 MHz).
Only each tag's serial number (UID) is used; nothing is written to the tags.

### Wiring (I2C, recommended: 4 wires)

1. On the PN532 board set the two little switches to **I2C: switch 1 ON, switch 2 OFF**.
2. Connect to the Pi's 40-pin header:

| PN532 pin | Pi pin |
|---|---|
| VCC | pin 1 (3.3 V) |
| GND | pin 6 (GND) |
| SDA | pin 3 (GPIO 2, SDA) |
| SCL | pin 5 (GPIO 3, SCL) |

If I2C is flaky on your board, use UART instead: switches **both OFF**, PN532 TXD → Pi pin 10 (RXD),
PN532 RXD → Pi pin 8 (TXD), plus VCC/GND as above, and set `STATION_NFC=uart` in the service below.

### Placement in the case

- Mount the board flat against the inside of the front panel, antenna side (the side with the
  printed coil) facing out. Plastic up to about 3–5 mm thick is fine.
- **Keep it beside or below the screen, not behind it.** The touchscreen has a metal back plate,
  and metal within ~3 cm of the antenna kills the read range. Same for the Pi, cables and any metal case.
- Expect about 2–4 cm of range with cards, less with small stickers and fobs. Put a "TAP HERE"
  label on the outside right over the antenna.
- Use standoffs or double-sided foam tape, and a dab of hot glue on the header so wires can't
  shake loose.

### Install

```bash
sudo raspi-config nonint do_i2c 0           # turn on I2C   (UART: do_serial_hw 0 and do_serial_cons 1)
sudo apt install -y i2c-tools python3-venv
i2cdetect -y 1                              # should show 24 (the PN532)

sudo python3 -m venv /opt/station-nfc
sudo /opt/station-nfc/bin/pip install adafruit-circuitpython-pn532 adafruit-blinka pyserial
sudo install -m 755 nfc_reader.py /usr/local/bin/station-nfc-reader
sudo tee /etc/systemd/system/station-nfc-reader.service >/dev/null <<'UNIT'
[Unit]
Description=Equipment station NFC reader

[Service]
ExecStart=/opt/station-nfc/bin/python /usr/local/bin/station-nfc-reader
Environment=STATION_NFC=i2c
Restart=always
DynamicUser=yes
SupplementaryGroups=i2c dialout gpio

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl enable --now station-nfc-reader
curl -s http://127.0.0.1:8766/nfc/status    # {"reader": true, ...}
curl -N http://127.0.0.1:8766/nfc/events    # tap a tag: event: tag / data: {"uid": "04A1B2C3D4E5F6"}
```

If the reader is unplugged or not answering, the service keeps retrying every 5 seconds and the
station shows "NFC reader not responding" in its bottom bar until it's back.
A USB reader that types the tag ID (keyboard style) also works, with no service needed.

`python3 test_nfc_reader.py` checks the service without a board (simulated taps).

## How the app finds it

When the station page is served from the Pi itself (`http://localhost/...`), the app
uses the helper. Anywhere else (like the test bench), Wi-Fi is simulated.

## First boot (what the customer sees)

1. **Wi-Fi**: pick a network, type the password on screen, or *Skip* (network cable).
2. **Activation code**: from the welcome email / dashboard. Loads the company's name, logo and colors.
3. **Admin tag**: tap the tag that shipped in the box, enter a name and PIN (twice).
   Allowed once, within an hour of activating. Can be skipped only if the company already has an admin fob.

Server and Wi-Fi changes later: tap the admin fob → **Admin menu** → **Station**.

## Not tested on hardware yet

The NFC service is tested with a simulated board (tap handling, the event stream, a missing board), not yet with a real PN532. The helper's `nmcli` parsing is unit-tested against sample output, but it hasn't run on
a real Pi yet. Check it on the first unit before shipping.
