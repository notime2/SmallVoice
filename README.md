# SmallVoice

[Русская версия](README.ru.md)

SmallVoice is native dictation for macOS that lives in the menu bar. Hold a key, speak, and the text
appears wherever your cursor is. Speech is recognized on your Mac by
[Parakeet Redux](https://huggingface.co/moondream/parakeet-redux), a 1.58-bit version of NVIDIA
Parakeet TDT 0.6B v3: 25 languages including English and Russian, with punctuation and casing.
Nothing leaves your computer.

![SmallVoice dictating into TextEdit: hold the key, speak, and the text appears at the cursor](docs/demo.gif)

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

SmallVoice is not the only free dictation for the Mac. What decides the choice fits into four measures:
model size on disk, speed, memory and accuracy. Sizes were measured on disk or taken from each
project's documentation, the engine figures come from the
[Parakeet Redux model card](https://huggingface.co/moondream/parakeet-redux), and one row was measured in
this project on an M3 Pro.

### The engines, and the apps that ship them

Every Parakeet app below runs the same 0.6B network; what changes is the package it runs through and the
weight format. Parakeet Redux, the one SmallVoice uses, stores every encoder weight as -1, 0 or +1.

| Engine (package) | Weights | Real time (audio seconds per second of wall clock) | Shipped by |
|---|---|---|---|
| **Parakeet Redux in MLX, ternary** | **178 MB**, 171 MiB measured on disk | **88x to 105x**, measured here on an M3 Pro | **SmallVoice** |
| Parakeet Redux in Photon, the model's own runtime | 178 MB | 38x on the CPU, 43x on the GPU | Moondream's Python package; no app in this list |
| Parakeet TDT v3 in CoreML, through FluidAudio | 461 MiB measured on disk | not published | FluidVoice, VoiceInk, OpenSuperWhisper, EnviousWispr |
| Parakeet TDT v3 in ONNX Runtime, through transcribe-rs | 0.67 GB, int8 | 28x to 33x on the CPU | Handy |
| Whisper-family models in ggml, through whisper.cpp or transcribe.cpp | 75 MB to 2.9 GB | not published | Handy, VoiceInk, OpenSuperWhisper, FluidVoice |
| WhisperKit on CoreML | 1.6 GB for Large v3 Turbo | not published | EnviousWispr |
| Apple Speech | built in | not published | macOS Dictation, and FluidVoice as an option |
| parakeet.cpp, q8_0 | 0.94 GB | 12x on the CPU, 38x on the GPU | - |
| parakeet.cpp, f16 | 1.44 GB | 9x on the CPU, 39x on the GPU | - |
| parakeet-mlx, fp32 | 2.51 GB | 37x on the GPU | - |

Apart from the first row, the figures are Moondream's, measured on an M2 MacBook Air. A dash means that no
app in this list documents that build; superwhisper and MacWhisper run local Whisper models but do not
document their runtime. The original fp16 weights of this network are 1.2 GB.

### What the smaller weights cost in accuracy

Word error rate in percent, lower is better, from the same model card:

| Benchmark | parakeet-tdt-0.6b-v3, 1.2 GB | Parakeet Redux, 178 MB |
|---|---|---|
| Open ASR Leaderboard, 7 English sets | **6.26** | 6.55 |
| FLEURS, 25 languages | 11.62 | **10.56** |
| TED-LIUM, 11 full talks | 2.71 | **2.51** |
| Business speech (calls, meetings) | **6.15** | 6.96 |
| With background noise (MUSAN) | **6.72** | 9.04 |

### The apps

| App | Engine | Speech model | Languages | Price | Licence | Platforms |
|---|---|---|---|---|---|---|
| **SmallVoice** | Parakeet Redux on MLX | **178 MB** (171 MiB on disk) | 25 | free | MIT | macOS 26+, Apple silicon |
| [FluidVoice](https://github.com/altic-dev/FluidVoice) | FluidAudio CoreML, transcribe.cpp, Apple Speech | 250 MB to 2.9 GB, about 500 MB for Parakeet TDT v3 | 25, or 99 through Whisper | free | GPL-3.0 | macOS 15+, Apple silicon |
| [EnviousWispr](https://github.com/saurabhav88/EnviousWispr) | FluidAudio CoreML, WhisperKit | 461 MiB, or 1.6 GB with WhisperKit | 25, or 99 through Whisper | free | GPL-3.0 | macOS 14+, Apple silicon |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | whisper.cpp, FluidAudio CoreML, transcribe.cpp | 461 MiB, or 75 MB to 2.9 GB with Whisper | 25, or 99 through Whisper | paid build, free from source | GPL-3.0 | macOS 15+ |
| [OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) | whisper.cpp, FluidAudio CoreML | 461 MiB, or 75 MB to 2.9 GB with Whisper | 25, or 99 through Whisper | free | MIT | macOS, Apple silicon |
| [Handy](https://github.com/cjpais/Handy) | transcribe.cpp on ggml, transcribe-rs on ONNX Runtime | 731 MB for Parakeet, or 487 MB to 1.6 GB with Whisper | 25, or 99 through Whisper | free | MIT | macOS, Windows, Linux |
| [superwhisper](https://superwhisper.com) | not documented, local Whisper on the free plan | not published | 99 | free, Pro from $8.49 a month | proprietary | macOS, Windows, iOS, Android |
| [MacWhisper](https://www.macwhisper.com/) | not documented, small Whisper models in the free tier | not published | 99 | free, Pro from €59 | proprietary | macOS |
| macOS Dictation | Apple Speech | built in | system languages | free | proprietary | macOS |

Whisper model sizes are the standard whisper.cpp set; Whisper is what buys 99 languages, at the price of
a few hundred megabytes to a few gigabytes and GPU inference. The ternary weights are not free either:
0.29 WER behind the 1.2 GB original on the seven English sets, and further behind in noise, but ahead of
it on FLEURS and on full-length talks. In this app they take about 150 MB of the roughly 250 MB held
while idle, and a 5.3 s dictation comes back in 60 ms.

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
