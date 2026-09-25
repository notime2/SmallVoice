# SmallVoice

[Русская версия](README.ru.md)

SmallVoice is native dictation for macOS that lives in the menu bar. Hold a key, speak, and the text
appears wherever your cursor is. Speech is recognized on your Mac by
[Parakeet Redux](https://huggingface.co/moondream/parakeet-redux), a 1.58-bit version of NVIDIA
Parakeet TDT 0.6B v3: 25 languages including English and Russian, with punctuation and casing.
Nothing leaves your computer.

## Using it

| You do | SmallVoice does |
|---|---|
| Hold the right ⌥ key and speak | Records while the key is down and inserts the text when you let go (push-to-talk) |
| Tap the right ⌥ key | Keeps listening hands-free (a lock shows in the indicator); tap again to finish |
| Press Esc while recording | Cancels without inserting anything |
| Press ⌥ with another key | Nothing: your usual shortcuts keep working |

- The key can be changed in Settings: right ⌘, Fn (🌐) or any shortcut you record.
- While it listens and thinks, a small Liquid Glass capsule sits at the bottom of the screen: a live
  voice level, then a soft travelling wave, then a checkmark.
- Text goes in through the clipboard, and your previous clipboard contents come back right after.
  Smart spacing adds a space when you continue a sentence.
- The menu keeps your last 10 dictations; click one to copy it.
- Long dictations are cut into pieces of up to 30 seconds at the pauses found by the model's own
  voice-activity head, and those pieces are recognized while you are still talking, so the wait
  after you release the key stays short.

## Requirements

- macOS 26 or later on Apple silicon
- To build: Xcode 26 or later with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)
  and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Installing a release

SmallVoice is not signed with an Apple Developer ID and not notarized: the project has no paid Apple
Developer account. macOS therefore refuses to open a downloaded copy until you allow it once.

1. Download `SmallVoice.dmg` from the Releases page, open it and drag SmallVoice to Applications.
2. Remove the download quarantine:

   ```bash
   xattr -dr com.apple.quarantine /Applications/SmallVoice.app
   ```

   Without Terminal: open SmallVoice, close the warning, then click "Open Anyway" in System Settings ->
   Privacy & Security.

Without a stable signature every new version is a new app to macOS. After updating, allow the
microphone again, and in System Settings -> Privacy & Security -> Accessibility remove the old
SmallVoice entry and switch the new one on.

## Building from source

```bash
make install    # Release build copied to /Applications and launched
make test       # engine tests (the transcription tests need the downloaded model)
make build      # Debug build in build/DerivedData
make dmg        # build/SmallVoice.dmg from the Release build
```

Builds are signed ad hoc by default, so no Apple developer account is needed. macOS then treats
every rebuild as a new app and asks for Microphone and Accessibility access again. To keep those
grants, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` (ignored by git) and set your
team and bundle identifier there. A free Apple Development certificate from Xcode is enough.

## First launch

A setup window asks for:

- microphone access;
- Accessibility access (System Settings -> Privacy & Security -> Accessibility), which the shortcut
  and text insertion need;
- a one-time download of the speech model (178 MB).

The model is downloaded from Hugging Face at a pinned revision, checked against its SHA-256 and kept
in `~/Library/Application Support/SmallVoice/Models/`.

## Making a release

`make dmg` builds `build/SmallVoice.dmg` from the Release build. CI (GitHub Actions, Xcode 26) also runs
the engine unit tests and uploads that ad-hoc signed image as a build artifact. That image is what
gets published, together with the install steps above.

With a Developer ID certificate, `scripts/notarize.sh` would sign and notarize the image so it opens
anywhere without those steps:

```bash
xcrun notarytool store-credentials SmallVoice --apple-id you@example.com --team-id ABCDE12345
DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)" scripts/notarize.sh
```

## How it works

```
Packages/ParakeetKit/   speech engine on MLX (Metal GPU), independent of the app
  Weights.swift         ternary weights repacked losslessly into MLX's 2-bit quantization
  Features.swift        log-mel features
  Encoder.swift         subsampling, 24 FastConformer blocks, the voice-activity head
  Decoder.swift         LSTM prediction network and greedy TDT decoding
  Segmenter.swift       cutting long audio at pauses
  ParakeetEngine.swift  actor: loading, warm-up, transcription
SmallVoice/                 the app (SwiftUI and AppKit)
  Dictation/            the hotkey state machine, microphone capture, text insertion
  Input/                hotkeys and permissions
  Model/                model download and verification
  UI/                   the indicator, menu, settings and first-run window
```

ParakeetKit is a Swift implementation of the Parakeet TDT architecture (as published in NVIDIA NeMo
and Hugging Face transformers) for this checkpoint's ternary weight format. Every encoder weight of
Parakeet Redux is -1, 0 or +1 times a per-group scale, which maps exactly onto MLX's 2-bit affine
quantization, so the weights take about 150 MB of memory and run through MLX's quantized matmul.

During development its output was checked against Photon, Moondream's own runtime, and matched it
character for character. The test suite checks:

- the weight repacking bit for bit;
- the log-mel features against an independent librosa computation;
- transcripts of English, Russian and mixed long-form Common Voice clips (CC0), against the spoken
  sentences and against a pinned snapshot.

Speed on an M3 Pro (Release build):

| Audio | Time to text |
|---|---|
| 5.3 s | 60 ms |
| 8.3 s | 79 ms |
| 41.9 s | 405 ms |

Loading the model with its warm-up pass takes about 0.4 s. While idle the app uses no CPU and about
250 MB of memory, most of it the model weights.

### Debug flags

```bash
SmallVoice.app/Contents/MacOS/SmallVoice --transcribe a.wav b.m4a   # transcribe files and report speed
open SmallVoice.app --args --hud-demo [recording|hands-free|processing|success|message]
open SmallVoice.app --args --onboarding
```

## How it compares

SmallVoice is not the only free dictation for the Mac. Every app below keeps speech on your Mac; the
differences are the models they run, what is built around them, and what they cost.

| App | Licence | Speech models | Platforms | In short |
|---|---|---|---|---|
| **SmallVoice** | MIT | Parakeet Redux (1.58-bit Parakeet TDT 0.6B v3), a 178 MB download | macOS 26+, Apple silicon | GPU through MLX: tens of milliseconds per dictation and about 250 MB of memory, 25 languages. Deliberately minimal: no AI rewriting, no cloud, no accounts |
| [FluidVoice](https://github.com/altic-dev/FluidVoice) | GPL-3.0 | Parakeet TDT v3 and v2, Parakeet Flash, Nemotron, Cohere, Whisper, Apple Speech | macOS 15+, Apple silicon (Windows and iOS planned) | The closest all-rounder: more models (250 MB to 3.5 GB), live preview, command and write modes, optional local or cloud AI cleanup |
| [EnviousWispr](https://github.com/saurabhav88/EnviousWispr) | GPL-3.0 | Parakeet TDT v3 (CoreML on the Neural Engine), WhisperKit Large v3 Turbo | macOS 14+, Apple silicon | Parakeet v3 plus optional on-device polishing (its own EG-1 model is not open source); Whisper brings 99 languages |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | GPL-3.0 source, the compiled build is paid | Whisper (whisper.cpp), Parakeet (FluidAudio), SenseVoice | macOS 15+ | The most configurable: per-app modes, context awareness, cloud providers. Free if you build it yourself |
| [OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) | MIT | Whisper (whisper.cpp), Parakeet (FluidAudio) | macOS, Apple silicon | Hold-to-record from a key or a mouse button, a queue for audio files |
| [Handy](https://github.com/cjpais/Handy) | MIT | Whisper (whisper.cpp), Parakeet v3 (GGUF) | macOS, Windows, Linux | The cross-platform one, built with Rust and Tauri; downloads start around 490 MB and go up |
| [superwhisper](https://superwhisper.com) | freemium | local Whisper models only on the free plan | macOS, Windows, iOS, Android | Unlimited private dictation for free, but Parakeet, cloud models and AI modes are Pro |
| [MacWhisper](https://www.macwhisper.com/) | freemium | Whisper, Parakeet | macOS | Built around transcribing files and meetings rather than live dictation; the free tier stops at the small Whisper models |
| macOS Dictation | free, built in | Apple's speech model | macOS | Nothing to install, and mostly on-device on Apple silicon, but there is no model choice and little to control |

Most of these run Whisper: up to 99 languages, at the cost of a few hundred megabytes to a few
gigabytes and GPU inference. Parakeet TDT v3 covers 25 languages in a much smaller model. SmallVoice
goes one step further: Parakeet Redux keeps every encoder weight at -1, 0 or +1, so the whole model is
178 MB and runs on MLX's 2-bit kernels, which is why a dictation takes tens of milliseconds and the app
idles at about 250 MB.

What SmallVoice leaves out is also the point: no AI rewriting, no per-app modes, no cloud providers,
no Windows or Linux build, and it asks for macOS 26. If those matter to you, FluidVoice, EnviousWispr
and VoiceInk are the natural places to look.

## Privacy

Audio is captured only while you dictate and is never written to disk. Recognition runs locally.
The only network access is the one-time model download from Hugging Face. Recent dictations are
kept in memory and are gone when you quit.

## License and credits

SmallVoice is released under the [MIT License](LICENSE).

- Speech model: [Parakeet Redux](https://huggingface.co/moondream/parakeet-redux) by Moondream, based
  on [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), licensed under
  [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). The model is not included in this
  repository; the app downloads it.
- [mlx-swift](https://github.com/ml-explore/mlx-swift) (MIT), which brings in
  [swift-numerics](https://github.com/apple/swift-numerics) and
  [swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache-2.0).
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (MIT).
- Test audio: [Mozilla Common Voice](https://commonvoice.mozilla.org) clips, CC0 1.0; see
  [Packages/ParakeetKit/Tests/ParakeetKitTests/Fixtures/SOURCES.md](Packages/ParakeetKit/Tests/ParakeetKitTests/Fixtures/SOURCES.md).
