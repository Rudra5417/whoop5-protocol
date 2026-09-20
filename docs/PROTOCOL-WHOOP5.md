# WHOOP 5.0 / MG protocol reference (fd4b "Maverick/Goose")

Collected from public reverse-engineering work. **Protocol facts only** — no code was
copied from these projects, and none of their source may be vendored here (see
Licensing below). Everything below is a documented observation, not a claim about
physiological meaning or accuracy.

Baseline firmware: **50.42.1.0** (the user's strap reports exactly this).

## Licensing of sources — READ BEFORE COPYING CODE

| Project | License | May we copy code? |
| --- | --- | --- |
| `Asherlc/dofek` | NOASSERTION ("Other") | No — treat as reference only |
| `b-nnett/goose` | **none declared** | **No** — all rights reserved |
| `ryanbr/noop` / `NoopApp/noop` | PolyForm **Noncommercial** | No — incompatible with a permissive release |
| `Sophonbot0/whoop-vault` | **MIT** | Yes, with attribution |

Protocol *facts* (UUIDs, byte offsets, CRC parameters, command numbers) are not
copyrightable. This implementation is written from those facts in our own idiom.
If whoop-vault (MIT) is ever translated, keep its notice.

## GATT

| Role | UUID |
| --- | --- |
| Custom service | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Command write (app → strap) | `fd4b0002-cce1-4033-93ce-002d5875f58a` |
| Command responses (notify) | `fd4b0003-cce1-4033-93ce-002d5875f58a` |
| Events (notify) | `fd4b0004-cce1-4033-93ce-002d5875f58a` |
| Data / fragmented (notify) | `fd4b0005-cce1-4033-93ce-002d5875f58a` |
| Memfault (notify) | `fd4b0007-cce1-4033-93ce-002d5875f58a` |

Standard services are also present and identical to 4.0: `180D`/`2A37` heart rate,
`180F`/`2A19` battery, `180A` device information (`2A24` model, `2A25` serial,
`2A26` firmware, `2A27` hardware, `2A29` manufacturer).

WHOOP 4.0, for contrast: service `61080001-8d6d-82b8-614a-1c8cb0f8dcc6`, only
four characteristics (`…0002`–`…0005`, no `…0007`).

## Frame envelope (8-byte header)

```
[0]     0xAA                    SOF
[1]     0x01                    version
[2..3]  u16 LE                  payloadLen — INCLUDES the 4-byte CRC32 trailer
[4]     0x00                    role1
[5]     0x01                    role2
[6..7]  u16 LE                  header CRC16
[8..]   payload                 payloadLen - 4 bytes
[..]    u32 LE                  payload CRC32
```

- **Header CRC**: CRC16-MODBUS — polynomial `0xA001`, init `0xFFFF`, over `frame[0..<6]`.
- **Payload CRC**: IEEE 802.3 / zlib CRC32 over the payload bytes only (not the trailer).
- Distinct from 4.0, which uses a **5-byte header** with **CRC8** (poly `0x07`) over the
  two length bytes and `payloadLen` that excludes the trailer.

Worked example (from public docs, reproducible check):
```
header  aa 01 0c 00 00 01 e7 41    CRC16(aa010c000001) = 0x41E7
payload 23 f1 6a 01 01 00 00 00    type 0x23 COMMAND, seq 0xF1, cmd 0x6A
crc     58 e9 61 fc                CRC32(payload) = 0xFC61E958
```

## Command payload

```
[packetType u8] [seq u8] [command u8] [params…]
```
`packetType` 0x23 = COMMAND, 0x25 = PUFFIN_COMMAND. Response is 0x24 / 0x26.
`seq` increments per command.

## Packet types

| Byte | Name |
| --- | --- |
| 0x23 | COMMAND |
| 0x24 | COMMAND_RESPONSE |
| 0x25 | PUFFIN_COMMAND |
| 0x26 | PUFFIN_COMMAND_RESPONSE |
| 0x28 | REALTIME_DATA — live HR / orientation |
| 0x2B | REALTIME_RAW_DATA — IMU (record type 21) |
| 0x2F | HISTORICAL_DATA — record type 18 |
| 0x30 | EVENT |
| 0x31 | METADATA |
| 0x32 | CONSOLE_LOGS |
| 0x33 | REALTIME_IMU |
| 0x34 | HISTORICAL_IMU |
| 0x35 / 0x36 | PUFFIN events |
| 0x37 | Battery pack console logs |
| 0x38 | PUFFIN_METADATA |

## Command numbers (shared vocabulary with 4.0)

`0x01` LINK_VALID · `0x02` GET_MAX_PROTOCOL_VERSION · `0x03` TOGGLE_REALTIME_HR ·
`0x07` REPORT_VERSION_INFO · `0x0A` SET_CLOCK · `0x0B` GET_CLOCK ·
`0x0E` TOGGLE_GENERIC_HR_PROFILE · `0x14` ABORT_HISTORICAL_TRANSMITS ·
`0x16` SEND_HISTORICAL_DATA · `0x17` HISTORICAL_DATA_RESULT · `0x1A` GET_BATTERY_LEVEL ·
`0x22` GET_DATA_RANGE · `0x23` GET_HELLO_HARVARD (4.0 only) · `0x3F` SEND_R10_R11_REALTIME ·
`0x60` ENTER_HIGH_FREQ_SYNC · `0x61` EXIT_HIGH_FREQ_SYNC · `0x62` GET_EXTENDED_BATTERY_INFO ·
`0x6A` TOGGLE_IMU_MODE · `0x6C` TOGGLE_OPTICAL_MODE · `0x78` SET_FF_VALUE ·
`0x7A` STOP_HAPTICS · `0x7B` SELECT_WRIST · `0x80` GET_FF_VALUE ·
`0x91` GET_HELLO (5.0/Maverick/Puffin)

Command payload format for a command with params, e.g. TOGGLE_IMU_MODE:
`[rev 0x01][enable 0x01][0x00][0x00][0x00]`.

## Bonding — the gate on everything

Every `fd4b` operation needs an **encrypted, bonded** link. Without it:

- subscribing to `fd4b0003/4/5/7` → stalls indefinitely
- writing `fd4b0002` → GATT "Insufficient Authentication"
- an unbonded command write returns `0x26` with error code `0x049c` (1180)

On Apple platforms, writing a frame to `fd4b0002` **with response** brings up the
just-works bond before subscriptions are attempted. Sequence that works:

1. `writeValue(CLIENT_HELLO, for: fd4b0002, type: .withResponse)`
2. subscribe `fd4b0003`, `fd4b0004`, `fd4b0005`, `fd4b0007`
3. strap replies with two `COMMAND_RESPONSE` (GET_HELLO, cmd 145) frames carrying
   device serial and a session token

A static `CLIENT_HELLO` frame is documented by multiple sources as sufficient. The
exact constant must be confirmed against our own strap capture before being relied on —
sources disagree on the middle bytes.

## Live data — REALTIME_DATA 0x28, compact 24-byte form (record type 2)

Streams continuously around 1 Hz, including outside sync sessions. **This is the
live heart-rate feed.**

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | packet type `0x28` |
| 1 | 1 | record type `0x02` |
| 2 | 4 | timestamp, u32 LE — **unix epoch seconds, note the different offset** |
| 6 | 2 | sub-sequence / flags |
| **8** | **1** | **heart rate, bpm** (`0` = no reading) |
| **9** | **1** | **valid flag** (`0x01` = valid HR + R-R, `0x00` = none) |
| **10** | **2** | **R-R interval, u16 LE milliseconds** (`0` when flag is 0) |
| 12 | 6 | reserved |
| 18 | 1 | constant `0x01` |
| 19 | 1 | constant `0x00` |
| 20 | 4 | CRC32 trailer |

A longer 116-byte 0x28 variant appears during active sync; heart rate at offset 22,
quaternion floats at 41–56.

## History — HISTORICAL_DATA 0x2F, record type 18 (116 bytes)

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | packet type `0x2F` |
| 1 | 1 | record type `0x12` (18) |
| 2 | 2 | sequence u16 LE |
| 4 | 2 | constant `0x1850` |
| 6 | 2 | sub-sequence |
| 8 | 6 | session / device id |
| **14** | **1** | **heart rate, bpm** |
| **15** | **1** | **flag** (1 = HR+RR, 2 = HR+RR+extra, 0 = none) |
| **16** | **2** | **R-R interval, u16 LE ms** |
| 18 | 2 | extra (non-zero when flag is 2) |
| 29 | 1 | smoothed HR (tracks a few bpm below offset 14) |
| 33 | 16 | quaternion W,X,Y,Z — 4× float32 LE |

WHOOP 5 history is **not** a WHOOP 4 layout with shifted offsets; the 4.0 type-47
record is a different structure entirely.

## Config keys pushed with SET_FF_VALUE (0x78)

Body = flag name ASCII NUL-padded to 32 bytes, the value byte at offset 32
(ASCII `'1'`/`'2'`), then 7 zeros. Notable: `enable_r22_packets` opens the
type-`0x2F` biometric stream. See NOOP's `Whoop5Config` for the ordered set of 16.

## Open questions for our own capture

1. The exact `CLIENT_HELLO` constant (sources disagree).
2. Whether `TOGGLE_REALTIME_HR` (0x03) or `TOGGLE_GENERIC_HR_PROFILE` (0x0E) is
   required to make `2A37` emit, or whether the `0x28` stream suffices on its own.
3. Whether the `0x28` compact stream flows before any command once bonded.
4. Battery: `2A19` read (standard) vs `GET_BATTERY_LEVEL` (0x1A) and
   `GET_EXTENDED_BATTERY_INFO` (0x62) — which the 5.0 answers.
