# WANZZMIXER V6 — Art-Net to Roblox DMX Bridge

**by wanzzmanusia**

## File Utama

| File | Fungsi |
|---|---|
| `WanzzMixer_V6.lua` | **Script utama** — execute di Roblox executor |
| `server.py` | Server HTTP polling (jembatan Art-Net → Roblox) |
| `artnet2WSS.py` | Penerima Art-Net UDP, kirim ke server.py |
| `requirements.txt` | Dependensi Python |

## Cara Pakai — MANUAL MODE (tanpa PC)
1. Buka Roblox, masuk map
2. Execute `WanzzMixer_V6.lua` di executor (Synapse X / KRNL / Fluxus)
3. Tab **Fixture** → patch lampu
4. Tab **Program** → kontrol dimmer, pan, tilt
5. Tab **Shape** → aktifkan shape generator Pearl 1024B

## Cara Pakai — BRIDGE MODE (dengan konsol Art-Net / MagicQ)
1. Install dependensi: jalankan `1_INSTALL_DEPENDENSI.bat`
2. Jalankan semua server: `START_SEMUA.bat`
   - Atau manual: `2_JALANKAN_SERVER.bat` + `3_JALANKAN_ARTNET2WSS.bat`
3. Saat diminta, isi username = **nama akun Roblox kamu**
4. Execute `WanzzMixer_V6.lua` di Roblox executor
5. Klik **◎ BRIDGE MODE** di master bar
6. Status hijau = Art-Net data mengalir ke Roblox

## Fixtures (MagicQ)
File `.hed` untuk MagicQ ada di folder `Fixtures/MagicQ/`:
- COR_TRF Clara S 14R
- COR_Parled
- COR_Strobe
- COR_Blinder
- COR_Flower_180W
- COR_Fogger 900W
- COR_MapleLeaf
- COR_Pixel-Beam-Bar_12x60W
- COR_Wallwasher_24X3W

## Perubahan V6 dari V5
- UI dirombak total (warna gelap, cyan accent, hover effect)
- **Bridge Mode** terintegrasi langsung — toggle 1 klik
- Tab baru **BRIDGE** untuk status koneksi & konfigurasi URL
- `Roblox_Script_LEGACY.lua` = script bridge lama (arsip)

## Requirements
- Python 3.8+
- Roblox executor dengan support HTTP request
- Konsol Art-Net (MagicQ, GrandMA, dll.) untuk Bridge Mode
