# Kaeluxra Key System (Website A/B/C + API + macOS launcher)

This folder contains:
- `Website A` at `/site-a` with 3 buttons:
  - Get Key (Limited Time) -> Website B
  - Get Premium VIP Key (Paid) -> `https://discord.gg/VtDa5PB33X`
  - Join Discord Server -> `https://discord.gg/KvGJvk4Rgv`
- `Website B` at `/site-b` with key generation:
  - normal key expiry = 6 hours
  - cooldown per client fingerprint = 4 minutes
- `Website C` at `/site-c`:
  - password login (default password: `Light@83`)
  - view active keys + expire/restore
  - toggle Website A / Website B
  - force expire all keys + activate again
  - create VIP keys (never expire by default, optional custom expiry)
- API endpoint for app/launcher:
  - `POST /api/client/validate-key`
- macOS launcher UI:
  - `launcher/kaeluxra_roblox_launcher.py`

## 1) Local run

```bash
cd /Users/rudrakshkotwar/Prometheus/luna/keysystem
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python app.py
```

Open:
- `http://127.0.0.1:5000/site-a`
- `http://127.0.0.1:5000/site-b`
- `http://127.0.0.1:5000/site-c`

Admin password default is `Light@83`.

## 2) Change admin password

```bash
export KEYSYS_ADMIN_PASSWORD='YOUR_NEW_PASSWORD'
python app.py
```

## 3) API request example

```bash
curl -X POST http://127.0.0.1:5000/api/client/validate-key \
  -H "Content-Type: application/json" \
  -d '{"key":"KX-XXXX-XXXX-XXXX"}'
```

Response:

```json
{
  "valid": true,
  "key": "KX-ABCD-EFGH-IJKL-MNOP",
  "key_type": "normal",
  "expires_at": 1710000000,
  "expires_at_utc": "2026-03-05 10:00:00 UTC",
  "seconds_remaining": 21599
}
```

## 4) macOS launcher (key window before Roblox)

```bash
cd /Users/rudrakshkotwar/Prometheus/luna/keysystem
python3 launcher/kaeluxra_roblox_launcher.py
```

Optional config:

```bash
export KEY_API_URL='https://YOUR_DOMAIN/api/client/validate-key'
export KEY_SITE_A_URL='https://YOUR_DOMAIN/site-a'
python3 launcher/kaeluxra_roblox_launcher.py
```

## 5) Important integration note

Because Kaeluxra source code is not present here (only zipped binary), this project provides:
- key backend + admin control
- launcher UI for key gating before Roblox open

Direct in-app Roblox interception requires Kaeluxra source integration or a separate process watchdog strategy.
