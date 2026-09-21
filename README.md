# Whoop5Protocol

A Swift implementation of the **WHOOP 5.0 / MG** ("Maverick/Goose", `fd4b`) Bluetooth Low
Energy protocol: frame envelope, checksums, command encoding, and decoders for the live
and historical biometric records.

**Verified against real hardware.** Four consecutive `0x28` records captured live from a
worn WHOOP 5.0 (firmware `50.42.1.0`) are checked into the test suite, and the encoder
reproduces a published `CLIENT_HELLO` capture byte-for-byte. See [Verification](#verification).

Written from publicly documented protocol observations. **No third-party source code was
copied** — see [Provenance and licensing](#provenance-and-licensing).

## Three findings that decide whether this works

Getting a WHOOP 5.0 to talk took three separate discoveries. Each fails silently on its
own, and each is easy to get wrong.

### 1. The command body must be padded to a 4-byte boundary

Format-1 acceptance requires `(declaredLength − 4)` to be divisible by four, and the
complete frame to exceed 15 bytes. The CRC32 covers the padding. **Without this the strap
silently drops the command** — no error, no response. This is the most common reason an
implementation connects, discovers services, and then appears to do nothing.

### 2. `CLIENT_HELLO` needs parameter `0x01`

The session opener is `GET_HELLO` (`0x91`) with parameter **`0x01`**, not `0x00`:

```
aa0108000001e67123019101363e5c8d
   header        crc16  23 01 91 01  crc32
                          ^type ^seq ^cmd ^param
```

A `0x00` parameter yields a structurally valid frame that parses cleanly and that the
strap **ignores**. `testEncoderReproducesThePublishedClientHelloFrame` asserts the exact
bytes.

### 3. On iOS, a third-party app cannot create the bond

The `fd4b` service exposes **no readable characteristic**:

| Characteristic | Properties |
| --- | --- |
| `fd4b0002` | write, writeWithoutResponse |
| `fd4b0003`, `…0004`, `…0005`, `…0007` | notify |

iOS begins BLE pairing only as a side effect of *reading* an encrypted value, so no
trigger is available. Every command write fails with `Encryption is insufficient` (code
15), then `Authentication is insufficient` (code 5). Retrying does not help: across ~9
connection cycles, 184 of 194 writes failed identically while the bond was never created.

**The bond must already exist**, created by the official WHOOP app — its OS-level bond is
then shared with every app on the phone. Two practical notes from doing this:

- The strap holds **one** bond. Unpair it **inside the WHOOP app** (Device Settings →
  Advanced → Unpair). Forgetting it in iOS Settings is not enough, and until it is
  unpaired the strap will not advertise as pairable at all.
- To enter pairing mode the strap must be **off the wrist with its green LEDs out**, held
  **by the sides** (so you don't touch the sensor LEDs), and tapped firmly **5–8 times
  quickly** until the LED is **blue only**. A green LED means "awake and detecting skin",
  not "pairable", and is the most common reason pairing appears impossible.

Once the bond exists the strap behaves exactly as documented: `GET_HELLO` returns `0x24`
status `01`, and the `0x28` stream delivers live heart rate.

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
| Body padding | unpadded | **4-byte aligned** |
| Session start | confirmed write, then `GET_HELLO_HARVARD` | static `CLIENT_HELLO` |

Anything that only swaps UUIDs will connect, discover services, and then stall forever.

## What's implemented

- **Checksums** — `crc16Modbus` (reflected `0xA001`, init `0xFFFF`) and `crc32IEEE`
  (zlib/IEEE 802.3), both validated against standard check vectors
- **Frame codec** — 8-byte header builder and parser, with `payloadLen` that *includes*
  the 4-byte CRC32 trailer, 4-byte body padding, and strict rejection of truncated,
  bad-CRC, and bad-SOF input
- **`Whoop5Reassembler`** — splits the CRC16-headed notify stream into frames. The 4.0
  reassembler validates a CRC8 header and cannot be reused
- **`Realtime`** — compact `0x28` record: heart rate, flag, R-R interval, unix timestamp.
  The ~1 Hz live feed. Accepts the full payload or the 20 command bytes `Frame.packet`
  yields
- **`HistoricalRecord`** — `0x2F` record type 18: heart rate, flag, R-R interval, smoothed
  heart rate, and the orientation quaternion, guarded by a unit-quaternion plausibility
  check
- **`DeviceFamily`** — 4.0/5.0 UUID sets, role mapping for the setup gate, and
  auto-detection from discovered services, so one client can support both generations
- **`batteryPercent(packet:)`** — the `GET_BATTERY_LEVEL` (`0x1A`) reply. The payload offset
  is calibrated against a `GET_CLOCK` reply, and it cross-checks against the standard `2A19`
  characteristic on hardware: both reported 41% and 45% at the same moments
- **`Command`** — the command numbers shared with the 4.0 vocabulary

Not implemented: GATT transport and bonding (platform-specific), the historical offload
state machine, optical/SpO₂ decoding, and firmware update paths.

## Usage

```swift
import Whoop5Protocol

// Open the session. This confirmed write is also what the strap answers.
let hello = Whoop5Wire.command(Whoop5Wire.Command.getHello.rawValue,
                               sequence: 1, payload: [0x01])

// Reassemble the notify stream, then parse each frame
var reassembler = Whoop5Reassembler()
for frame in reassembler.append(notificationData) {
    let parsed = try Whoop5Wire.Frame(frame)
    if let live = Whoop5Wire.Realtime(packet: parsed.packet) {
        print(live.heartRate, live.rrMilliseconds, live.valid)
    }
}
```

`Realtime.valid` reflects the **flag** byte — whether the reading is *trustworthy*
(R-R available). A worn strap reports flag `1`/`2`; an off-wrist strap can still report a
plausible rate with flag `0`. Treat liveness (data arriving) separately from validity:
counting a flag-0 reading as silence makes a watchdog tear down a perfectly healthy link.

## Verification

```sh
swift test        # 36 tests
```

Two independent anchors:

**1. A published hardware capture.** This frame is rebuilt byte-for-byte, and its header
CRC16 (`0x41E7`) and payload CRC32 (`0xFC61E958`) asserted directly:

```
aa 01 0c 00 00 01 e7 41 | 23 f1 6a 01 01 00 00 00 | 58 e9 61 fc
```

**2. Real frames from a live WHOOP 5.0**, worn on the wrist — four consecutive `0x28`
records, decoded to the values actually observed:

```
28021070b06a0a375102c402bf020000000001003ce5fab7 → ts 1789947920, HR 81, flag 2, R-R 708 ms
28021170b06a0a375101c4020000000000000100fee00359 → ts 1789947921, HR 81, flag 1, R-R 708 ms
28021270b06a0a375201cf0200000000000001009b14fb3c → ts 1789947922, HR 82, flag 1, R-R 719 ms
28021370b06a0a375302b9028e020000000001000afb97fb → ts 1789947923, HR 83, flag 2, R-R 697 ms
```

If the header CRC, endianness, `payloadLen` semantics, padding, or record offsets were off
by a single byte, these fail.

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

## History offload — not yet implemented

The route to full analytics (per-second HR, skin temperature, motion, gravity, activity
score, over weeks), as documented by `whoop-vault` (MIT):

```
cmd 96 ENTER_HIGH_FREQ_SYNC
cmd 22 SEND_HISTORICAL_DATA
  ← strap streams 0x2F chunks plus METADATA HISTORY_END (type 49, sub 2)
cmd 23 ACK: [SUCCESS=1, start_id(4), end_id(4)]     (9 bytes, padded to 12)
```

Without the per-chunk acknowledgement the strap stops after the first chunk. A successful
acknowledgement can let the strap reclaim history, so records must be committed locally
**before** acknowledging.

Still open:

1. Whether `TOGGLE_REALTIME_HR` (`0x03`) or `TOGGLE_GENERIC_HR_PROFILE` (`0x0E`) is
   required, or whether the `0x28` stream suffices once bonded
2. How to decode skin temperature and motion from the `0x2F` record, which the analytics
   need alongside heart rate
3. Whether `GET_EXTENDED_BATTERY_INFO` (`0x62`) adds anything over `0x1A` — the strap was
   never observed answering it, while `0x1A` answers reliably

Resolved: the battery question. `2A19` reads *and* a `0x1A` reply both arrive, and they
agree, so a cross-checked value is available without the standard characteristic.

See [`docs/PROTOCOL-WHOOP5.md`](docs/PROTOCOL-WHOOP5.md) for the full protocol reference,
including the GATT map, record layouts, and the `SET_FF_VALUE` config keys.

## Disclaimer

Independent project. Not affiliated with, endorsed by, or connected to WHOOP. Not a
medical device. Use only with hardware you own.
