<img src="assets/pico-icon.png" alt="Pico icon" width="96" align="right" />

# Pico

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-iOS-lightgrey.svg)](#install-on-your-iphone)

**An on-device AI agent that also works on your own computers.**

Pico is a modified version of [OpenMinis](https://github.com/OpenMinis/OpenMinis), changed since
2026-10-17. It keeps everything OpenMinis does on the phone (leading models, a Linux shell on the
device, browser automation, skills, memory and system integration) and adds a computer of your own
for the agent to work on: a Mac or Linux machine you reach over SSH.

---

## What Pico adds

| | |
|---|---|
| **Remote computers** | Bind a chat to a host and its shell and file tools run there, over SSH. Long commands keep running while iOS suspends the app. |
| **Pairing by scan** | Run `minis-hostd pair` on the computer and scan its code in Pico; no keys to copy or fingerprints to compare. |
| **The host's browser** | On a Mac host, the agent drives ego lite, with your logins there, through `ego-browser`. ego lite is macOS only, so Linux hosts have no browser yet. |
| **The host's screen** | View and control the computer's screen in the app, and let the agent see and click it; taking control pauses the agent. |
| **Proactive push** | `minis-hostd` watches your mail and GitHub, pushes what needs you, and a tap opens a read-only session that explains it. |

Design, decisions and acceptance results: **[docs/remote-agent](docs/remote-agent/README.md)**.
The host daemon: **[host/minis-hostd](host/minis-hostd/README.md)**.

## From OpenMinis

| | |
|---|---|
| **Bring your own model** | Claude, GPT, Gemini and other providers, via your own API keys or account sign-in. |
| **A real Linux shell** | A sandboxed Alpine Linux environment runs on-device. The agent can install packages, run scripts, and work with real files. |
| **Device integration** | Health, Calendar, Reminders, Contacts, HomeKit, Bluetooth, Clipboard, Media, Alarms and more, exposed to the agent as tools. |
| **Browser automation** | The agent can browse and interact with the web on your behalf. |
| **Skills & memory** | Extensible skills plus persistent memory across sessions. |
| **Workspaces** | Organise work into separate contexts, addressable via `minis://workspace/`. |
| **Native offloads** | Heavy or platform-specific work is handed to native code instead of the sandbox. |

Skills built for Claude, Codex, OpenClaw or Hermes Agent generally run as-is. OpenMinis keeps a
collection adapted to its tools in **[OpenMinis/MinisSkills](https://github.com/OpenMinis/MinisSkills)**,
and use cases in **[OpenMinis/AwesomeMinis](https://github.com/OpenMinis/AwesomeMinis)**; both work
in Pico.

---

## Install on your iPhone

Pico is not in the App Store. Build it from source and install it on your own device:

```sh
git clone --recurse-submodules https://github.com/NoSugarCoffee/Pico.git
cd Pico
# build the native dependencies once, as in BUILDING.md, then:
scripts/ios-personal-device.sh --team <TEAM_ID> --prefix <com.you.pico> --device <device id>
```

The script rewrites upstream's bundle id, App Group and iCloud container to your prefix and drops
the entitlements your team cannot sign. The first run stops at the App Group: open
`.build/personal-device/src/ios/Minis.xcodeproj` in Xcode, and for the targets Minis,
AgentWidgetExtension, MinisFileProvider and MinisShare pick your team under Signing & Capabilities
and tick `group.<prefix>` under App Groups. Then run the script again.

Pico installs under its own name and opens its own `pico://` links. It also still claims
upstream's `minis://` links, so while OpenMinis is installed too, iOS may open those in either app.

Then add your computer. To pair it only:

```sh
curl -fsSL https://raw.githubusercontent.com/NoSugarCoffee/Pico/main/host/minis-hostd/scripts/install.sh \
  | sh -s -- --pair --version <version>
```

and scan the code it prints in Pico: Settings → Remote Hosts → Add Host. For notifications from
mail and GitHub, install the daemon as a service with `--host-name` and fill in its configuration:
see [host/minis-hostd](host/minis-hostd/README.md#install).

With a paid Apple team, add `--keep-push` to the build script and the notifications arrive as
Pico's own, straight from your computer through Apple; without one they come through the Bark app.
See [Pico notifications instead of Bark](host/minis-hostd/README.md#pico-notifications-instead-of-bark).

---

## Building from source

Pico ships OpenMinis's Linux sandbox inside the app, so the native dependencies (iSH on iOS, PRoot
on Android, FFmpeg, LAME, rclone) and the Alpine rootfs are **built from source** rather than
committed as binaries.

**→ See [BUILDING.md](BUILDING.md) for the full first-build guide.**

The short version:

```sh
git clone --recurse-submodules https://github.com/NoSugarCoffee/Pico.git
cd Pico

# iOS  — needs Go 1.25+ and Xcode's Metal Toolchain
#        (xcodebuild -downloadComponent MetalToolchain)
#        order matters: FFmpeg links against LAME
./deps/build_lame.sh && ./deps/build_ffmpeg.sh
./deps/build_ish.sh && ./deps/prepare_alpine_rootfs.sh
./deps/build_rclone_ios.sh
open src/ios/Minis.xcodeproj

# Android, inherited from OpenMinis; Pico's own features are iOS only
#          needs NDK r28+, Go 1.25+ and gomobile
./deps/build_proot.sh && ./scripts/prepare_android_sandbox.sh
./deps/build_rclone_android.sh
mkdir -p src/android/app/libs && cp deps/build/rclone/rclone.aar src/android/app/libs/
cd src/android && ./gradlew :app:assembleDebug
```

Internal names (`Minis.xcodeproj`, `com.openminis.app`, `minis-hostd`, `~/.minis`) are
upstream's and stay that way, so OpenMinis changes keep merging into Pico.

---

## Repository layout

```
src/ios/          iOS app (Swift / SwiftUI) + share, widget and file-provider extensions
src/android/      Android app (Kotlin / Compose) + JNI native code
src/shared/       Assets shared by both platforms
host/minis-hostd/ Pico's host daemon: pairing, notifications, the event store (Go)
deps/             Native dependency build scripts and vendored sources
docs/specs/       Architecture and interface specifications, from OpenMinis
docs/remote-agent Pico's remote-agent design, decisions and acceptance
scripts/          Rootfs preparation and developer tooling
```

---

## Built on OpenMinis

Pico exists because OpenMinis is free and open source. The app, its sandbox, its tools and most of
this repository are OpenMinis's work.

- Website: **[openminis.app](https://openminis.app)**
- The original app: [App Store](https://apps.apple.com/app/id6759188481) ·
  [TestFlight beta](https://testflight.apple.com/join/3BdkA5c3) ·
  [Android releases](https://github.com/OpenMinis/OpenMinis/releases)
- Source: **[OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis)**
- Community: the OpenMinis [Telegram group](https://t.me/+2NzhOJuzRyI1YmM1)

What people have written about OpenMinis:

> "the most impressive indie app I've seen in a while"
>
> — Federico Viticci, [**Open Minis Is the iOS Agent I Wish Siri AI Could Be**](https://www.macstories.net/reviews/open-minis-is-the-ios-agent-i-wish-siri-ai-could-be/),
> MacStories (July 2026)

> "在很大程度上实现甚至局部超越了 Apple Intelligence"
>
> — Ye Han, [**这可能是 iPhone 最强 Agent 软件，没有之一 丨Open Minis 入门指南**](https://zhuanlan.zhihu.com/p/2045570157783807562),
> 知乎 / Zhihu (June 2026)

> "可能是 iOS 端最强 AI Agent"
>
> — [**Open Minis：可能是 iOS 端最强 AI Agent**](https://www.appinn.com/open-minis/),
> 小众软件 / Appinn (March 2026)

Please report problems with Pico's own features here, not to OpenMinis.

---

## Acknowledgements

Pico, like OpenMinis, stands on a great deal of open-source work. Our thanks to the OpenMinis
authors, and to the maintainers of these projects — the full inventory, with versions and license
terms, is in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

**The sandbox** — the heart of the product:

- **[iSH](https://github.com/ish-app/ish)** (GPLv3) — Linux usermode emulation on
  iOS. OpenMinis runs [an ARM64 fork](https://github.com/OpenMinis/ish-arm64).
- **[PRoot](https://github.com/termux/proot)** (GPLv2) — user-space chroot for the
  Android sandbox, via [the OpenMinis fork](https://github.com/OpenMinis/proot);
  **[talloc](https://talloc.samba.org)** (LGPLv3+) underpins it.
- **[Alpine Linux](https://alpinelinux.org)** — the minirootfs the sandbox boots.

**Media & text** — [FFmpeg](https://ffmpeg.org) (LGPL-2.1+),
[LAME](https://lame.sourceforge.io) (LGPL), [cppjieba](https://github.com/yanyiwu/cppjieba) (MIT),
[KaTeX](https://katex.org) (MIT).

**iOS** — [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic),
[SwiftMath](https://github.com/mgriebling/SwiftMath),
[RealTimeCutVADLibrary](https://github.com/helloooideeeeea/RealTimeCutVADLibrary) (all MIT),
[swift-cmark](https://github.com/swiftlang/swift-cmark) (BSD-2-Clause), and the
Apple / Swift Server Workgroup packages (Apache-2.0).

**Android** — [AndroidX & Jetpack Compose](https://developer.android.com/jetpack),
[OkHttp](https://square.github.io/okhttp/), [Coil](https://coil-kt.github.io/coil/),
[kotlinx](https://github.com/Kotlin) serialization & coroutines,
[multiplatform-markdown-renderer](https://github.com/mikepenz/multiplatform-markdown-renderer),
[Reorderable](https://github.com/Calvin-LL/Reorderable), [ACRA](https://github.com/ACRA/acra)
(all Apache-2.0), and [Shizuku](https://github.com/RikkaApps/Shizuku-API) (MIT).

---

## License

Pico is licensed under the **[GNU General Public License v3.0](LICENSE)**, as OpenMinis is.
It is a modified version of OpenMinis; the changes since 2026-10-17 are in this repository's
history.

The app links GPL-licensed components — [iSH](https://github.com/OpenMinis/ish-arm64)
(GPLv3) and [PRoot](https://github.com/OpenMinis/proot) (GPLv2) — so the combined
work is distributed under GPLv3. Bundled third-party licenses are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

---

## Contributing

[Issues](https://github.com/NoSugarCoffee/Pico/issues) and
[pull requests](https://github.com/NoSugarCoffee/Pico/pulls) are welcome at NoSugarCoffee/Pico. See
[CONTRIBUTING.md](CONTRIBUTING.md).
