# The shared clipboard

A beta, off by default, in ScreenHere for the Mac and for Windows: what you copy on one device is on the clipboard of the other. A Mac and a PC, two Macs or two PCs — any two devices that run ScreenHere on the same network.

- [Connecting two devices](#connecting-two-devices)
- [What is shared, and what is not](#what-is-shared-and-what-is-not)
- [What it does on your network](#what-it-does-on-your-network)
- [When it does not connect](#when-it-does-not-connect)
- [The protocol](#the-protocol)

## Connecting two devices

1. On both, turn on **Shared clipboard** in ScreenHere's panel.
2. On both, click **Connect a device…**. Each now shows the other.
3. On one of them, click the other device's name.
4. Both show the same six digits. If they are the same, click **Connect** on both.

That is done once. From then on the two find each other whenever they are on the same network, and the panel says **Connected**. **Forget** undoes it, on either side.

> On a PC where you are not an administrator, Windows will not let other devices reach ScreenHere. That is fine — the PC reaches the Mac instead — but in step 3, **click the Mac's name on the PC**, not the other way round.

The code is what makes it safe. Someone else on the network could answer in the other device's place, but they could not make both screens show the same digits: if the codes differ, click **Cancel**.

## What is shared, and what is not

- **Text and pictures**, up to 1 MB of text and 25 MB for a picture.
- **Not files.** A file copied in the Finder or in Explorer stays where it is.
- **Nothing marked private.** Copies that password managers flag as concealed are never sent, as they are never kept in the history.
- **One other device.** Connecting a new one replaces the one before.

A copy that arrives is put on the clipboard and, when **History** is on, at the top of the history, with the other device's name where the app usually is. The history itself is not shared: only what is copied while the two are connected.

## What it does on your network

Nothing leaves your network, and there is no server and no account.

- **Finding each other.** While Shared clipboard is on, ScreenHere announces itself with Bonjour (`_screenhere._tcp`), the way printers and speakers do, under a random identifier and the computer's name, and listens on one TCP port (47583 when it is free). Turn it off and both stop.
- **Talking.** One direct connection between the two devices. Everything on it is encrypted with a key only those two have, made when they were connected and kept on each: in a file readable by your account only on the Mac, and under Windows' own data protection on a PC.
- **Being asked.** ScreenHere answers a device it was never connected to only while you are on **Connect a device…**, and then only to show you the code.

macOS asks once whether ScreenHere may find devices on your local network; Windows may ask whether to let it through the firewall. The first is needed. The second is not, as long as the other device can be reached.

## When it does not connect

- **Not the same network**, or a network that keeps its devices apart: guest Wi-Fi, many office and hotel networks. There is nothing ScreenHere can do about that.
- **A firewall on both sides.** One of the two has to be reachable. A Mac is, unless its firewall blocks incoming connections for ScreenHere.
- **A VPN** that takes all traffic, on either device.
- **The other device is asleep.** It comes back by itself when it wakes.

## The protocol

For anyone who wants to check it, or to speak it. Both apps implement it separately — `SyncProtocol.swift` and `SyncProtocol.cs` — and both test suites check the same vectors, so two builds that pass speak the same thing byte for byte.

**Frames.** Every message is a 4-byte big-endian length followed by that many bytes, 32 MiB at most.

**Discovery.** A DNS-SD service of type `_screenhere._tcp`. The instance name is the device's identifier, 32 lowercase hexadecimal digits chosen at random; the TXT record carries `name` (what to show) and `v=1`.

**Connecting two devices** — four frames of JSON in the clear, then one answer each:

| | From | Frame |
|---|---|---|
| 1 | asking | `{"t":"pair1","v":1,"id":…,"name":…,"commit":…}` |
| 2 | answering | `{"t":"pair2","v":1,"id":…,"name":…,"pub":…,"nonce":…}` |
| 3 | asking | `{"t":"pair3","pub":…,"nonce":…}` |
| 4 | both | `{"t":"pair4","ok":true}` or `false` |

`pub` is a fresh P-256 public key in uncompressed form (65 bytes), `nonce` 32 random bytes, both in Base64. `commit` is `SHA-256(pub ‖ nonce)` of the asking device: it promises its key before seeing the other's, and the answering device checks frame 3 against it. Without that, someone in the middle could choose their key after seeing both, and steer the code.

Both then compute

```
salt     = SHA-256(pub_asking ‖ pub_answering ‖ nonce_asking ‖ nonce_answering)
material = HKDF-SHA-256(ECDH(pub_asking, pub_answering), salt, "ScreenHere pairing v1", 36 bytes)
key      = material[0..32]
code     = big-endian(material[32..36]) mod 1 000 000, as six digits
```

and show `code`. Each sends frame 4 with what its user decided; the key is kept only when both said yes. Someone in the middle has one chance in a million of making the two codes match.

A device that is not on **Connect a device…** answers `{"t":"no"}` and closes.

**A session** — one frame of JSON each way, then sealed frames:

```
client:  {"t":"hello","v":1,"id":…,"pub":…,"nonce":…}
server:  {"t":"hello","v":1,"id":…,"pub":…,"nonce":…}

material         = ECDH(pub_client, pub_server) ‖ key
salt             = nonce_client ‖ nonce_server
client-to-server = HKDF-SHA-256(material, salt, "ScreenHere sync v1 c2s", 32 bytes)
server-to-client = HKDF-SHA-256(material, salt, "ScreenHere sync v1 s2c", 32 bytes)
```

`pub` is again a fresh P-256 key, so each connection has keys of its own: a key that leaked later would not open what was said before. A server that does not know the `id` closes the connection.

Every frame after that is AES-256-GCM: the ciphertext followed by its 16-byte tag, under a 12-byte nonce of four zero bytes and the frame's number in that direction, from zero, as 8 big-endian bytes. A frame that is replayed, dropped or out of order does not open, and the connection is closed. The first byte of what is sealed says what it is:

| Byte | | Rest |
|---|---|---|
| 0 | ready | nothing — the first frame each way, which proves the sender holds the key |
| 1 | text | UTF-8 |
| 2 | picture | a PNG file |
| 3 | still here | nothing, every 20 seconds |

Anything else is ignored, so a later version can say more. A connection that has said nothing for 65 seconds is closed.

**Who calls whom.** Either may. The device whose identifier sorts first tries at once, the other after eight seconds without a connection — which is what lets a device behind a firewall reach one that is not. Should both get through at the same moment, both keep the connection opened by the device whose identifier sorts first.

**Not bouncing.** A device does not send what it just received, nor twice in a row the same thing, and ignores what it just sent when it comes back.
