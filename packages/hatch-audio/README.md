General-purpose audio playback for WrenLift apps. A cpal-backed output stream feeds a small voice mixer; WAV bytes decode through hound. `Audio.context()` opens the device, `Sound.load(bytes)` decodes a clip, and `Audio.play(sound)` schedules an immediate voice on the global mixer.

## Overview

Two surfaces and a global mixer behind them. Open the output once at startup, decode each clip once, then schedule voices on top — every `play` call spawns a fresh voice, so overlapping triggers stack the way you want for impacts, footsteps, or UI clicks.

```wren
import "@hatch:audio"  for Audio, Sound
import "@hatch:assets" for Assets

Audio.context()

var assets = Assets.open("assets")
var bang   = Sound.load(assets.bytes("sfx/bang.wav"))

Audio.play(bang)
Audio.play(bang, { "volume": 0.6 })
Audio.play(bang, { "loop": true })
```

`Audio.stopAll()` hard-cuts every active voice; the loaded `Sound` records stay live in the PCM cache until you call `sound.unload`. `Audio.activeVoices` reports the live voice count, which is enough to cap concurrency from the game side without reaching for a separate scheduler.

> **Note — WAV only, today**
> Decoding goes through hound, so input must be WAV. Convert MP3 / OGG / FLAC during the build. Native multi-format decode is planned but not in this release.

> **Warning — sample-rate mismatch shifts pitch**
> The mixer resamples nearest-neighbour. If the clip's sample rate differs from the device's preferred rate, expect audible pitch shift. Pre-resample assets to a common rate (44.1 or 48 kHz) until the higher-quality resampler lands.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only — `#!wasm` builds skip this package; route browser audio through `@hatch:web`'s WebAudio bridge instead.
