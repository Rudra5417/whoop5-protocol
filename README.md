# Whoop5Protocol

[![Tests](https://github.com/Rudra5417/whoop5-protocol/actions/workflows/tests.yml/badge.svg)](https://github.com/Rudra5417/whoop5-protocol/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%2013%2B%20%7C%20iOS%2017%2B-lightgrey.svg)

A Swift implementation of the **WHOOP 5.0 / MG** (`fd4b`) Bluetooth Low Energy protocol.
It provides the frame envelope, checksum routines, command encoding, and decoders for the
live and historical biometric records, and is intended to be embedded in a BLE central
that already owns its GATT transport.

The library contains no platform transport code. It is a pure-Foundation package and
builds for macOS 13+ and iOS 17+.

## Status

| Area | State |
| --- | --- |
| Frame codec (encode, parse, reassemble) | Implemented, hardware-verified |
| Live heart rate (`0x28`) | Implemented, hardware-verified |
| Historical record (`0x2F`, type 18) | Implemented, partially verified |
| Battery (`0x1A`) | Implemented, hardware-verified |
| Device family detection (4.0 / 5.0) | Implemented |
| GATT transport and bonding | Out of scope (platform-specific) |
| Historical offload state machine | Not implemented |
| Optical / SpO₂ decoding | Not implemented |

Hardware verification was performed against a WHOOP 5.0 / MG running firmware
`50.42.1.0`. Captured frames are committed as test fixtures.

## Requirements

- Swift 5.9 or later
- macOS 13 or later, or iOS 17 or later

## Installation

Add the package to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Rudra5417/whoop5-protocol.git", from: "1.0.0")
]
```

Or add it to an Xcode project via **File → Add Package Dependencies**.

## Usage

### Opening a session

The session opener is `GET_HELLO` (`0x91`) with parameter `0x01`. The write is
acknowledged by the strap and must be sent before any other command.

```swift
import Whoop5Protocol

let hello = Whoop5Wire.command(
    Whoop5Wire.Command.getHello.rawValue,
    sequence: 1,
    payload: [0x01]
)
peripheral.writeValue(hello, for: characteristic, type: .withResponse)
```

### Reassembling the notify stream

Notify characteristics deliver an arbitrary byte stream, not discrete frames. Feed each
notification into a reassembler and parse the frames it yields.

```swift
var reassembler = Whoop5Reassembler()

func peripheral(_ peripheral: CBPeripheral,
                didUpdateValueFor characteristic: CBCharacteristic,
                error: Error?) {
    guard let data = characteristic.value else { return }
    for bytes in reassembler.append(data) {
        guard let frame = try? Whoop5Wire.Frame(bytes) else { continue }
        handle(frame)
    }
}
```

### Decoding records

```swift
func handle(_ frame: Whoop5Wire.Frame) {
    if let live = Whoop5Wire.Realtime(packet: frame.packet) {
        // ~1 Hz. `valid` reflects the flag byte, not the presence of data.
        print(live.timestamp, live.heartRate, live.rrMilliseconds, live.valid)
    } else if let history = Whoop5Wire.HistoricalRecord(packet: frame.packet) {
        print(history.heartRate, history.rrMilliseconds, history.quaternion ?? [])
    } else if let percent = Whoop5Wire.batteryPercent(packet: frame.packet) {
        print(percent)
    }
}
```

`Realtime.valid` reflects the **flag** byte, which reports whether a reading is
trustworthy rather than whether one arrived. A worn strap reports flag `1` or `2`; an
off-wrist strap can report a plausible rate with flag `0`. Consumers should treat liveness
and validity as independent signals: treating a flag-`0` reading as silence causes
watchdogs to tear down healthy links.

### Detecting the device family

`DeviceFamily` maps the 4.0 and 5.0 UUID sets and resolves characteristic roles, so one
central can support both generations.

```swift
let family = DeviceFamily.detect(fromServiceUUIDs: peripheral.services?.map(\.uuid.uuidString) ?? [])
if family == .whoop5 {
    // CRC16 header, 8-byte envelope, 4-byte body alignment
}
```

## Protocol overview

### Frame envelope

All 5.0 traffic uses an 8-byte header followed by a payload and a CRC32 trailer.

```
 0    1     2..3         4      5      6..7      8..n        n+4
+----+----+-----------+------+------+---------+----------+---------+
| AA | 01 | payloadLen| role1| role2| CRC16   | payload  | CRC32   |
+----+----+-----------+------+------+---------+----------+---------+
                  u16 LE                     u16 LE     u32 LE
```

- `payloadLen` **includes** the 4-byte CRC32 trailer, so the payload is `payloadLen - 4`
  bytes.
- The header CRC16 covers bytes `0..<6` only.
- The payload CRC32 covers the payload, excluding the trailer.

### Checksums

| Checksum | Algorithm | Parameters |
| --- | --- | --- |
| Header | CRC16-Modbus | reflected polynomial `0xA001`, init `0xFFFF`, no final XOR |
| Payload | CRC32 IEEE 802.3 / zlib | standard |

### Command encoding

A command body is `[0x23, sequence, command, params…]`, zero-padded to a multiple of four
bytes. The CRC32 covers the padding and is appended as the trailer; `payloadLen` is the
padded body size plus four.

```swift
let frame = Whoop5Wire.command(Whoop5Wire.Command.getClock.rawValue, sequence: 2)
```

### Response frames

Replies use type `0x24`:

```
[0x24 type][sequence][command][counter][0x01 status][payload…]
```

`status == 0x01` indicates success. The payload offset is consistent across commands; it
is fixed by a `GET_CLOCK` (`0x0B`) reply, whose payload is a little-endian unix timestamp.

### Record layouts

**`0x28` — compact realtime (~1 Hz).** Heart rate, flag, R-R interval, and the record's
own unix timestamp. Offsets are relative to the packet, which begins after the header.

| Offset | Type | Field |
| --- | --- | --- |
| 0 | `u8` | packet type (`0x28`) |
| 1 | `u8` | record version (`0x02`) |
| 2 | `u32` | unix timestamp, seconds |
| 8 | `u8` | heart rate, bpm |
| 9 | `u8` | flag (`0` invalid, `1` HR + R-R, `2` HR + R-R + extra) |
| 10 | `u16` | R-R interval, milliseconds |

**`0x2F` — historical record, type 18.**

| Offset | Type | Field |
| --- | --- | --- |
| 0 | `u8` | packet type (`0x2F`) |
| 1 | `u8` | record type (`0x12`) |
| 2 | `u16` | sequence |
| 14 | `u8` | heart rate, bpm |
| 15 | `u8` | flag |
| 16 | `u16` | R-R interval, milliseconds |
| 29 | `u8` | smoothed heart rate |
| 33..48 | `4 × f32` | orientation quaternion (W, X, Y, Z) |

The quaternion is returned only when it passes a unit-magnitude plausibility check;
otherwise the field is `nil` and the raw bytes remain available via `Frame.raw`.

## Protocol requirements

Three properties of the protocol are not discoverable by inspection: a frame that violates
any of them is structurally valid, parses without error, and is silently discarded by the
strap.

### Body alignment

The command body must be zero-padded to a 4-byte boundary, the CRC32 must cover the
padding, and the complete frame must exceed 15 bytes. A command that violates this is
dropped with no error and no response, which typically presents as a client that connects
and discovers services successfully but never receives data.

### Session opener parameter

`GET_HELLO` must carry parameter `0x01`. A `0x00` parameter produces a frame that parses
correctly and that the strap ignores.

```
aa0108000001e67123019101363e5c8d
   header        crc16  23 01 91 01  crc32
                          ^type ^seq ^cmd ^param
```

### Bonding on iOS

The `fd4b` service exposes no readable characteristic:

| Characteristic | Properties |
| --- | --- |
| `fd4b0002` | write, writeWithoutResponse |
| `fd4b0003`, `…0004`, `…0005`, `…0007` | notify |

iOS initiates BLE pairing only as a side effect of reading an encrypted value. With no
readable characteristic on the service, a third-party app has no available trigger, and
every command write fails with `Encryption is insufficient` (code 15) followed by
`Authentication is insufficient` (code 5). Retrying within the same connection does not
create the bond.

The bond must therefore be created by the official WHOOP app and reused by the OS-level
bond it establishes. Two constraints apply:

- **The strap holds a single bond.** It must be unpaired from within the WHOOP app
  (Device Settings → Advanced → Unpair). Removing it in iOS Settings is insufficient, and
  until it is unpaired the strap does not advertise as pairable.
- **Pairing mode requires specific handling.** The strap must be off the wrist with its
  green LEDs extinguished, held by the sides so the sensor LEDs are not covered, and
  tapped firmly 5–8 times in quick succession until the LED shows blue only. A green LED
  indicates skin detection, not pairability, and is the most common cause of apparent
  pairing failure.

Once the bond exists, `GET_HELLO` returns a `0x24` reply with status `0x01` and the `0x28`
stream delivers live heart rate.

## Compatibility

WHOOP 4.0 and 5.0 are separate protocols rather than variants of one another.

| | WHOOP 4.0 | WHOOP 5.0 / MG |
| --- | --- | --- |
| Custom service | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Characteristics | `…0002`–`…0005` | `…0002`–`…0005` plus `…0007` |
| Frame header | 5 bytes | 8 bytes (adds `role1`, `role2`) |
| Header checksum | CRC8, polynomial `0x07` | CRC16-Modbus, polynomial `0xA001` |
| Inner record offset | byte 4 | byte 8 |
| Body alignment | unpadded | 4-byte aligned |
| Session start | confirmed write, then `GET_HELLO_HARVARD` | static `CLIENT_HELLO` |

Substituting UUIDs alone is not sufficient: a client adapted this way connects and
discovers services, then stalls without producing data. The 4.0 reassembler and battery
decoder are likewise not reusable, as both validate a different envelope.

## Limitations

- **Historical offload is not implemented.** Per-second heart rate, skin temperature,
  motion, gravity, and activity score over multi-week windows require a command sequence
  that this library does not yet provide.
- **Skin temperature and motion are not decoded** from the `0x2F` record. Only heart rate,
  R-R interval, and the orientation quaternion are exposed.
- **Optical and SpO₂ data are not decoded.** The raw packets are time-multiplexed and no
  validated offline decoding is available.
- **GATT transport and bonding are out of scope.** The library operates on bytes; it does
  not manage connections, pairing, or characteristic discovery.
- **`GET_EXTENDED_BATTERY_INFO` (`0x62`) is not implemented.** The strap was not observed
  answering it, whereas `0x1A` responds reliably.

## Testing

```sh
swift test
```

39 tests, anchored on two independent sources.

**Published hardware capture.** The documented `CLIENT_HELLO` frame is reproduced
byte-for-byte, with its header CRC16 (`0x41E7`) and payload CRC32 (`0xFC61E958`) asserted
directly:

```
aa 01 0c 00 00 01 e7 41 | 23 f1 6a 01 01 00 00 00 | 58 e9 61 fc
```

**Captured frames.** Four consecutive `0x28` records and two `0x1A` battery replies
captured from a worn WHOOP 5.0 are committed as fixtures and decoded to the values
observed on the device:

```
28021070b06a0a375102c402bf020000000001003ce5fab7 -> ts 1789947920, HR 81, flag 2, R-R 708 ms
28021170b06a0a375101c4020000000000000100fee00359 -> ts 1789947921, HR 81, flag 1, R-R 708 ms
28021270b06a0a375201cf0200000000000001009b14fb3c -> ts 1789947922, HR 82, flag 1, R-R 719 ms
28021370b06a0a375302b9028e020000000001000afb97fb -> ts 1789947923, HR 83, flag 2, R-R 697 ms
```

```
aa0110000100208124021a040129000000000000d5a361c3 -> 41%, status 0x01
aa01100001002081244a1a02012d000000000000e606bf28 -> 45%, status 0x01
```

These fixtures exercise the header CRC, endianness, `payloadLen` semantics, body
alignment, and record offsets simultaneously; an error of a single byte in any of them
fails the suite. Both battery replies were cross-checked against the standard `2A19`
characteristic, which reported the same percentages at the same moments.

## Provenance and licensing

Protocol facts — UUIDs, byte offsets, checksum parameters, and command numbers — are
observations rather than copyrightable expression, and this implementation is written from
those facts independently. No third-party source code is vendored.

The reference projects consulted are not uniformly reusable:

| Project | License | Use |
| --- | --- | --- |
| `Sophonbot0/whoop-vault` | MIT | Reusable with attribution |
| `Asherlc/dofek` | NOASSERTION | Reference only |
| `ryanbr/noop`, `NoopApp/noop` | PolyForm Noncommercial | Not compatible with this license |
| `b-nnett/goose` | None declared | All rights reserved; do not copy |

This repository is licensed under the MIT License. See [`LICENSE`](LICENSE).

See [`docs/PROTOCOL-WHOOP5.md`](docs/PROTOCOL-WHOOP5.md) for the complete protocol
reference, including the GATT map, record layouts, and `SET_FF_VALUE` configuration keys.

## Disclaimer

Independent project. Not affiliated with, endorsed by, or connected to WHOOP. Not a
medical device. Use only with hardware you own.
