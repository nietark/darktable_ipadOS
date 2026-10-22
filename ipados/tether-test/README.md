# TetherTest: Sony a7 III wired tethering spike for iPad

A small, throwaway iPad app that answers one question before any tethering
code goes into the darktable iPad port: can an iPad drive a Sony a7 III over
a USB-C cable using only public Apple APIs?

It talks to the camera through Apple's ImageCaptureCore framework, sending raw
PTP commands with `requestSendPTPCommand`. The Sony commands come from
[libgphoto2](https://github.com/gphoto/libgphoto2)'s `camlibs/ptp2` driver
(LGPL-2.1-or-later), the same code desktop darktable uses to tether. Sony's
own Camera Remote Command documents were not used: their licence forbids
sharing the material and reverse engineering. The app is GPL-3.0-or-later,
like darktable.

> **Status: not built or run yet.** It was written without a Mac, an iPad
> or the camera, so it has not been compiled. Expect a few compile errors to
> fix on the first build; the PTP and Sony logic follows libgphoto2 closely,
> but none of it has touched hardware.

## What you need

- a Mac with Xcode 16 or newer (Xcode 26 if your iPad runs iPadOS 26)
- an iPad with USB-C, on iPadOS 16 or newer
- an Apple ID; a free one works, but the app then stops launching after
  7 days until you build it again
- the a7 III with a charged battery and a memory card in it
- a USB-C to USB-C **data** cable (the one from a phone charger often only
  carries power)

## Set up the camera

On the a7 III, in the menus (names from Sony's English menu):

1. Update the firmware if it is old; the test was planned for the current
   version.
2. Network > Ctrl w/ Smartphone: **Off**.
3. Setup > USB Connection: **PC Remote**.
4. Setup > USB LUN Setting: **Single**.
5. Setup > USB Power Supply: **Off**.
6. Camera settings > PC Remote Function > Still Img. Save Dest.:
   **PC+Camera**, with a card in the slot.
7. Put the mode dial on **M** for step 7, and set ISO to a number rather
   than Auto.

Close Photos, Capture One, Cascable and any other camera app on the iPad
first: only one app can hold the camera.

## Build and install

1. Clone the fork on your Mac and check out this branch:
   ```bash
   git clone https://github.com/nietark/darktable_ipadOS.git
   cd darktable_ipadOS
   git checkout claude/project-thread-rcuna1
   open ipados/tether-test/TetherTest.xcodeproj
   ```
2. In Xcode, select the **TetherTest** project in the left sidebar, then the
   **TetherTest** target, then **Signing & Capabilities**. Tick
   *Automatically manage signing* and pick your Apple ID under **Team**
   (Xcode > Settings > Accounts adds one). The bundle identifier ends with
   your team ID, so it will not clash with anyone else's.
3. Connect the iPad to the Mac with a cable, unlock it and tap **Trust**.
   On the iPad, turn on Settings > Privacy & Security > **Developer Mode**
   and restart when asked.
4. Pick the iPad as the run destination at the top of the Xcode window and
   press **Run** (Cmd-R).
5. The first time, the iPad refuses to open an app from an unknown
   developer: go to Settings > General > VPN & Device Management, tap your
   Apple ID and **Trust** it, then start TetherTest again.
6. Unplug the iPad from the Mac and plug in the camera. You can keep Xcode's
   console by using Xcode > Window > Devices and Simulators > *Connect via
   network* first, but the app writes its own log, so it is not needed.

If Xcode says the project cannot be opened (an older Xcode), regenerate it:
`brew install xcodegen`, then `xcodegen generate` in `ipados/tether-test`.

If the build fails, copy the errors into the project chat; they will most
likely be small API spelling issues that are quick to fix.

## Run the test

The left side lists the eight steps of the one-day spike from the
[Wired tethering on iPad](https://claude.ai/artifact/Q4VwG6MiqVTUf6ohtSfZaM)
report. Run them in order and stop at the first that fails: each failure
text says which fallback it points to.

| step | what it does | what to note |
|---|---|---|
| 1. Find the camera | starts ImageCaptureCore's device browser | whether the a7 III appears, and its product ID (0x0C34 is PC Remote) |
| 2. Authorization | asks for contents and control access | both statuses; "not determined" is a known iPadOS 26.1 bug |
| 3. Raw PTP | opens a session, sends GetDeviceInfo (0x1001) | pass proves raw commands get through; -21249 means "receive only" |
| 4. Sony handshake | SDIO connect 0x9201 phases 1-3, ext. device info 0x9202 | protocol version (200 expected) |
| 5. Shutter and download | half press, full press, release, then fetches the frame | seconds from press to file on the iPad, file size and MB/s |
| 6. Live view | fetches 100 live view frames | frames per second |
| 7. Settings | moves ISO and shutter speed one notch and back | whether the values change and return |
| 8. One-hour heartbeat | polls the camera every 3 s until you press Stop | pull the cable twice; it should reconnect and fetch any frame shot meanwhile |

During step 8, press the shutter on the camera once while the cable is out:
the reconnect should fetch that frame as a `missed-` file.

The right side has a capture button, live view, ISO and shutter buttons, the
camera's current settings and the full log.

Three switches under the steps help if something fails:

- **Receive-only download** tests fallback 1: shoot on the camera and see
  whether ImageCaptureCore hands the new file to the app by itself.
- **Wrap sent data in a PTP container**: try this if every capture or
  setting change fails with an error while steps 3 and 4 pass. It changes
  how the data for Sony's 0x9205 and 0x9207 commands is packed.
- **Log every PTP command** for a detailed log.

## Getting the results back

Press **Save results**, then **Share results** and **Share log** (AirDrop to
the Mac works), or open the Files app: On My iPad > TetherTest holds
`spike-results.md`, the `logs` folder and every captured frame in
`captures`. Post the results file and the log in the project chat.

## Files

| file | what it holds |
|---|---|
| `TetherTest/Sources/ICCShim.h`, `.m` | Objective-C layer over ImageCaptureCore: delegates, authorization, the PTP call |
| `TetherTest/Sources/PTP.swift` | PTP codes, containers and dataset parsing |
| `TetherTest/Sources/PTPTransport.swift` | one command at a time, with a timeout on each |
| `TetherTest/Sources/SonyProps.swift` | parser for Sony's property blob (0x9209) |
| `TetherTest/Sources/SonyCamera.swift` | handshake, capture, live view, settings, ported from libgphoto2 |
| `TetherTest/Sources/SpikeModel.swift` | the eight steps, heartbeat, reconnect, results |
| `TetherTest/Sources/ContentView.swift` | the screen |

Where each piece comes from in libgphoto2 (`camlibs/ptp2`):

- connect sequence: `camera_init()` in `library.c`, `ptp_sony_sdioconnect()`
  and `ptp_sony_get_vendorpropcodes()` in `ptp.c`
- capture: `camera_sony_capture()` in `library.c`
- live view: the `PTP_VENDOR_SONY` case of `camera_capture_preview()` in
  `library.c`
- property blob: `ptp_unpack_Sony_DPD()` in `ptp-pack.c`
- ISO and shutter stepping on protocol 200 bodies: `_put_sony_value_*()` and
  `_put_Sony_ShutterSpeedMode2()` in `config.c`
