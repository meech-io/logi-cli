# logi

A macOS command-line tool for Logitech mice and receivers, speaking the
HID++ 1.0/2.0 protocol directly over IOKit. No G HUB, no daemon, no kernel
extension — one static Swift binary.

Built and verified against a **PRO X 2 DEX** (046d:c0a0) and a **Lightspeed
receiver** (046d:c547).

## Build

```sh
make
sudo make install     # /usr/local/bin/logi
```

## Quick start

```sh
logi devices                    # what's plugged in
logi info                       # firmware, battery, DPI, report rate
logi dpi set 1600 --persist     # DPI that survives a power cycle
logi buttons                    # current button bindings
logi buttons set 4 copy         # side button → Cmd+C
logi buttons actions            # everything a button can be bound to
```

## What works on which mouse

HID++ is feature-based: every device advertises the features it implements, and
`logi features` prints that table. Two families matter here.

**Older mice** (MX Master, G502, most Unifying mice) implement `0x1B04
REPROG_CONTROLS_V4`. Buttons have named control IDs and can be remapped live:

```sh
logi buttons remap 0x0053 0x0056 --persist
```

**Newer G mice** (PRO X 2, PRO X 2 DEX, Superlight 2) dropped `0x1B04`
entirely. Their buttons exist only inside onboard profile sectors, so `logi
buttons` transparently switches to editing those:

```sh
logi buttons set 4 paste
logi buttons set 5 copy
logi buttons set 3 dpi-cycle --gshift
```

The same split applies to DPI. `0x2202 EXTENDED_ADJUSTABLE_DPI` exposes a live
setter, but the PRO X 2 DEX firmware answers it with a `logitech internal`
error — the only path that actually sticks is rewriting the profile sector,
which is what `--persist` does. Report rate behaves the same way, so `rate set`
tries the live call and falls back to the profile automatically.

## Onboard profiles

```sh
logi profiles          # DPI stages, report rate, per-button bindings
logi onboard           # onboard (device-managed) vs host (software-managed)
logi dump-sector 1     # raw hex, for when a new profile format shows up
```

A profile sector is a fixed-layout blob ending in a CRC-16/CCITT. `logi` reads
the sector, patches only the bytes it means to change, recomputes the CRC, and
writes it back — so an edit never disturbs lighting, macros, or timeouts.

Logitech has revised that layout. Format ≤5 (what Solaar decodes) packs five
16-bit DPI values at offset 3. Format 6+ stores five-byte X/Y/lift-off records
at offset 4 and shifts the button banks from 32/96 to 48/112. `logi` picks the
layout from the `profileFormat` byte the device reports.

## Pairing

Lightspeed receivers pair through the HID++ 1.0 pairing register (0xB2):

```sh
logi pair --timeout 30       # then power-cycle the mouse near the receiver
logi unpair 1 --yes
```

A Lightspeed receiver only accepts the mouse model it shipped with — mismatched
pairs are silently ignored by the receiver, not rejected with an error.

PRO X / Superlight mice have **no pairing button**. They advertise only on
power-up while unpaired, so `logi pair` works by opening the receiver's lock and
waiting for that window. Unplug the USB cable first: a corded mouse never uses
the wireless link.

Re-pairing one of these to a *different* receiver is what G HUB's Device Pairing
Tool does over the charging cable, and that path is closed here. The mouse
exposes `0x1817` (and every other engineering feature — `0x1801`, `0x1806`,
`0x1EB0`) but answers all of them with error `0x05 logitech internal`, before
and after `0x1E00` enables hidden features. The unlock G HUB uses is not
public. Use `logi scan-registers` and `logi reg` if you want to keep digging.

## Button actions

```
mouse buttons     left, right, middle, back, forward, scroll-left, …
functions         dpi-up, dpi-down, dpi-cycle, dpi-shift, gshift,
                  profile-next, profile-cycle, battery, host-switch, …
macOS shortcuts   copy, paste, cut, undo, redo, select-all, save, find,
                  new-tab, close-tab, quit, app-switch, spotlight,
                  mission-control, screenshot, browser-back, browser-forward
key chords        cmd+c, ctrl+shift+t, alt+left, f5
media             consumer:0x00CD
raw               key:0x06,0x08   raw:80020806
```

## Debugging

`LOGI_DEBUG=1` traces every frame:

```
TX  11 FF 09 6A 00 06 40 06 40 02 …
RX  11 FF FF 09 6A 05 00 …          ← error 0x05 for feature 0x09, function 6
```

If a device can't be opened at all, grant the terminal Input Monitoring access
in System Settings → Privacy & Security.

## Credits

Protocol knowledge, the control-ID and feature-ID tables, and the classic
onboard-profile layout come from [Solaar](https://github.com/pwr-Solaar/Solaar)
(GPLv2) and [libratbag](https://github.com/libratbag/libratbag). The format-6+
profile layout and the 0x8061 connection-type quirk were reverse-engineered
here against a PRO X 2 DEX.
