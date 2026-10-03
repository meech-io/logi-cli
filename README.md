# logi

A macOS command-line tool for Logitech mice and receivers, speaking the
HID++ 1.0/2.0 protocol directly over IOKit. No G HUB, no daemon, no kernel
extension — one static Swift binary.

Built and verified against a **PRO X 2 DEX** (046d:c0a0) and a **Lightspeed
receiver** (046d:c547).

## Build

```sh
make
make test             # tests use a fake mouse
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
logi profiles                     # DPI stages, report rate, button bindings
logi profile use 1                # activate the first listed profile
logi profile use 0x0001           # select a sector directly
logi profile create               # copy the selected profile into a free slot
logi profile factory              # back up the user directory and return to defaults
logi profile backup               # save all profile memory to a file
logi profile restore backup.json  # restore a saved backup
logi onboard                      # onboard vs host mode
logi dump-sector 1                # raw hex, for when a new profile format shows up
```

A mouse can report room for five profiles while listing only one. The PRO X 2
DEX can be running its read-only factory profile at `0x0101` with an empty user
profile directory. `dpi set --persist`, `rate set --persist`, and `buttons set`
copy that factory profile into a free user slot on the first edit. Later edits
write back to the user profile. `profile create` makes a separate copy instead.
Use `--profile 0x0101` to copy from the factory profile explicitly.

Add `--dry-run` to an onboard edit or to `profile create`, `profile restore`,
or `profile factory` to see what it would do without changing the mouse.
Writes need onboard mode and at least 20% battery if the mouse reports a level.
Profile formats above 7 aren't supported for writing yet.

Each onboard edit starts with a backup in `~/Library/Application Support/logi/backups/`.
The command prints the path and stops if it can't save the file. Backups contain
all user sectors, the factory directory and profiles, and the current selection.
Restore checks the file's checksum, the mouse's identity and memory layout, and
requires a backup taken in onboard mode. It saves a fresh backup before writing.

**To get back to factory settings, run `logi profile factory`.** The defaults
come from the mouse's ROM, so this doesn't need an older backup file. DEX
firmware refuses to select ROM while a user directory exists. The command
backs up that directory, replaces it with an empty one, then selects the factory
profile. User profile data stays in memory, but disappears from `logi profiles`.
Use the printed backup with `logi profile restore` to get those entries back.
`profile use 1` won't restore them. `profile use factory` and
`profile use 0x0101` do the same thing as `profile factory`.

Edits temporarily clear the user directory so the mouse can run its factory
profile while user data is being written. The directory goes back last, after
the profile has been read back and checked. This costs two extra directory
writes per edit. Setting an already-stored value skips the write altogether.
Restore also writes the directory last and leaves unused sector data alone.

MPM 37.03 has another quirk. Committing an empty directory returns
`INVALID_ARGUMENT` even though it saves the bytes and selects ROM. `logi`
accepts that reply only for an empty directory whose bytes read back exactly,
with the mouse in onboard mode and a factory profile active.

A lost connection can leave a write unfinished. `logi` tries to select the
factory profile and reports whether that worked, but doesn't retry the write.
Once the mouse reconnects, use `profile factory` or restore the backup. Profile
commands don't write firmware. The low-level `raw` command bypasses the backup
and validation checks.

**If button bindings seem to do nothing, check `logi onboard` first.** In *host*
mode the firmware ignores its onboard profiles entirely and waits for software
to drive it, so a perfectly-written binding is simply never read. DPI hides this
symptom, because that goes to the sensor directly and keeps working. Re-pairing
a mouse can flip it into host mode on its own.

The mode values are `0 = no change`, `1 = onboard`, `2 = host` — note that 0 is
*not* "onboard", so writing 0 is a silent no-op that reads back as success.
`logi onboard` re-reads the mode after setting it rather than trusting the write.

`setActiveProfile` is rejected while in host mode; switching to onboard mode
selects a profile again on its own.

A user profile sector is a fixed-layout blob ending in a CRC-16/CCITT. `logi`
checks the CRC, patches only the bytes it means to change, recomputes the CRC,
and checks the whole sector after writing it back. Factory sectors can omit
the checksum, so a new writable copy gets one.

Logitech has revised that layout. Format ≤5 (what Solaar decodes) packs five
16-bit DPI values at offset 3. Format 6+ stores five-byte X/Y/lift-off records
at offset 4 and shifts the button banks from 32/96 to 48/112. Bytes 0/1 hold
wireless/wired report rates and bytes 2/3 hold default/shift DPI indices. `logi`
picks the layout from the `profileFormat` byte the device reports. The `*` in
`profiles` marks the stored default DPI stage. Use `logi dpi` for the live value.

## Pairing

Lightspeed receivers pair through the HID++ 1.0 pairing register (0xB2):

```sh
logi pair --timeout 30       # then power-cycle the mouse near the receiver
logi unpair 1 --yes
```

A Lightspeed receiver only accepts the mouse model it shipped with — mismatched
pairs are silently ignored by the receiver, not rejected with an error.

**A Lightspeed receiver holds exactly one device, and the slot must be free.**
If a pairing is already stored, opening the lock succeeds and the receiver
genuinely listens — it just has nowhere to put a new device, so the attempt
times out looking exactly like an incompatible mouse. Clear it first:

```sh
logi info -d 1        # "Devices linked: 1" means the slot is taken
logi unpair 1 --yes
logi pair --timeout 120
```

`logi pair` sends slot 0 ("receiver picks"), which is what the official tools
do, and sets the receiver's wireless notification flag (register 0x00) first —
without it the receiver never announces that a device joined, and a successful
pairing looks like a timeout.

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

The format-7 DPI offsets were checked against [OpenMouse's protocol notes](https://github.com/OpenMouse-Project/mouse-protocol/blob/main/docs/logitech-onboard-profiles.md)
and a PRO X 2 DEX factory profile, saved in `Tests/Fixtures/`.
