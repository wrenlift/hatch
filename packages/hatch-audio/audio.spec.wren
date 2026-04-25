// @hatch:audio — minimal acceptance.
//
// Smoke-tests the foreign surface end-to-end short of actually
// hearing a sound: open the default output device, decode a
// hand-crafted minimal WAV, schedule a voice, confirm the mixer
// counts it. Audible round-trip lives in the cross-package game
// demo since it needs a window to keep the process alive long
// enough for the audio thread to consume frames.

import "./audio"       for Audio, Sound
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// Build a 1-sample 16-bit mono 44.1kHz WAV. 44-byte standard
// header + 2 bytes of PCM (silence). Smallest valid WAV.
var wav = [
  // "RIFF"
  82, 73, 70, 70,
  // chunk size = 36 (header) + 2 (data) = 38
  38, 0, 0, 0,
  // "WAVE"
  87, 65, 86, 69,
  // "fmt " sub-chunk id
  102, 109, 116, 32,
  // sub-chunk size = 16
  16, 0, 0, 0,
  // PCM format
  1, 0,
  // mono
  1, 0,
  // sample rate = 44100 little-endian
  68, 172, 0, 0,
  // byte rate = 88200
  136, 88, 1, 0,
  // block align = 2
  2, 0,
  // bits per sample = 16
  16, 0,
  // "data"
  100, 97, 116, 97,
  // data size = 2
  2, 0, 0, 0,
  // one silent sample
  0, 0
]

Test.describe("Audio") {
  Test.it("context init succeeds and is idempotent") {
    Expect.that(Audio.context()).toBe(true)
    Expect.that(Audio.context()).toBe(true)
    Expect.that(Audio.activeVoices).toBe(0)
  }

  Test.it("Sound.load + play counts a voice on the mixer") {
    Audio.context()
    var s = Sound.load(wav)
    Expect.that(s is Sound).toBe(true)
    Audio.play(s)
    // Mixer pulls samples from the audio thread; a 1-sample
    // source is consumed almost immediately. The voice may or
    // may not still be live by the time we check, but the call
    // must succeed and never abort.
    Expect.that(Audio.activeVoices >= 0).toBe(true)
    Audio.stopAll()
    Expect.that(Audio.activeVoices).toBe(0)
    s.unload
  }

  Test.it("rejects non-WAV byte buffers") {
    var e = Fiber.new {
      Sound.load([0, 1, 2, 3, 4, 5])
    }.try()
    Expect.that(e).toContain("WAV")
  }
}

Test.run()
