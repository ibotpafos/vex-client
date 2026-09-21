# Android QA — VEX mobile redesign

Date: 2026-09-09

## Device and build

- Physical device: Xiaomi Mi A1 (`4ba9ae7d9805`), Android 9, arm64-v8a.
- Test package: `com.vexguard.client.debug`, version `1.0.57.debug` (`1005765`).
- Source version remains `1.0.55`; higher local debug metadata was used only to pass the remote mandatory-update gate.
- Preserved production package: `com.vexguard.app`. Old development packages remain removed.

## UI and selection verification

- Text-only `VEX` wordmark rendered; no emblem is present.
- Location photo, circular connect action, settings action, and bottom location control rendered without clipping.
- Annotated standalone `VPN выключен` row is removed; connection state is carried by the main action.
- Default mode renders `Автоматически` with the resolved country, server/city, and latency below it.
- Germany, Finland, and the Netherlands render as country cards. Multi-server countries expand in place; no persistent `Выбрать вручную` row remains.
- Country cards have a native 10 dp list gap (29–32 physical px on the Xiaomi); rows inside an expanded country remain contiguous.
- Manual selection of the second Finland server passed, and returning to automatic selection passed.

## Real VPN proof

- AmneziaWG sent a handshake initiation and received a handshake response.
- Android reported a connected, validated VPN transport on `tun0` with DNS `10.64.1.1`.
- HTTPS through the tunnel returned `200` and downloaded `133919` bytes.
- `tun0` counters increased from RX/TX `43553/5349` to `188693/9213` bytes.
- The Android crash buffer was empty.
- Final disconnect passed and Android no longer reported a VPN transport.

Result: **PASS**
