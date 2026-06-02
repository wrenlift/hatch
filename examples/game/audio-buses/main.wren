// audio-buses — open the audio context, set per-bus volumes,
// optionally play a one-shot. Music + SFX + UI + master are
// independent scalars; master multiplies after every per-bus
// scalar, so it's the global volume slider every game ships.

import "@hatch:audio" for Audio, Sound

Audio.context()

// Settings-panel-style: pull current volumes, mutate them, read
// back to confirm. Defaults are all 1.0 (unity).
var master = Audio.group("master")
var music  = Audio.group("music")
var sfx    = Audio.group("sfx")
System.print("Defaults: master=%(master.volume) music=%(music.volume) sfx=%(sfx.volume)")

master.volume = 0.8
music.volume  = 0.4
sfx.volume    = 1.0
System.print("After settings: master=%(master.volume) music=%(music.volume) sfx=%(sfx.volume)")

// Sound.load accepts WAV or OGG bytes. A real game would read
// from @hatch:assets; we ship a 1-sample silent WAV inline so the
// example runs without external data.
var wav = [
  // "RIFF" + size 38
  82, 73, 70, 70, 38, 0, 0, 0,
  // "WAVE" "fmt " size 16 PCM mono 44.1kHz 88.2k Bps 2 16
  87, 65, 86, 69, 102, 109, 116, 32, 16, 0, 0, 0,
  1, 0, 1, 0, 68, 172, 0, 0, 136, 88, 1, 0, 2, 0, 16, 0,
  // "data" size 2 + one silent sample
  100, 97, 116, 97, 2, 0, 0, 0, 0, 0
]
var snd = Sound.load(wav)
Audio.play(snd, {"group": "sfx", "volume": 1.0})
System.print("Played one shot on the SFX bus; voices active = %(Audio.activeVoices)")
Audio.stopAll()
