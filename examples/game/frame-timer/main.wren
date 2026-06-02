// frame-timer — feed synthetic dt into FrameTimer and read FPS,
// avg ms, and the 1%-low. Mirrors what DebugOverlay does each
// frame inside a real game-loop: ingest g.dt, surface live stats
// in an F12-style panel.

import "@hatch:game" for FrameTimer

var ft = FrameTimer.new(100)

// Simulate 60-fps frames for two seconds (200 ticks > capacity).
var i = 0
while (i < 200) {
  ft.tick(0.0166)
  i = i + 1
}
// Inject a few stutters.
ft.tick(0.05)
ft.tick(0.08)

System.print("Window: %(ft.count)/%(ft.capacity)")
System.print("Avg ms: %(ft.avgMs)")
System.print("FPS:    %(ft.fps)")
System.print("1%% low: %(ft.lowFps)")

// After a reset the stats clear out — useful right after a long
// load to drop the spike from the averages.
ft.reset
System.print("\nAfter reset:")
System.print("  count = %(ft.count), fps = %(ft.fps)")
