# Whoop5Protocol

A Swift implementation of the **WHOOP 5.0 / MG** ("Maverick/Goose", `fd4b`) Bluetooth Low
Energy protocol: frame envelope, checksums, command encoding, and decoders for the live
and historical biometric records.

Written from publicly documented protocol observations. **No third-party source code was
copied** — see [Provenance and licensing](#provenance-and-licensing).

## Why this exists

WHOOP 4.0 and 5.0 are not the same protocol with different UUIDs. They differ in frame
header length, checksum algorithm, inner record offset, and connection flow:

| | WHOOP 4.0 ("Harvard") | WHOOP 5.0 / MG ("Goose") |
| --- | --- | --- |
| Custom service | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Characteristics | `…0002`–`…0005` | `…0002`–`…0005` **plus `…0007`** |
| Frame header | 5 bytes | **8 bytes** (adds `role1`, `role2`) |
| Header checksum | CRC8, poly `0x07` | **CRC16-Modbus, poly `0xA001`** |
| Inner record offset | byte 4 | **byte 8** |
| Session start | confirmed write, then `GET_HELLO_HARVARD` | static `CLIENT_HELLO` frame |

Anything that only swaps UUIDs will connect, discover services, and then stall forever.

## What's implemented

- **Checksums** — `crc16Modbus` (reflected `0xA001`, init `0xFFFF`) and `crc32IEEE`
  (zlib/IEEE 802.3), both validated against standard check vectors
- **Frame codec** — 8-byte header builder and parser, with `payloadLen` that *includes*
  the 4-byte CRC32 trailer, and strict rejection of truncated, bad-CRC, and bad-SOF input
- **`Realtime`** — compact `0x28` record (24 bytes): heart rate, validity flag, R-R
  interval, unix timestamp. This is the ~1 Hz live feed.
- **`HistoricalRecord`** — `0x2F` record type 18 (116 bytes): heart rate, flag, R-R
  interval, smoothed heart rate, and the strap's orientation quaternion, guarded by a
  unit-quaternion plausibility check
- **`Command`** — the 22 command numbers shared with the 4.0 vocabulary

Not implemented: GATT transport and bonding (platform-specific, see the doc's open
questions), optical/SpO₂/temperature decoding, and firmware update paths.

## Usage

```swift
import Whoop5Protocol

// Build a command frame
let frame = Whoop5Wire.command(Whoop5Wire.Command.toggleRealtimeHR.rawValue, sequence: 1)
// → write this to fd4b0002 with a response, which also brings up the BLE bond

// Parse an incoming notification
let parsed = try Whoop5Wire.Frame(notificationData)
if let live = Whoop5Wire.Realtime(packet: parsed.packet) {
    print(live.heartRate, live.rrMilliseconds, live.valid)
}
```

## Verification

The test suite is anchored on a **real hardware capture** published in the community
documentation. This frame:

```
aa 01 0c 00 00 01 e7 41 | 23 f1 6a 01 01 00 00 00 | 58 e9 61 fc
```

is rebuilt byte-for-byte by the encoder, and its header CRC16 (`0x41E7`) and payload
CRC32 (`0xFC61E958`) are asserted directly. If the header CRC, endianness, or
`payloadLen` semantics were off by a single byte, those tests fail.

```sh
swift test
```

## Provenance and licensing

Protocol *facts* — UUIDs, byte offsets, checksum parameters, command numbers — are
observations, not copyrightable expression. This implementation is written from those
facts in its own idiom.

The sources it draws on are **not** uniformly reusable, and none of their code is
vendored here:

| Project | License | Status |
| --- | --- | --- |
| `Sophonbot0/whoop-vault` | MIT | Reusable with attribution |
| `Asherlc/dofek` | NOASSERTION | Reference only |
| `ryanbr/noop`, `NoopApp/noop` | PolyForm Noncommercial | **Not** compatible with this license |
| `b-nnett/goose` | none declared | **All rights reserved** — do not copy |

This repository is licensed **MIT** (see `LICENSE`).

## Open questions

These need confirmation against real hardware rather than documentation:

1. The exact static `CLIENT_HELLO` frame — published sources disagree on the middle bytes
2. Whether `TOGGLE_REALTIME_HR` (`0x03`) or `TOGGLE_GENERIC_HR_PROFILE` (`0x0E`) is
   required to make the standard `2A37` characteristic emit, or whether the `0x28`
   stream suffices once bonded
3. Whether the compact `0x28` stream flows before any command is sent, once bonded
4. Battery: `2A19` read vs `GET_BATTERY_LEVEL` (`0x1A`) vs
   `GET_EXTENDED_BATTERY_INFO` (`0x62`) — which the 5.0 answers

See [`docs/PROTOCOL-WHOOP5.md`](docs/PROTOCOL-WHOOP5.md) for the full protocol reference.

## Disclaimer

Independent project. Not affiliated with, endorsed by, or connected to WHOOP. Not a
medical device. Use only with hardware you own.
