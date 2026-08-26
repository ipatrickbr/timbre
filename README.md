# Timbre

Records the audio playing **inside** your Mac and saves it as an MP3.

Built for recording talks, public hearings and live calls you are watching:
the sound is captured from the system itself, never through a microphone, so
you get the clean feed instead of the room. You keep listening normally —
speakers or headphones — and the output volume does not affect the recording.

No BlackHole, no Loopback, no virtual audio driver.

![The Timbre icon](icon/preview.png)

The icon uses the South China Morning Post palette: navy ground, gold recording bar.

## The guide

[Timbre-Guide.pdf](Timbre-Guide.pdf) walks a non-technical colleague through
installation and use, with a screenshot of every button. It is written for the
SCMP newsroom and asks readers not to pass the app outside it.

It also carries a page on the **SCMP Editorial Generative AI Policy**, setting
out where Timbre already answers what the policy asks for, chiefly that nothing
is uploaded and that the audio, transcript and timestamps stay together, and
what still falls to the reporter: the transcript is not a citable source, quotes
are confirmed against the audio, and editors are told when AI has been involved.

## Requirements

- macOS 14.4 or later (Core Audio process taps)
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/ipatrickbr/timbre.git
cd timbre
./vendor/build-lame.sh   # builds the MP3 encoder (~1 min)
./build.sh               # builds Timbre.app into ~/Applications
```

Open Timbre from Launchpad. macOS will ask for permission the first time —
approve it under **System Settings › Privacy & Security › Screen & System
Audio Recording**.

Optionally drag the app to the Dock: clicking its icon starts and stops
recording, same as the menu bar icon.

## Using it

Click the waveform icon in the menu bar:

- **Idle** → asks how to record: keeping the audio audible, or silently
- **Recording** → offers *Pause recording* and *Finish and save*
- **Paused** → the icon turns orange and the clock freezes

When you finish, a panel shows the encoding progress with a real percentage
and time estimate, then the destination folder opens with the file selected.
Recordings land in a **Timbre** folder on the Desktop.

Two short marimba cues mark the start (rising) and the end (falling) of a
recording. They are excluded from the capture, so they never end up in the file.

### From the terminal

```bash
./timbre talk.mp3            # record until Ctrl+C
./timbre -d 3600 talk.mp3    # stop automatically after an hour
./timbre --mute talk.mp3     # record with the speakers silent
./timbre --keep-wav talk.mp3 # also keep the lossless WAV
./timbre -b 320 talk.mp3     # bitrate (default 192)
```

## Transcription (optional)

Timbre can transcribe a recording the moment it finishes, entirely offline,
using [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with Metal
acceleration. Install it once:

```bash
./vendor/build-whisper.sh
```

That builds the engine and downloads two models into `~/Library/Application
Support/Timbre/whisper`: `large-v3-turbo` (~1.5 GB) for transcription, and
`small` (~470 MB) for translation. The turbo models are trained for
transcription only and silently return the original language when asked to
translate, which is why a second model is needed.

After that, every time a recording finishes Timbre asks whether you want a
transcript, with an estimate of how long it will take. Say yes and you get a
`.txt` next to the MP3, plus a `.srt` with timestamps. Say no and nothing else
happens.

Measured on an M4: **8x faster than real time**, so an hour of audio transcribes
in about seven minutes. The language is detected automatically, and when it is
not English, Timbre offers an English translation as a second pass. Treat those
translations as a way to navigate the material rather than as quotable text.

The point is not only convenience. Uploading audio to a cloud transcription
service means handing the material to a third party; here nothing leaves the
machine, which matters for embargoed or sensitive recordings.

## Language

The interface ships in **English** and **Brazilian Portuguese**, following the
system language. To pin one app to a specific language regardless of the
system:

```bash
defaults write local.timbre AppleLanguages -array pt-BR
```

Use `-array en` to switch back. Translations live in `lang/*.lproj`.

## How it works

**Capture** — a Core Audio process tap intercepts the system audio mix *before
the output volume stage*. That is why the recording always comes out at full
level, even with the Mac turned down, on headphones, or muted. The tap excludes
Timbre's own process so its sound cues stay out of the file.

Passing `--mute` creates the tap with `mutedWhenTapped`, recording without
anything reaching the speakers.

**Encoding** — macOS decodes MP3 but cannot encode it, so LAME is built locally
by `vendor/build-lame.sh` and bundled into the app. Progress comes from LAME's
own frame counter, not from an estimate.

`--sck` switches to a ScreenCaptureKit backend as a fallback. It cannot mute
the output, but it is there if the tap ever fails.

## Behaviour worth knowing

- Recording starts at the **first sound**. The tap idles while nothing plays,
  so leading silence never reaches the file. No audio is lost — silence in the
  middle of a recording is preserved.
- If nothing plays at all, no file is written.
- One hour of recording uses roughly 700 MB of temporary WAV, ending as about
  86 MB of MP3.
- The app is ad-hoc signed. Rebuilding changes the signature, so macOS may ask
  for the permission again.
- **Reopen the app after every build** — the running process keeps the old
  binary in memory.

## Layout

```
main.swift     command line entry point and routing
tap.swift      TapRecorder: capture through a Core Audio process tap
menubar.swift  menu bar icon, dialogs and progress panel
sck.swift      ScreenCaptureKit backend (--sck)
transcribe.swift  offline transcription through whisper.cpp
lang/          English and Portuguese translations
icon/          icon generator (CoreGraphics) and AppIcon.icns
sounds/        marimba cue synthesis and the WAVs
vendor/        builds LAME locally
build.sh       compiles, signs and installs into ~/Applications
timbre         terminal wrapper: records and converts to MP3
```

## Licence

Timbre's own source is MIT — see [LICENSE](LICENSE).

MP3 encoding uses [LAME](https://lame.sourceforge.io/), which is LGPL 2.1 and
is **not** distributed here: `vendor/build-lame.sh` downloads and builds it on
your machine, verifying the official checksum. If you redistribute a built
`Timbre.app`, you are also redistributing LAME and must comply with the LGPL.
