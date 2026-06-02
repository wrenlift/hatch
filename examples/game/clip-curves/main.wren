// clip-curves — sample three Clip flavours of the same two
// keyframes [0, 0] → [1, 100] at fixed t-steps. Shows how step
// holds, linear ramps, and cubic-Hermite eases (with explicit
// in/out tangents that match glTF's CUBICSPLINE shape).

import "@hatch:game" for Clip

// Same data shape across all three; just the per-track
// interpolation kind differs.
var tracks = {"y": [[0, 0], [1, 100]]}
var cubicTracks = {"y": [[0, 0, 0, 200], [1, 100, 0, 0]]}   // out-tan 200 → eases up fast

var linClip  = Clip.new("lin", 1.0, tracks)
var stepClip = Clip.withInterpolations("step", 1.0, tracks, {"y": "step"})
var cubicClip = Clip.withInterpolations("cubic", 1.0, cubicTracks, {"y": "cubic"})

System.print("   t  | linear  | step    | cubic")
System.print("------+---------+---------+--------")
var i = 0
while (i <= 10) {
  var t = i / 10
  var l = linClip.sample(t)["y"]
  var s = stepClip.sample(t)["y"]
  var c = cubicClip.sample(t)["y"]
  System.print("  %(t)  | %(l) | %(s) | %(c)")
  i = i + 1
}
