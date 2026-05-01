// `@hatch:audio` — playback for WrenLift apps.
//
// ```wren
// import "@hatch:audio"  for Audio, Sound
// import "@hatch:assets" for Assets
//
// Audio.context()                       // open the output stream
//
// var assets = Assets.open("assets")
// var bang   = Sound.load(assets.bytes("bang.wav"))
//
// // Trigger a one-shot. Each play() schedules a fresh voice;
// // overlapping triggers naturally stack.
// Audio.play(bang)
// Audio.play(bang, {"volume": 0.6})
// Audio.play(bang, {"loop": true})         // loops until stopped
//
// // Hard cut every active voice.
// Audio.stopAll()
// ```
//
// Backed by cpal for the output stream + hound for WAV decode.
// Output is f32 stereo at the device's preferred sample rate.
// MP3 / OGG / FLAC support is on the v0+ list; until then,
// convert assets to WAV during the build.
//
// Known limitation: source rate ≠ device rate causes pitch
// shift. A higher-quality resampler will replace the naive
// nearest-neighbour pass.

#!native = "wlift_audio"
foreign class AudioCore {
  #!symbol = "wlift_audio_context_init"
  foreign static contextInit()

  #!symbol = "wlift_audio_sound_load"
  foreign static soundLoad(bytes)

  #!symbol = "wlift_audio_sound_unload"
  foreign static soundUnload(id)

  #!symbol = "wlift_audio_play"
  foreign static play(id, options)

  #!symbol = "wlift_audio_stop_all"
  foreign static stopAll()

  #!symbol = "wlift_audio_active_voices"
  foreign static activeVoices()
}

class Audio {
  /// Open the default output device + start the mixer thread.
  /// Idempotent — subsequent calls are no-ops. Aborts the fiber
  /// if the host has no usable output device.
  static context() { AudioCore.contextInit() }

  /// Trigger immediate playback.
  ///
  /// | Option   | Type   | Notes                  |
  /// |----------|--------|------------------------|
  /// | `volume` | `Num`  | In `0..=1`, default 1. |
  /// | `loop`   | `Bool` | Default `false`.       |
  static play(sound) { play(sound, {}) }
  static play(sound, options) {
    if (!(options is Map)) options = {}
    AudioCore.play(sound.id, options)
  }

  /// Stop every active voice. Sources stay loaded; only the live
  /// voices are cleared.
  static stopAll() { AudioCore.stopAll() }

  /// Number of voices currently playing — useful for diagnostics
  /// and for capping concurrent plays from the game side.
  static activeVoices { AudioCore.activeVoices() }
}

class Sound {
  /// Decode a WAV byte buffer into a Sound. Pixels live in the
  /// mixer's PCM cache for the lifetime of the process unless
  /// explicitly unloaded.
  static load(bytes) { Sound.new_(AudioCore.soundLoad(bytes)) }

  construct new_(id) { _id = id }

  id { _id }

  /// Drop the underlying sample buffer. After unload, the Sound's
  /// id is invalid — passing it to Audio.play surfaces a runtime
  /// error. Idempotent.
  unload {
    AudioCore.soundUnload(_id)
    _id = -1
  }

  toString { "Sound(%(_id))" }
}
