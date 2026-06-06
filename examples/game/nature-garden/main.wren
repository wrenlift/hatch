// Nature Garden — cel-shaded forest clearing with a winding
// walk path.
//
//   wlift main.wren
//
// Loads a curated set of Quaternius nature-kit archetypes
// (trees, rocks, bushes, plants, mushrooms, flowers, stones)
// and scatters a small number of large props across a
// sandy-tan clearing with a sinusoidal dirt track carved
// through. The remaining ground fills with 50,000 toon-shaded
// grass blades. Mouse: left-drag orbits, scroll zooms.
//
// Prop scatter is intentionally sparse (≤ 12 each for props +
// stones) — the underlying renderer's per-draw UBO pool +
// runtime allocator interact badly above ~20 individual draw
// calls per frame on this platform, so the demo restricts
// per-frame draws to that safe envelope rather than crashing
// downstream. Grass blades use a single instanced draw, which
// is safe at the 50k-instance scale.

import "@hatch:game"   for Game, Foliage, Actions, PostFX, GpuParticleSystem3D, Particles
import "@hatch:gpu"    for Renderer3D, Camera3D, Mesh, Material
import "@hatch:math"   for Vec2, Vec3, Vec4, Mat4
import "@hatch:gltf"   for Gltf
import "@hatch:assets" for Assets
import "@hatch:image"  for Image
import "@hatch:fsm"    for StateChart
import "@hatch:noise"  for Noise
import "@hatch:postfx" for SkyPass, OutlinePass, Bloom

class NatureGarden is Game {
  construct new() {}

  config { {
    "title":      "Nature Garden — Walk Path",
    "width":      1280,
    "height":     720,
    "clearColor": [0.66, 0.82, 0.95, 1.0],
    "depth":      true
  } }

  // Curve sampling the walk path: x(z) = amp * sin(z * freq).
  pathX(z) { 4.0 * (z * 0.18).sin }
  pathHalfWidth { 1.6 }

  // Two-octave simplex heightmap. Soft rolling hills bounded so
  // the orbit camera doesn't clip props at the peaks. Shared by
  // the terrain mesh, prop placement, grass, and path stones so
  // everything sits on the same surface.
  heightAt(x, z) {
    var a = Noise.simplex2(x * 0.05, z * 0.05, 4242) * 0.90
    var b = Noise.simplex2(x * 0.16, z * 0.16, 9999) * 0.30
    return a + b
  }

  // Organic-blob edge radius at angle theta. baseRadius + radial
  // simplex noise gives a roughly round shape with lobes and
  // indents instead of a perfect disc. Used by both the terrain
  // mesh edge AND the scatter clip so every prop sits inside the
  // shape the ground actually covers.
  edgeRadius(theta) {
    var ca = theta.cos
    var sa = theta.sin
    var n = Noise.simplex2(ca * 1.6, sa * 1.6, 5151)
    return 21.0 + n * 3.0
  }

  // Density caps. Big props (trees + boulders) get a lower
  // cap with bigger spacing; ground foliage (bushes, ferns,
  // mushrooms, flowers, ground-grass tufts) uses its own
  // dense scatter so the small stuff isn't starved by the
  // tree picks that the original single-bucket hash kept
  // hogging. Renderer3D pre-allocates 256 per-draw UBO slots
  // so even the combined 48 + 90 = 138 individual draws fit.
  propCap    { 48 }
  // foliageCap 90 → 220 — boosted to support meadow-density
  // grass tufts (the 70%-grass pattern below puts ~150 tufts
  // in the field with this cap, vs ~45 at cap=90).
  foliageCap { 220 }
  stoneCap   { 24 }
  // petalCap 1400 → 200: each petal is a non-instanced draw,
  // and Renderer3D's per-draw UBO pool is ~256. At 1400 we were
  // 5-12x past the safe ceiling, dominating the per-frame CPU
  // dispatch time. Drops frame time ~42 ms → ~12-15 ms. Proper
  // fix is batching via drawMeshInstanced like the grass field.
  petalCap   { 200 }

  setup(g) {
    var aspect = g.width / g.height
    _camera = Camera3D.perspective(55, aspect, 0.1, 200)
    // 4-arg form opts the renderer into MRT mode — the fragment
    // shader writes per-pixel world-space normals into the
    // secondary attachment OutlinePass samples for its Sobel
    // pass. Format must match `PostFX.new`'s normalFormat opt.
    _renderer3d = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat, "rgba8unorm")

    // ----- Orbit camera. Polled via the Actions facade — A/D
    // rotates yaw, W/S tilts pitch, Q/E zooms. Routing through
    // `Actions.value(name)` means input runs through the framework's
    // pre-allocated per-frame state instead of the per-call
    // `g.input.mouseX` / `g.input.scrollY` reads that were
    // hammering the minor GC and crashing the scene under
    // sustained orbit. StateChart wraps the high-level game
    // flow so `Escape` toggles `playing ↔ paused` without
    // touching the camera reads each frame.
    _yaw      = 0.6
    _pitch    = 0.35
    _distance = 18
    _target   = Vec3.new(0, 2, 0)
    // Mouse-driven orbit. `MouseLeft` is the only Actions binding
    // we need — drag deltas + scroll wheel are continuous channels
    // (not button presses) so they read from `g.input.mouseX/Y`
    // and `g.input.scrollY` directly, gated by the chart state.
    // Keyboard fallbacks stay so the camera works without a mouse
    // (e.g. the wasm playground capturing pointer events for the
    // page scroll).
    Actions.define("orbit.drag",  ["MouseLeft"])
    Actions.define("orbit.left",  ["ArrowLeft"])
    Actions.define("orbit.right", ["ArrowRight"])
    Actions.define("orbit.up",    ["ArrowUp"])
    Actions.define("orbit.down",  ["ArrowDown"])
    // WASD pans the camera TARGET around the disc — yes-W moves
    // the orbit point forward in the camera's facing direction,
    // A/D strafes, S pulls back. Arrows handle rotation so both
    // axes have dedicated bindings.
    Actions.define("pan.forward", ["KeyW"])
    Actions.define("pan.back",    ["KeyS"])
    Actions.define("pan.left",    ["KeyA"])
    Actions.define("pan.right",   ["KeyD"])
    Actions.define("zoom.in",     ["KeyE"])
    Actions.define("zoom.out",    ["KeyQ"])
    Actions.define("pause",       ["Escape"])

    _lastMx = 0
    _lastMy = 0

    // Cache the camera "up" vector so the per-frame lookAt
    // doesn't allocate a new Vec3 every frame. Reduces minor-GC
    // cadence under steady-state allocation pressure.
    _upY = Vec3.new(0, 1, 0)

    // FPS readout to stdout. On-screen HUD would need a
    // Renderer2D, but Renderer2D's pipeline is single-attachment
    // and conflicts with the multi-attachment 3D pass that
    // OutlinePass requires for normal-edge detection. Stdout is
    // the simplest workaround that keeps the outline pipeline.
    _fpsEma       = 60.0
    _lastElapsed  = 0.0
    _fpsPrintTick = 0

    // High-level flow: `idle ↔ dragging` toggles on MouseLeft
    // press / release, and `pause` parks the whole chart. Reading
    // chart state instead of per-frame `g.input.mouseDown` is what
    // pivots the input pipeline onto Actions + StateChart.
    _chart = StateChart.build {|c|
      c.id("garden")
      c.initial("idle")
      c.state("idle") {|s|
        s.on("orbit.drag", "dragging")
        s.on("pause",      "paused")
      }
      c.state("dragging") {|s|
        s.on("orbit.drag.released", "idle")
        s.on("pause",               "paused")
      }
      c.state("paused") {|s|
        s.on("pause", "idle")
      }
    }
    // Include `orbit.drag.released` so the chart sees the
    // mouse-up edge and transitions dragging → idle. Without it
    // the chart got the press but never the release, so the
    // user had to press Escape (pause/unpause) to break out of
    // the drag state.
    _chart.bindEvents(Actions.emitter, ["orbit.drag", "orbit.drag.released", "pause"])
    _chart.start()

    // Lighting + wind (committed per-frame in draw()).
    // Pastel-anime palette tuned for harmony rather than
    // contrast: a warm cream ambient sits in the same hue
    // family as the soil and grass-shadow tones, the key
    // light stays neutral-warm so it doesn't tint the
    // material colours away from their painted palette, and
    // the three-band IBL gradient blends pale sky overhead
    // with a soft cream at the horizon.
    // Warmer, brighter ambient than the cooled-cel-contrast pass
    // — the previous (0.50, 0.46, 0.42) bought a visible cel
    // step at the cost of every prop's shadow side crushing to
    // black. Lifting to (0.72, 0.66, 0.56) keeps the warm/cool
    // hue family for the two-tone but stops the bark + rock
    // textures reading as silhouettes. Sun intensity bumped to
    // 5.0 to keep the lit side from washing into the brighter
    // ambient.
    // Ambient bumped 0.72→0.88 (R/G) and 0.56→0.72 (B) so the
    // unlit / shadow-side cel band carries a warmer cream tone
    // regardless of view angle. Aerial pitch zeroes out the
    // grass rim (fresnel≈0 looking straight down) and pulls the
    // warm horizon sky gradient out of frame, so without a
    // lifted ambient the top-down view reads dimmer than the
    // mid/low orbit where rim + bloom + sky layer in. This
    // gives the scene its painterly cream wash from any angle.
    _ambient      = Vec3.new(0.88, 0.82, 0.72)
    _sunColor     = Vec3.new(1.00, 0.97, 0.88)
    _sunIntensity = 5.0
    // Cool fill light from the camera-opposite side at low
    // intensity — picks the dark sides of barks up enough that
    // tree trunks read as forms rather than silhouettes.
    _fillDir      = Vec3.new(0.40, -0.30, 0.30)
    _fillColor    = Vec3.new(0.62, 0.74, 0.92)
    _fillIntensity = 0.7
    _sunDir       = Vec3.new(-0.25, -0.82, -0.20)
    _envTop       = Vec3.new(0.66, 0.82, 0.95)
    _envHorizon   = Vec3.new(0.96, 0.88, 0.78)
    _envBottom    = Vec3.new(0.42, 0.38, 0.32)

    // Organic-blob terrain. Disc-fan mesh: 1 centre vertex +
    // 16 rings × 64 segments, each vertex at angle θ sitting at
    // radius `edgeRadius(θ) × t` and height `heightAt(x, z)`.
    // The noisy edge radius makes it read as a natural clearing
    // rather than a geometric disc; the heightmap underneath
    // gives the terrain bumps the scene's been missing.
    _ground          = buildBlobTerrainMesh_(g.device, 64, 16)
    _groundTransform = Mat4.translation(0, 0, 0)

    // Shadow infrastructure. 2048² depth target covers the
    // ~46×46 visible blob terrain around the camera target. PCF
    // radius low for crisp cel-style shadow edges. Static-scene
    // optimisation below: the shadow map is BAKED ONCE at setup
    // (after all props/foliage/stones/grass scatter), then the
    // main toon pass samples it every frame. Sun is fixed, all
    // casters are static, so there's no need to re-render the
    // shadow map per frame.
    _renderer3d.enableShadows({
      "size":      2048,
      "extent":    30,
      "near":      0.5,
      "far":       120,
      "bias":      0.003,
      "pcfRadius": 0.0004
    })
    // Sandy-cream → greener-brown spatial variation baked into
    // a procedural noise palette and bound below as albedoTexture.
    // `albedoColor` stays at (1,1,1,1) — texture is the only
    // colour source so the procedural palette doesn't get
    // double-tinted at the cel-shader's `albedo_color *
    // albedo_sample` step.
    // Hand-painted earth tile from `assets/stylized_floor.png`.
    // The texture already carries the warm-sand base, olive patch
    // variation, and painted crack linework that read as cel-
    // shaded forest floor; the material is configured to surface
    // those colours verbatim — `albedoColor = white` so the shader
    // `albedoColor * sample(albedo)` step is identity, and the toon
    // pipeline quantises lighting only (not chroma).
    // Identity multiplier — the path-center-to-edge gradient is
    // baked into the 256² texture by `buildPathTintedFloor_`.
    _groundMat = Material.new(Vec4.new(1.0, 1.0, 1.0, 1.0))
    _groundMat.shadingModel = "toon"
    // Two-band cel. ambientFloor 0.58 — high enough that the
    // shadow side stays luminous (matching the reference high-key
    // look), low enough that the cel step still registers as a
    // visible band on heightAt undulations. 0.72 collapsed the
    // lit/shadow delta so the disc read as flat-shaded.
    _groundMat.bands         = 2
    _groundMat.ambientFloor  = 0.58
    _groundMat.doubleSided   = true
    // `Material.uvScale = (4, 4)` via KHR_texture_transform tiles
    // the painted tile four times across the ~46 m blob disc
    // (~11.5 m per repeat) — dense enough that the crack pattern
    // reads at character height without obvious seams.
    var db = Assets.open("assets")
    _groundMat.albedoTexture = buildPathTintedFloor_(g, db)
    // `uvScale = (1, 1)` — the texture stretches once across the
    // disc. Previous (1.7, 1.3) and earlier (4, 4) made the painted
    // cracks in `stylized_floor.png` line up at tile boundaries
    // every ~27 m / 35 m, reading as a grid even with irrational
    // ratios. The painted cracks ARE the surface detail, so
    // tiling at all amplifies them into a checker. With (1, 1)
    // the 1k texture covers the ~46 m disc at ~22 px/m — fine
    // for the cel-shaded scale; the brush detail still reads at
    // character height without repeating.
    _groundMat.uvScale = Vec2.new(1.0, 1.0)

    // ----- Grass blade primitive + material. 0.55 m short blades
    // with width 0.12 m give a fuller-bodied tuft — the previous
    // 0.35×0.08 blades read as scattered weeds against the warm
    // soil; this height + the denser tuft scatter below produces
    // a grass-carpet that still lets soil show through the patchy
    // gaps the noise mask cuts.
    _blade    = Mesh.grassBlade(g.device, 0.55, 0.12, 6)
    // Balanced apple-green — fits with the cream ambient
    // without clashing against the warm earth. A subtle rim
    // catches the silhouette of the blade tips.
    // Three grass hue buckets — soft gradient around one base
    // green, only tiny warmth / coolness shifts between them so
    // patches read as natural variation, not a checker. Base
    // values pulled DOWN from the previous (0.50, 0.74, 0.32)
    // — the lit-band cel multiplier was pushing the green
    // channel into bloom-threshold territory (>0.78) at
    // distance, where alpha-blended grass cards picked up
    // background luma and the field washed out cream-yellow.
    // The new range keeps lit-side green under ~0.65 so the
    // far grass reads as grass, not haze.
    // Vivid grass palette — Base / Cool / Warm 3-bucket. Kept
    // saturated so the field reads alive. Cream↔green contrast
    // is managed from the path side (cream tint pulled down,
    // not by dulling the blades).
    var grassMatBase  = Material.new(Vec4.new(0.40, 0.64, 0.28, 1.0))
    var grassMatCool  = Material.new(Vec4.new(0.36, 0.62, 0.26, 1.0))
    var grassMatWarm  = Material.new(Vec4.new(0.44, 0.66, 0.28, 1.0))
    _grassMats = [grassMatBase, grassMatCool, grassMatWarm]
    var gi = 0
    while (gi < _grassMats.count) {
      var m = _grassMats[gi]
      m.shadingModel = "toon"
      m.bands         = 2
      m.ambientFloor  = 0.60
      // Wider Fresnel band (pow(fresnel, 1.8)) catches more
      // blade angles so more silhouettes register glow under
      // bloom. Face-on still contributes 0 (fresnel=0), so the
      // flat lit surface doesn't pick up extra luma — only
      // grazing-angle blades. Emissive intentionally NOT used
      // because it has no distance falloff: at distance alpha-
      // blended grass cards pick up bright sky luma and an
      // additive emissive blows them into white blooms.
      // Peak rim pulled down (0.32 → 0.24) so far grass blades —
      // whose alpha-blended edges blend with bright sky/horizon
      // pixels — don't hit white at their silhouettes and read
      // as cream haze. Mid-fresnel pixels still light up because
      // rim_width 1.8 keeps the band wide; just the peak is
      // softer.
      m.rimStrength   = 0.24
      m.rimWidth      = 1.8
      m.sway          = 1.0
      m.doubleSided   = true
      gi = gi + 1
    }

    // ----- Nature-kit archetypes. Synchronously loaded with a
    // yield between each so the setup pump pumps OS events
    // (project_setup_pump_async_load.md).
    // Two separate scene buckets — big silhouettes (trees +
    // boulders) versus ground foliage (bushes, ferns, mushrooms,
    // flowers, grass tufts). Each gets its own scatter pass so
    // ferns and flowers don't lose their slot to a tree the
    // hash happened to roll for them.
    _scenes       = []   // big props: indices 0..4
    _foliage      = []   // ground foliage: indices 0..8
    _stoneScenes  = []   // path stones
    _petals       = []   // dense flower/petal scatter
    loadProp(g, db, "nature-kit/CommonTree_2.gltf")
    loadProp(g, db, "nature-kit/CommonTree_4.gltf")
    loadProp(g, db, "nature-kit/TwistedTree_2.gltf")
    loadProp(g, db, "nature-kit/Rock_Medium_1.gltf")
    loadProp(g, db, "nature-kit/Rock_Medium_2.gltf")
    loadFoliage(g, db, "nature-kit/Bush_Common_Flowers.gltf")
    loadFoliage(g, db, "nature-kit/Fern_1.gltf")
    loadFoliage(g, db, "nature-kit/Plant_1_Big.gltf")
    loadFoliage(g, db, "nature-kit/Mushroom_Common.gltf")
    loadFoliage(g, db, "nature-kit/Mushroom_Laetiporus.gltf")
    loadFoliage(g, db, "nature-kit/Flower_3_Group.gltf")
    loadFoliage(g, db, "nature-kit/Flower_4_Group.gltf")
    loadFoliage(g, db, "nature-kit/Grass_Common_Tall.gltf")
    loadFoliage(g, db, "nature-kit/Grass_Wispy_Tall.gltf")
    loadStone(g, db, "nature-kit/RockPath_Round_Small_1.gltf")
    loadStone(g, db, "nature-kit/RockPath_Round_Wide.gltf")
    loadStone(g, db, "nature-kit/Pebble_Round_3.gltf")
    loadStone(g, db, "nature-kit/Pebble_Square_2.gltf")

    // Petal / small flower scatter — much higher density than
    // the regular foliage so the grass field reads as dotted
    // with colour the way anime backgrounds frame their
    // clearings.
    loadPetal(g, db, "nature-kit/Petal_1.gltf")
    loadPetal(g, db, "nature-kit/Petal_2.gltf")
    loadPetal(g, db, "nature-kit/Petal_3.gltf")
    loadPetal(g, db, "nature-kit/Flower_3_Single.gltf")
    loadPetal(g, db, "nature-kit/Flower_4_Single.gltf")
    loadPetal(g, db, "nature-kit/Clover_1.gltf")
    loadPetal(g, db, "nature-kit/Clover_2.gltf")

    scatterProps_()
    scatterFoliage_()
    // Tiny pebbles back on the path — scatterStones_ restricted
    // to the two pebble variants at scale 0.20..0.32 so they
    // read as ground grit rather than stepping stones.
    scatterStones_()
    scatterPetals_()
    scatterGrass_(g.device)

    // ----- Fireflies: HDR-emissive GPU billboards that the
    // existing Bloom pass (threshold 0.78, intensity 0.65) picks
    // up automatically. The disc spans ~21 m radius; spawns are
    // jittered across the full area at hover height 1.0..3.0 m.
    // Curl-noise wind drives the slow lazy drift that reads as
    // firefly wandering rather than embers falling.
    _fireflyTex = makeDiscTexture_(g.device, 64)
    // Four perimeter emitters at compass points around the disc.
    // pathX(z) = 4 sin(0.18 z) serpentines x in [-4, 4] within
    // pathHalfWidth=1.6; off-path starts at |x - pathX(z)| > 3.1.
    // Emitters parked at |coord|=12 (radius 12 from origin), well
    // outside the bright-lime sun-lit centre and inside the
    // deeper-toned outlined grass band the cel-shading + outline
    // ink paints around the scene perimeter. Low y (0.9..2.3 m)
    // mixes them into the grass-blade canopy so each amber spark
    // reads against an INKED green backdrop instead of bloom-
    // bleached lime.
    _fireflies  = makeFireflyEmitter_(g.device, _fireflyTex,  12.0,   0.0)
    _fireflies2 = makeFireflyEmitter_(g.device, _fireflyTex, -12.0,   0.0)
    _fireflies3 = makeFireflyEmitter_(g.device, _fireflyTex,   0.0,  12.0)
    _fireflies4 = makeFireflyEmitter_(g.device, _fireflyTex,   0.0, -12.0)
    Particles.register(_fireflies)
    Particles.register(_fireflies2)
    Particles.register(_fireflies3)
    Particles.register(_fireflies4)

    // Painted sky backdrop. Three-band gradient — pale cyan at
    // zenith, warm cream at the horizon. `falloff = 1.4` gives
    // the cyan a long top-of-frame run and the cream a tight
    // band, which mirrors the way anime backgrounds frame their
    // skies. Depth-aware: only paints over the far-plane
    // fragments so the scene geometry is untouched.
    g.postFX = PostFX.new(g, { "normalFormat": "rgba8unorm" })

    // Toon outline ink. Runs FIRST so Bloom can halo the inked
    // silhouettes. Sobel-style edge detect over depth + normal
    // G-buffers. Tuned for SUBTLE-BUT-ALWAYS-PRESENT — softening
    // ink alpha alone isn't enough because at low orbit pitch the
    // typical silhouette (tree against grass at similar depth)
    // doesn't clear an aggressive depth threshold, so the lines
    // disappear from first/third-person framings while staying
    // visible top-down. The gates here are loose enough to fire
    // from any pitch; the warm-sepia ink at ~55% alpha keeps the
    // line painted-soft rather than pen-hard.
    //
    //   - `thickness 1.0` (FOV-scaled to ~1.1 at 55°): 1-pixel line.
    //   - `depthThreshold 0.0035`: catches tree-vs-grass jumps
    //     down to ~0.7m depth difference at typical view distance.
    //   - `normalThreshold 0.28`: ~43° normal break — picks up
    //     branch creases and rock facets from horizontal angles.
    //   - `color rgba(0.18, 0.12, 0.08, 0.55)`: warm-sepia ink,
    //     blends into the painted backdrop without stamping black.
    //   - `fovDeg 55.0`: matches the camera below; OutlinePass
    //     scales the sample step so the line keeps consistent
    //     weight if FOV changes.
    g.postFX.add(OutlinePass.new(g.device, {
      // Thresholds lowered so grass blade silhouettes actually
      // catch at distance — blade-vs-blade and blade-vs-field
      // depth gradients are 0.001-0.003 NDC, normal gradients
      // ~30-50° (path stones are gone now, so this can be tight
      // without dragging them back in). Thickness 1.2 widens the
      // Sobel kernel to register 1-2 pixel blade widths.
      "thickness":       1.2,
      "depthThreshold":  0.0025,
      "normalThreshold": 0.35,
      "color":           [0.18, 0.12, 0.08, 0.55],
      "fovDeg":          55.0,
      // Fade pulled in (0.990 → 0.988, 0.997 → 0.993) so distant
      // trees (now denser at propCap=72) lose their outlines and
      // recede into the painted backdrop — close grass + mid
      // foliage still inks, only the far tree-line goes ink-free.
      "fadeNear":        0.988,
      "fadeFar":         0.993
    }))

    // Bloom — soft anime halo on bright leaf-tips. Runs BEFORE
    // SkyPass so the additive composite (`s + b * intensity`
    // in bloom.wren:484) only touches scene geometry. With
    // SkyPass first the horizon RGB (0.96, 0.86, 0.74, luma
    // ≈ 0.876) passed the 0.78 threshold and the additive
    // composite saturated sky pixels to white. LDR threshold
    // because our toon pipeline writes display-range colour;
    // intensity stays moderate so the halo reads as "painted
    // soft light" rather than as a glow filter. Mip pyramid 4
    // levels = 80×45 smallest at 1280×720, plenty wide for the
    // gentle halos anime backgrounds use.
    g.postFX.add(Bloom.new({
      // Threshold stays at 0.78 — terrain horizon luma sits at
      // mask ~0.72 either way, so lowering would bloom the
      // horizon. The grass-glow expansion comes from the grass
      // material (wider rim + small emissive lift the per-pixel
      // luma into the existing mask).
      "threshold": 0.78,
      "knee":      0.30,
      // Intensity 0.55 → 0.65. Mid-fresnel rim pixels now register
      // a ~0.10 mask where they were ~0.03 — 0.65 turns those into
      // visible-but-soft painted glow. Hard-grazing silhouettes
      // (rim mask ~0.32) gain ~18% so the halo widens without
      // blowing out.
      "intensity": 0.65,
      "levels":    4
    }))

    // Painted sky backdrop runs LAST. The depth guard
    // (`depth >= 0.999` in painted_sky.wren) writes only
    // far-plane fragments, so the gradient lands verbatim over
    // Bloom's bright-pass output without affecting bloomed
    // geometry. Three-band gradient — pale cyan at zenith,
    // warm cream at the horizon. `falloff = 1.4` gives the cyan
    // a long top-of-frame run and the cream a tight band, which
    // mirrors the way anime backgrounds frame their skies.
    g.postFX.add(SkyPass.new({
      "zenith":  [0.55, 0.78, 0.95, 1.0],
      // Slightly warmer (more pink-red) horizon — reads as a
      // softer painted-light sunset tint when it's visible.
      "horizon": [0.98, 0.80, 0.70, 1.0],
      // `falloff = 2.4` (was 1.4) pushes the warm horizon hue
      // up the framebuffer so it's still visible when the
      // camera pitches down at the scene and the sky only fills
      // the top 20–30% of the frame. With falloff=1.4 the
      // horizon was confined to uv.y > 0.5 — you had to zoom
      // OUT (sky filling more of the frame) to see it.
      "falloff": 2.4
    }))

    // Pre-warm every material's UBO + BindGroup so the first
    // frame's draw loop is pure dispatch. Without this, the
    // renderer's `createBuffer + createBindGroup` calls land
    // inside the encoder pass and a GC cycle mid-draw corrupts
    // the shared per-draw UBO list.
    _renderer3d.prewarmMaterial(_groundMat)
    var pwgi = 0
    while (pwgi < _grassMats.count) {
      _renderer3d.prewarmMaterial(_grassMats[pwgi])
      pwgi = pwgi + 1
    }
    _renderer3d.prewarmGltfScenes(_scenes)
    _renderer3d.prewarmGltfScenes(_foliage)
    _renderer3d.prewarmGltfScenes(_petals)
    _renderer3d.prewarmGltfScenes(_stoneScenes)

    // ----- Bake the shadow map ONCE. The scene is static: sun
    // direction is fixed, every caster transform is built at
    // setup time, no animation. Setup runs before the framework's
    // per-frame encoder lifecycle so we own this encoder fully:
    // create → record shadow pass → submit → destroy. The main
    // toon pass samples the resulting depth map every frame
    // without re-recording the shadow pass.
    var bakeEnc = g.device.createCommandEncoder()
    _renderer3d.beginShadowPass(bakeEnc, _sunDir, Vec3.new(0, 0, 0))
    _renderer3d.drawShadow(_ground, _groundTransform)
    var si = 0
    while (si < _propCount) {
      drawShadowScene(_scenes[_propSceneIdx[si]], _propTransforms[si])
      si = si + 1
    }
    var sf = 0
    while (sf < _foliageCount) {
      drawShadowScene(_foliage[_foliageSceneIdx[sf]], _foliageTransforms[sf])
      sf = sf + 1
    }
    var sp = 0
    while (sp < _petalCount) {
      drawShadowScene(_petals[_petalSceneIdx[sp]], _petalTransforms[sp])
      sp = sp + 1
    }
    var sk = 0
    while (sk < _stoneCount) {
      drawShadowScene(_stoneScenes[_stoneSceneIdx[sk]], _stoneTransforms[sk])
      sk = sk + 1
    }
    _renderer3d.endShadowPass
    g.device.submit([bakeEnc.finish])
    bakeEnc.destroy
  }

  loadProp(g, db, path) {
    var scene = Gltf.fromAssetsDir(g.device, db, path)
    toonify(scene)
    _scenes.add(scene)
    Fiber.yield()
  }

  loadFoliage(g, db, path) {
    var scene = Gltf.fromAssetsDir(g.device, db, path)
    toonify(scene)
    _foliage.add(scene)
    Fiber.yield()
  }

  loadStone(g, db, path) {
    var scene = Gltf.fromAssetsDir(g.device, db, path)
    toonify(scene)
    _stoneScenes.add(scene)
    Fiber.yield()
  }

  loadPetal(g, db, path) {
    var scene = Gltf.fromAssetsDir(g.device, db, path)
    toonify(scene)
    _petals.add(scene)
    Fiber.yield()
  }

  // Procedural soft-disc texture for the firefly billboards.
  // Hard 1×1 pixels render every particle as a tiny square; a
  // 64×64 gaussian falloff in the alpha channel makes each spark
  // a soft glow that the Bloom postFX smears into a painted halo.
  // RGB is held at 255 so the multiplied output colour is the
  // HDR amber from the particle system; the FS in @hatch:gpu's
  // renderer3d treats tex.a as the source coverage under
  // premultiplied blend, so a small alpha at the edge produces
  // a soft circular halo without erasing dst.
  makeDiscTexture_(device, size) {
    var bytes = []
    var half = size / 2.0
    var y = 0
    while (y < size) {
      var x = 0
      while (x < size) {
        var dx = (x + 0.5) - half
        var dy = (y + 0.5) - half
        var d  = (dx * dx + dy * dy).sqrt / half
        if (d > 1) d = 1
        var fall = 1 - d
        var a    = (fall * fall * 255).floor
        bytes.add(255)
        bytes.add(255)
        bytes.add(255)
        bytes.add(a)
        x = x + 1
      }
      y = y + 1
    }
    var tex = device.createTexture({
      "width": size, "height": size, "format": "rgba8unorm",
      "usage": ["texture-binding", "copy-dst"]
    })
    device.writeTexture(tex, ByteArray.fromList(bytes),
                        {"width": size, "height": size, "bytesPerRow": size * 4})
    return tex
  }

  // Build one firefly emitter at `(cx, _, cz)`. Tuned for REAL
  // emissive glow: HDR colour pushed FAR past the bloom 0.78
  // threshold so the bright-pass extraction registers each spark
  // as a saturated source, the 4-level mip pyramid spreads it
  // into a wide halo, and the additive composite paints
  // visible amber light onto the surrounding grass — the spark
  // pixel itself is small but the halo it CASTS makes the spark
  // glow like a real luminous body.
  makeFireflyEmitter_(device, tex, cx, cz) {
    var sys = GpuParticleSystem3D.new(device, {
      "texture":      tex,
      "capacity":     90,
      "emissionRate": 22,
      "lifetime":     [3.5, 5.5],
      "position":     [cx, 1.6, cz],
      "spread":       [4.0, 0.7, 4.0],
      "velocity":     [[-0.12, -0.04, -0.12], [0.12, 0.04, 0.12]],
      "gravity":      [0.0, 0.0, 0.0],
      "drag":         0.85,
      // Slightly larger so bloom kernel has more bright area
      // to sample — the halo widens cubically with source
      // brightness × source area.
      "size":         [0.06, 0.06],
      // HDR amber pushed to ~5.9 luma start (well past the 0.78
      // bloom threshold) → strong bright-pass extraction, real
      // glow. Fade to a dimmer amber at lifetime end (~1.55
      // luma) before alpha hits 0 so the spark stays emissive
      // throughout its life rather than dimming into invisibility.
      "color":        [[4.50, 2.90, 0.90, 1.0], [1.40, 0.80, 0.25, 0.0]]
    })
    sys.setWindNoise(0.18, 0.35, 1.0, 0.4)
    sys.setWind(0.2, 0.0, 0.15, 0.6)
    return sys
  }

  // Fisher-Yates in-place shuffle over a paired (xs, zs) scatter
  // result. `count` is the number of populated entries (which can
  // be less than `xs.count` since `Foliage.scatter` over-allocates
  // for the worst-case bound). The LCG is the Numerical Recipes
  // constant set — deterministic, well-distributed for our scale.
  shuffleSites_(xs, zs, count, seed) {
    var s = seed
    if (s < 0) s = -s
    if (s == 0) s = 1
    var k = count - 1
    while (k > 0) {
      s = (s * 1103515245 + 12345) % 2147483648
      var idx = (s % (k + 1))
      var tx = xs[idx]
      var tz = zs[idx]
      xs[idx] = xs[k]
      zs[idx] = zs[k]
      xs[k] = tx
      zs[k] = tz
      k = k - 1
    }
  }

  // Build the organic-blob terrain mesh. 1 centre vertex + `rings`
  // concentric rings of `segments` vertices each. The fan from
  // centre to ring 1 and the quad strips between adjacent rings
  // are wound CCW-from-above so `cullMode: back` shows them to a
  // Tint the painted earth texture per-pixel so the on-path band
  // reads as lit sand-brown and the off-path field reads as
  // mossy-green earth that blends with the grass carpet above it.
  // Mesh UV layout: u = 0.5 + cos(theta) * t * 0.5, v same with
  // sin, centered on the disc — so texel (u, v) maps to world
  // `((u - 0.5) * 2 * R, (v - 0.5) * 2 * R)` with R = 21. The
  // same `pathX(z)` that the scatter passes use to AVOID drawing
  // grass / props on the path here decides the tint mix: distance
  // from the path centerline drives a smoothstep between the two
  // chroma stops. Soft transition over ~2 m so the band doesn't
  // read as a hard painted edge.
  // Bake the path-vs-grass tint into a 256² texture by
  // downsampling the source painted PNG and applying per-pixel
  // multipliers based on distance from `pathX(z)`. Lower res
  // than the source (1024²) is fine — the path/grass mask is
  // low-frequency (smoothstep over ~2 m) and the sampler
  // bilinear-filters the upload, so the boundary stays soft.
  // Working at 256² keeps the destination ByteArray at 256 KB,
  // safely inside the libc small-allocation path (the 4 MB
  // version triggered a malloc double-free on macOS — likely the
  // mmap-vs-sbrk crossover).
  buildPathTintedFloor_(g, db) {
    // Paint the walkway DIRECTLY onto the texture as solid colors
    // — creamy brown on the path band, olive-cream off-path,
    // soft noise-wobbled edge between them. No PNG sampling, no
    // multiplier wrestling — just paint two colors with a
    // smoothstep boundary.
    var w = 384
    var h = 384
    var dst = ByteArray.new(w * h * 4)

    var R = 21.0
    var pathBand  = pathHalfWidth + 0.1
    // Widened 1.4 → 2.6 m so the path→moss transition reads as a
    // proper graduated band — the previous 1.4 m squeezed the
    // gradient into too few pixels and the eye saw a hard jump
    // between tan and moss. Now the smoothstep runs through a
    // warm intermediate stop (see midR/midG/midB below) so the
    // gradient has THREE colour stops carrying the eye across.
    var edgeWidth = 2.6

    // Warm peach-cream path — tuned to the scene's high-key
    // pastel palette: pink-peach sky horizon, vivid green grass,
    // pink and red trees. The path bridges sky horizon to grass
    // by echoing the sky's warm cream tone. R lifted, G held,
    // B significantly lifted (0.28 → 0.45) so it reads as cream
    // not yellow — yellow saturated against vivid green and
    // pink horizons was breaking the painterly read.
    //   target lit-band sRGB ≈ (220, 206, 173) — warm linen cream
    //   target post-cel linear ≈ (0.72, 0.621, 0.396)
    //   base = post ÷ key (1.0, 0.97, 0.88) = (0.72, 0.64, 0.45)
    var brR = 0.72
    var brG = 0.64
    var brB = 0.45
    // Off-path: creamy-green-brown moss — lifted ~12% from
    // (0.41, 0.46, 0.28) so the ring reads brighter while
    // keeping the earthy bridge tone between cream and green.
    //   target lit-band sRGB ≈ (177, 190, 152) — brighter moss
    //   target post-cel linear ≈ (0.46, 0.50, 0.30)
    //   base = post ÷ key (1.0, 0.97, 0.88) = (0.46, 0.52, 0.34)
    var grR = 0.46
    var grG = 0.52
    var grB = 0.34
    // Intermediate stop for the path→moss gradient: a warm
    // dried-grass yellow that the eye reads as a transition
    // colour between tan and moss. R high (carries the warmth
    // through), G lifted (starts pushing toward green), B low
    // (still earthy, not yet damp).
    //   target lit-band sRGB ≈ (193, 188, 130) — warm hay
    var midR = 0.62
    var midG = 0.58
    var midB = 0.36

    var jj = 0
    while (jj < h) {
      var v = jj / (h - 1)
      var wz = (v - 0.5) * 2 * R
      var pathCx = pathX(wz)
      var ii = 0
      while (ii < w) {
        var u = ii / (w - 1)
        var wx = (u - 0.5) * 2 * R
        var dx = (wx - pathCx).abs

        // Two-octave noise wobbles the path boundary so the edge
        // reads as a worn footpath instead of a clean curve.
        var nLow  = Noise.simplex2(wx * 0.25, wz * 0.25, 1234)
        var nHigh = Noise.simplex2(wx * 1.6,  wz * 1.6,  5678)
        var dxAdj = dx + nLow * 0.35 + nHigh * 0.18

        // pathness: 1 inside path band, 0 off-path. Smoothstep
        // across edgeWidth metres for an organic boundary.
        var t = (dxAdj - pathBand) / edgeWidth
        if (t < 0) t = 0
        if (t > 1) t = 1
        var s = t * t * (3 - 2 * t)
        var pathness = 1 - s

        // Three-stop gradient: tan → hay → moss. s=0 is full
        // path tan, s=0.5 is full hay mid, s=1 is full moss.
        // Linear ramps between each pair so the eye sees the
        // gradient passing through a warm intermediate hue.
        var outR
        var outG
        var outB
        if (s < 0.5) {
          var u = s * 2
          outR = brR * (1 - u) + midR * u
          outG = brG * (1 - u) + midG * u
          outB = brB * (1 - u) + midB * u
        } else {
          var u = (s - 0.5) * 2
          outR = midR * (1 - u) + grR * u
          outG = midG * (1 - u) + grG * u
          outB = midB * (1 - u) + grB * u
        }

        // Light noise dither across the whole surface so the
        // painted bands have a whisper of detail instead of
        // reading as flat poster.
        var d = Noise.simplex2(wx * 2.2, wz * 2.2, 99) * 0.05
        outR = outR + d
        outG = outG + d
        outB = outB + d

        // Subtle stone-grain overlay on the path band — much
        // softer than a hard crack pattern, just enough surface
        // detail that the path doesn't read as flat poster. Two
        // octaves of simplex sum, darken by ~5% along ridges.
        // Previous 14% darken read as muddy dirt cracks; this is
        // a whisper of texture, like aged paper or worn stone.
        if (pathness > 0.5) {
          var c1 = Noise.simplex2(wx * 0.85, wz * 0.85, 4321)
          var c2 = Noise.simplex2(wx * 1.7,  wz * 1.7,  8765)
          var cell = (c1.abs + c2.abs * 0.5)
          if (cell < 0.14) {
            var crackStrength = (0.14 - cell) / 0.14
            var darken = 0.05 * crackStrength * pathness
            outR = outR - darken
            outG = outG - darken
            outB = outB - darken * 0.8
          }
        }
        if (outR > 1) outR = 1
        if (outR < 0) outR = 0
        if (outG > 1) outG = 1
        if (outG < 0) outG = 0
        if (outB > 1) outB = 1
        if (outB < 0) outB = 0

        var idx = (jj * w + ii) * 4
        dst[idx]     = (outR * 255).floor
        dst[idx + 1] = (outG * 255).floor
        dst[idx + 2] = (outB * 255).floor
        dst[idx + 3] = 255
        ii = ii + 1
      }
      jj = jj + 1
    }

    var painted = Image.new(w, h, dst)
    return g.device.uploadImage(painted, {
      "format": "rgba8unorm",
      "label":  "ground-painted-walkway"
    })
  }

  // camera above the soil. Edge radius at each angle comes from
  // `edgeRadius(theta)`; vertex height from `heightAt(x, z)`.
  // Vertex layout matches `Mesh.fromArrays`: position(3) + normal(3)
  // + uv(2) + tangent(4) = 12 floats per vertex.
  buildBlobTerrainMesh_(device, segments, rings) {
    var twoPi = 6.283185307
    var vertCount = 1 + segments * rings
    var verts = List.filled(vertCount * 12, 0)
    var centerY = heightAt(0, 0)
    writeBlobVertex_(verts, 0, 0, centerY, 0, 0, 1, 0, 0.5, 0.5)
    var ri = 1
    while (ri <= rings) {
      var t = ri / rings
      var s = 0
      while (s < segments) {
        var theta = twoPi * s / segments
        var ca = theta.cos
        var sa = theta.sin
        var r = edgeRadius(theta) * t
        var x = ca * r
        var z = sa * r
        var y = heightAt(x, z)
        // Finite-difference normal across the heightmap surface.
        var step = 0.4
        var yPx = heightAt(x + step, z)
        var yPz = heightAt(x, z + step)
        var dx = yPx - y
        var dz = yPz - y
        var nx = -dx
        var ny = step
        var nz = -dz
        var nl = (nx * nx + ny * ny + nz * nz).sqrt
        if (nl < 0.0001) nl = 1
        var u = 0.5 + ca * t * 0.5
        var v = 0.5 + sa * t * 0.5
        writeBlobVertex_(verts, 1 + (ri - 1) * segments + s,
          x, y, z, nx / nl, ny / nl, nz / nl, u, v)
        s = s + 1
      }
      ri = ri + 1
    }
    // Indices. CCW from above winding worked out to:
    //   fan: centre → s+1 → s (around the inner ring)
    //   quad strip: ia → ib → ic, ib → id → ic
    //     where ia = (r, s), ib = (r, s+1), ic = (r+1, s), id = (r+1, s+1)
    var triCount = segments + (rings - 1) * segments * 2
    var indices = List.filled(triCount * 3, 0)
    var tri = 0
    // Inner fan
    var fs = 0
    while (fs < segments) {
      var fsNext = (fs + 1) % segments
      indices[tri + 0] = 0
      indices[tri + 1] = 1 + fsNext
      indices[tri + 2] = 1 + fs
      tri = tri + 3
      fs = fs + 1
    }
    // Quad strips
    var qr = 1
    while (qr < rings) {
      var qs = 0
      while (qs < segments) {
        var qsNext = (qs + 1) % segments
        var ia = 1 + (qr - 1) * segments + qs
        var ib = 1 + (qr - 1) * segments + qsNext
        var ic = 1 + qr * segments + qs
        var id = 1 + qr * segments + qsNext
        indices[tri + 0] = ia
        indices[tri + 1] = ib
        indices[tri + 2] = ic
        indices[tri + 3] = ib
        indices[tri + 4] = id
        indices[tri + 5] = ic
        tri = tri + 6
        qs = qs + 1
      }
      qr = qr + 1
    }
    return Mesh.fromArrays(device, verts, indices)
  }

  writeBlobVertex_(verts, idx, x, y, z, nx, ny, nz, u, v) {
    var base = idx * 12
    verts[base + 0]  = x
    verts[base + 1]  = y
    verts[base + 2]  = z
    verts[base + 3]  = nx
    verts[base + 4]  = ny
    verts[base + 5]  = nz
    verts[base + 6]  = u
    verts[base + 7]  = v
    verts[base + 8]  = 1
    verts[base + 9]  = 0
    verts[base + 10] = 0
    verts[base + 11] = 1
  }

  // Distance + edge-radius gate used by every scatter pass so
  // props only land inside the blob shape.
  insideBlob_(x, z) {
    var d = (x * x + z * z).sqrt
    if (d < 0.01) return true
    var theta = z.atan(x)
    return d < edgeRadius(theta) - 0.6
  }

  // Sandy-cream → greener-brown soil palette. 128×128 RGBA8
  // baked once at setup. World-space FBM drives a 3-stop mix:
  //   t=0.0  → dry sandy cream  (0.86, 0.78, 0.58)
  //   t=0.55 → warm earth        (0.70, 0.60, 0.42)
  //   t=1.0  → mossy green-brown (0.52, 0.58, 0.34)
  // Heightmap valleys get pushed toward the green end (damp
  // soil hosts moss); path-proximity damps toward warm earth so
  // the soil colour story tracks the visible dirt track. Texture
  // is sampled by the blob mesh through the centred UV the
  // mesh writes (`0.5 + ca*t*0.5`, `0.5 + sa*t*0.5`), so
  // texel (u, v) maps to world (x, z) = ((u-0.5)*2*R, (v-0.5)*2*R)
  // with R = 21 (≈ mean edgeRadius).

  // Build a (tileCount × tileCount) grid mesh covering
  // `extent × extent` world units, with per-vertex Y sampled from
  // `heightAt(x, z)` and per-vertex normals approximated from
  // finite differences on the same field. Vertex layout matches
  // `Mesh.fromArrays` (pos.xyz + normal.xyz + uv.xy + tangent.xyzw
  // = 12 floats per vertex). Greener tint near grass-ier valleys
  // would need per-vertex colour the engine doesn't currently
  // surface; for now the global olive-earth base reads as
  // forest-floor across the slope.
  buildHeightmapMesh_(device, tileCount, extent) {
    var half = extent / 2
    var step = extent / tileCount
    var vertCount = (tileCount + 1) * (tileCount + 1)
    var verts = List.filled(vertCount * 12, 0)
    var iz = 0
    while (iz <= tileCount) {
      var ix = 0
      while (ix <= tileCount) {
        var x = -half + ix * step
        var z = -half + iz * step
        var y = heightAt(x, z)
        // Finite-difference normal: cross of tangent vectors
        // (ddx along +X, ddz along +Z) gives the surface normal.
        // Small epsilon (= step) is fine for the smooth heightmap.
        var yPx = heightAt(x + step, z)
        var yPz = heightAt(x, z + step)
        var dx = yPx - y
        var dz = yPz - y
        // n = (-dx, step, -dz) normalized — derivative of standard
        // smooth-surface normal.
        var nx = -dx
        var ny = step
        var nz = -dz
        var nl = (nx * nx + ny * ny + nz * nz).sqrt
        if (nl < 0.0001) nl = 1
        nx = nx / nl
        ny = ny / nl
        nz = nz / nl
        var u = ix / tileCount
        var v = iz / tileCount
        var base = ((iz * (tileCount + 1)) + ix) * 12
        verts[base + 0]  = x
        verts[base + 1]  = y
        verts[base + 2]  = z
        verts[base + 3]  = nx
        verts[base + 4]  = ny
        verts[base + 5]  = nz
        verts[base + 6]  = u
        verts[base + 7]  = v
        verts[base + 8]  = 1
        verts[base + 9]  = 0
        verts[base + 10] = 0
        verts[base + 11] = 1
        ix = ix + 1
      }
      iz = iz + 1
    }
    var triCount = tileCount * tileCount * 2
    var indices = List.filled(triCount * 3, 0)
    var tri = 0
    var qz = 0
    while (qz < tileCount) {
      var qx = 0
      while (qx < tileCount) {
        var i0 = qz * (tileCount + 1) + qx
        var i1 = i0 + 1
        var i2 = i0 + (tileCount + 1)
        var i3 = i2 + 1
        // CCW from above so the default `cullMode: back` keeps
        // the terrain visible to a camera above. Matches the
        // Mesh.plane winding fix.
        indices[tri + 0] = i0
        indices[tri + 1] = i2
        indices[tri + 2] = i1
        indices[tri + 3] = i1
        indices[tri + 4] = i2
        indices[tri + 5] = i3
        tri = tri + 6
        qx = qx + 1
      }
      qz = qz + 1
    }
    return Mesh.fromArrays(device, verts, indices)
  }

  // Keep every GLTF material's diffuse / normal / occlusion /
  // emissive textures intact. The toon shader handles textures
  // fine — `toon_compute` does
  //   `base_color = mat.albedo_color * albedo_sample`
  // and quantises lighting on top, so a textured material reads
  // as "painted hue + cel-banded lighting". Stripping the texture
  // was solving a non-problem and breaking two real ones:
  //   - Quaternius materials have `baseColorFactor = (1,1,1,1)`
  //     because their colour lives in the texture, so the strip
  //     left props rendering pure white.
  //   - Leaf cards use the texture's ALPHA channel to cut out the
  //     leaf silhouette; stripping turned every leaf-quad into a
  //     fully opaque polygon (the "jagged trees" symptom).
  // Doublesided gets flipped on alpha-masked materials so the back
  // face of each leaf card still draws at grazing camera angles.
  toonify(scene) {
    var meshes = scene.meshes
    var mi = 0
    while (mi < meshes.count) {
      var prims = meshes[mi].primitives
      var pj = 0
      while (pj < prims.count) {
        var prim = prims[pj]
        if (prim.material != null) {
          // Three-band cel: shadow / mid / lit reads as distinct
          // painted zones on rocks and tree trunks rather than the
          // smooth-Lambert two-tone the previous bands=2 produced
          // (the `floor(n_dot_l * 2 + 0.5) / 2` quantiser collapses
          // anywhere `ambient_floor` is high). Dropping the floor
          // to 0.28 puts a clear gap between the bottom band and
          // the mid band so the shading "lines" actually read.
          prim.material.shadingModel  = "toon"
          prim.material.bands         = 3
          prim.material.ambientFloor  = 0.28
          prim.material.rimStrength   = 0.55
          prim.material.rimWidth      = 2.2
          var mode = prim.material.alphaMode
          if (mode == "mask" || mode == "blend") {
            // Leaves: texture already reads bright after the cel
            // step, so the multiplier stays neutral.
            prim.material.albedoColor = Vec4.new(1.10, 1.10, 1.10, 1.0)
            prim.material.doubleSided = true
          } else {
            // Opaque rocks, bark, mushroom caps. Quaternius
            // ships these PNGs in the dark half of the value
            // range (intended for an HDR pipeline that
            // re-brightens during tonemap). With our LDR cel
            // pipeline the result reads almost black, so
            // `albedoColor` becomes a 1.6× brightener on the
            // sampled texture — fragment math is
            // `mat.albedo_color * albedo_sample`, so any
            // multiplier above 1.0 lifts the painted hue
            // without re-saturating.
            // Quaternius bark + rock PNGs are authored for an HDR
            // pipeline that re-brightens during tonemap; in our
            // LDR cel pipeline they sample dim. 2.4× brightener
            // lifts the textures into the mid-luminance range
            // where cel banding actually reads as wood-grain or
            // granite. R-channel will clip on the lit-side band
            // for the brightest pixels, which is fine — bark
            // doesn't need detail above white.
            prim.material.albedoColor = Vec4.new(2.40, 2.30, 2.15, 1.0)
          }
        }
        pj = pj + 1
      }
      mi = mi + 1
    }
  }

  // Scatter a capped number of large props across the clearing,
  // suppressing any sites that fall onto the walk path. Bounds
  // match the 50×50 terrain mesh so trees and rocks fill the
  // visible field instead of bunching in the centre.
  scatterProps_() {
    var rawProps = Foliage.scatter({
      "bounds":  [-23, -23, 23, 23],
      // Spacing tightened 3.2 → 2.4 so the ~46×46 disc yields
      // enough candidate sites to actually fill propCap=72.
      "spacing": 2.4,
      "jitter":  0.85,
      "seed":    9001
    })
    var pxRaw    = rawProps["xs"]
    var pzRaw    = rawProps["zs"]
    var rawCount = rawProps["count"]
    // `Foliage.scatter` packs sites in Z-major raster order (see
    // hatch-game/foliage.wren). With propCap=32 the unshuffled
    // iteration ate the first 2-3 rows at min-Z and the rest of
    // the field stayed empty — that's the "trees all at the
    // back" symptom. Fisher-Yates over (xs, zs) breaks that
    // ordering deterministically; the seed is derived from the
    // scatter seed so the same Foliage.scatter inputs still
    // produce a stable layout.
    shuffleSites_(pxRaw, pzRaw, rawCount, 9001 + 7)

    _propCount      = 0
    _propSceneIdx   = List.filled(propCap, 0)
    // Cache each prop's TRS matrix at scatter time. Building a
    // fresh Mat4 in `draw()` allocates 16 floats per prop per
    // frame, and a few seconds of orbiting fills the minor heap
    // enough to trip a GC walk on stale state. Cached matrices
    // are constant, so the per-frame loop is pure dispatch.
    _propTransforms = List.filled(propCap, null)

    // Per-archetype scale ranges. Quaternius nature-kit assets are
    // authored at wildly different native sizes — CommonTree natively
    // reads ~3 m, TwistedTree ~6-8 m, mushrooms ~0.3 m. A single
    // uniform range either made the red TwistedTrees fill the
    // screen or shrunk the CommonTrees into dwarves; the per-bucket
    // approach is what procedural-world does too. Indices line up
    // with the `loadProp` order above.
    //                                 [minScale, maxScale]
    var archetypeScales = [
      [0.75, 1.05], // 0 CommonTree_2 — lifted from 0.55-0.80 for
      [0.75, 1.05], // 1 CommonTree_4  more vertical presence
      [0.28, 0.42], // 2 TwistedTree_2 — modest lift; the red
                    //   canopies still kept tight because they
                    //   visually dominate at any scale
      [0.6, 1.0],   // 3 Rock_Medium_1
      [0.6, 1.0]    // 4 Rock_Medium_2
    ]

    // Weighted archetype pattern — 10-slot ring.
    //   indices 0,1,2   = CommonTree_2 (30%)
    //   indices 3,4,5   = CommonTree_4 (30%)
    //   indices 6,7     = TwistedTree_2 (20%, dropped from 40%
    //                     because the red canopies dominate
    //                     visually even at small scale)
    //   index   8       = Rock_Medium_1 (10%)
    //   index   9       = Rock_Medium_2 (10%)
    var propPattern = [0, 0, 0, 1, 1, 1, 2, 2, 3, 4]
    var sceneCount = _scenes.count
    var j = 0
    while (j < rawCount && _propCount < propCap) {
      var x = pxRaw[j]
      var z = pzRaw[j]
      var dx = (x - pathX(z)).abs
      // Trees + rocks pushed further out (+3.5 m) than the
      // smaller foliage (+1.5 m). Trunks are tall and read as
      // boundary structure; at +1.5 m their canopies crowded
      // the walk surface. Bushes, ferns and grass blades still
      // grow right at the green band's edge so the path feels
      // lush, but no trunk-overhang.
      if (dx > pathHalfWidth + 3.5 && insideBlob_(x, z)) {
        // Pattern lookup instead of round-robin — heavily weights
        // trees over rocks so bumping propCap actually means more
        // trees, not more boulders.
        var idx = propPattern[_propCount % propPattern.count]
        // Uniform yaw on [0, 2π). The previous `.sin * π` hash
        // pushed values to the arcsine extremes, so every prop
        // ended up facing roughly the same direction. The
        // standard fract-hash gives flat distribution.
        var h    = (x * 12.9898 + z * 78.233 + idx * 3.1415).sin * 43758.5453
        var yaw  = (h - h.floor) * 6.28318
        var range = archetypeScales[idx]
        var t     = (x * 2.71 + z * 1.83).sin * 0.5 + 0.5
        var scale = range[0] + t * (range[1] - range[0])
        _propSceneIdx[_propCount]   = idx
        _propTransforms[_propCount] = trsY(x, heightAt(x, z), z, scale, yaw)
        _propCount = _propCount + 1
      }
      j = j + 1
    }
  }

  // Dense ground-foliage scatter: bushes, ferns, mushrooms,
  // flowers, ground-grass tufts. Independent of the big-prop
  // scatter so the small foliage isn't starved by the tree
  // hash. Suppressed within the walk path's half-width so the
  // track stays clear.
  scatterFoliage_() {
    var raw = Foliage.scatter({
      "bounds":  [-22, -22, 22, 22],
      "spacing": 1.05,
      "jitter":  0.85,
      "seed":    20251
    })
    var fxRaw    = raw["xs"]
    var fzRaw    = raw["zs"]
    var rawCount = raw["count"]
    // Same deterministic shuffle as `scatterProps_` — without it
    // the foliage cap (90) starves the far half of the field.
    shuffleSites_(fxRaw, fzRaw, rawCount, 20251 + 7)

    _foliageCount      = 0
    _foliageSceneIdx   = List.filled(foliageCap, 0)
    _foliageTransforms = List.filled(foliageCap, null)

    //                                 [minScale, maxScale]
    var foliageScales = [
      [0.45, 0.7],  // 0 Bush_Common_Flowers
      [0.5,  0.8],  // 1 Fern_1
      [0.5,  0.8],  // 2 Plant_1_Big
      [0.35, 0.6],  // 3 Mushroom_Common
      [0.35, 0.6],  // 4 Mushroom_Laetiporus
      [0.3,  0.5],  // 5 Flower_3_Group
      [0.3,  0.5],  // 6 Flower_4_Group
      [0.4,  0.6],  // 7 Grass_Common_Tall
      [0.4,  0.6]   // 8 Grass_Wispy_Tall
    ]

    var sceneCount = _foliage.count
    var j = 0
    while (j < rawCount && _foliageCount < foliageCap) {
      var x = fxRaw[j]
      var z = fzRaw[j]
      var dx = (x - pathX(z)).abs
      // Keepout aligned with the cream→green band end (+1.5),
      // matching scatterGrass_. Foliage (bushes / ferns / flower
      // groups / tall grass) stays clear of the painted ring.
      if (dx > pathHalfWidth + 1.5 && insideBlob_(x, z)) {
        // Weighted pattern — tall-grass-tuft variants
        // (idx 7 Grass_Common_Tall, idx 8 Grass_Wispy_Tall)
        // claim ~70% of placements so the field reads as
        // a proper grass meadow with scattered flora woven
        // through. 20-slot pattern:
        //   bushes/ferns/plants  (0,1,2) — 2 slots (~10%)
        //   mushrooms            (3,4)   — 2 slots (~10%)
        //   flower groups        (5,6)   — 2 slots (~10%)
        //   tall grass tufts     (7,8)   — 14 slots (~70%) ← hero
        var foliagePattern = [7, 8, 7, 8, 7, 8, 7, 0, 8, 7, 8, 7, 8, 7, 1, 8, 7, 8, 7, 2]
        var idx = foliagePattern[_foliageCount % foliagePattern.count]
        // Uniform yaw — see scatterProps_ for the bias fix.
        var h    = (x * 12.9898 + z * 78.233 + idx * 5.7172).sin * 43758.5453
        var yaw  = (h - h.floor) * 6.28318
        var range = foliageScales[idx]
        var t     = (x * 1.91 + z * 2.47).sin * 0.5 + 0.5
        var scale = range[0] + t * (range[1] - range[0])
        _foliageSceneIdx[_foliageCount]   = idx
        _foliageTransforms[_foliageCount] = trsY(x, heightAt(x, z), z, scale, yaw)
        _foliageCount = _foliageCount + 1
      }
      j = j + 1
    }
  }

  // Dense petal/flower scatter. Tighter spacing than the main
  // foliage pass so the field reads as dotted with colour rather
  // than spotted. Drops sites that land on the path OR outside
  // the blob terrain edge.
  scatterPetals_() {
    var raw = Foliage.scatter({
      "bounds":  [-22, -22, 22, 22],
      "spacing": 0.38,
      "jitter":  0.55,
      "seed":    77777
    })
    var pxRaw    = raw["xs"]
    var pzRaw    = raw["zs"]
    var rawCount = raw["count"]
    shuffleSites_(pxRaw, pzRaw, rawCount, 77777 + 7)

    _petalCount      = 0
    _petalSceneIdx   = List.filled(petalCap, 0)
    _petalTransforms = List.filled(petalCap, null)
    var sceneCount = _petals.count
    var j = 0
    while (j < rawCount && _petalCount < petalCap) {
      var x = pxRaw[j]
      var z = pzRaw[j]
      var dx = (x - pathX(z)).abs
      // Keepout aligned with the cream→green band end (+1.5).
      // Petals were sitting on the path edge at +0.2 — moved out
      // so they decorate the field, not the walk surface.
      if (dx > pathHalfWidth + 1.5 && insideBlob_(x, z)) {
        // Round-robin by iteration index — sites are already
        // shuffled deterministically above, so `_petalCount %
        // sceneCount` distributes every archetype evenly across
        // the field instead of relying on the biased
        // arcsine-distributed `.sin` hash that was over-weighting
        // index 0 and index sceneCount-1.
        var idx = _petalCount % sceneCount
        // Uniform yaw — see scatterProps_ for the bias fix.
        var h    = (x * 12.9898 + z * 78.233 + idx * 8.3219).sin * 43758.5453
        var yaw  = (h - h.floor) * 6.28318
        var t     = (x * 5.91 + z * 9.47).sin * 0.5 + 0.5
        // Petals + small flowers are tiny in Quaternius native
        // units, keep them under 0.5 m so they don't fight the
        // foliage scatter visually.
        var scale = 0.28 + t * 0.18
        _petalSceneIdx[_petalCount]   = idx
        _petalTransforms[_petalCount] = trsY(x, heightAt(x, z), z, scale, yaw)
        _petalCount = _petalCount + 1
      }
      j = j + 1
    }
  }

  scatterStones_() {
    _stoneCount      = 0
    _stoneSceneIdx   = List.filled(stoneCap, 0)
    _stoneTransforms = List.filled(stoneCap, null)
    // Original road-tile layout — restored from the very first
    // iteration that read as proper old road tiles. Single
    // column along the path centreline with `sin * 0.7` lateral
    // wobble; idx draws from ALL 4 stone variants (the larger
    // RockPath_Round_Small_1 + RockPath_Round_Wide give the
    // tile look, the Pebble variants fill between them). Scale
    // 0.55..0.90 — these are flat road tiles, not grit.
    var step = 28.0 / (stoneCap + 1)
    var z = -14 + step
    while (_stoneCount < stoneCap) {
      var cx    = pathX(z)
      var off   = (z * 4.17).sin * 0.7
      var idx   = (((z * 1.91).sin * 0.5 + 0.5) * _stoneScenes.count).floor
      if (idx >= _stoneScenes.count) idx = _stoneScenes.count - 1
      var h     = (z * 12.9898 + idx * 11.917).sin * 43758.5453
      var yaw   = (h - h.floor) * 6.28318
      var scale = 0.55 + ((z * 1.33).sin * 0.5 + 0.5) * 0.35
      var sx = cx + off
      _stoneSceneIdx[_stoneCount]   = idx
      _stoneTransforms[_stoneCount] = trsY(sx, heightAt(sx, z), z, scale, yaw)
      _stoneCount = _stoneCount + 1
      z = z + step
    }
  }

  scatterGrass_(device) {
    // Dense scatter at 0.22 spacing with full-jitter placement +
    // a soft Perlin-ish noise mask. The mask drops only the
    // bottom ~15% of sites — most of the field is covered, but
    // the noise valleys carve organic bare-soil patches a viewer
    // can walk between. Tunable by raising `noiseThreshold` if
    // the grass needs to thin.
    // True grass-mat density — spacing 0.16 over the 46×46
    // field gives ~83k tufts before mask, ×4 blades per tuft
    // ≈ 300k blades. The cross-product instance buffer is one
    // `writeFloats` call so the GPU upload stays bounded;
    // drawMeshInstanced renders the whole field in a single
    // draw at any density. Soil shows through the noise-cut
    // patches only — the field reads as a continuous mat.
    var sites = Foliage.scatter({
      "bounds":  [-23, -23, 23, 23],
      "spacing": 0.16,
      "jitter":  0.42,
      "seed":    1337
    })
    var bladesPerSite = 4
    var siteCount = sites["count"]
    var xs = sites["xs"]
    var zs = sites["zs"]
    var keptTufts = 0
    var tuftKeep = List.filled(siteCount, false)
    var ti = 0
    while (ti < siteCount) {
      var x = xs[ti]
      var z = zs[ti]
      var dx = (x - pathX(z)).abs
      // Patchy noise: about 65% of off-path sites get a tuft,
      // the rest leave bare soil. Trig-hash mimics blue noise
      // without pulling @hatch:noise into the demo's deps.
      // Lightly-pruned noise mask — drops only the bottom
      // ~8% of sites so soil shows only at the wettest
      // valleys, keeping the rest of the field as a mat.
      var n1 = ((x * 4.13 + z * 5.71).sin * 0.5 + 0.5) * 0.6
      var n2 = ((x * 1.71 - z * 2.31).sin * 0.5 + 0.5) * 0.4
      var noise = n1 + n2
      // Keepout pushed to pathHalfWidth + 1.5 so blades start
      // AFTER the painted cream→green smoothstep band ends
      // (band runs to pathHalfWidth + 1.5). Exposes the green
      // soil ring as a visible buffer between path and field.
      if (dx > pathHalfWidth + 1.5 && noise > 0.08 && insideBlob_(x, z)) {
        tuftKeep[ti] = true
        keptTufts = keptTufts + 1
      }
      ti = ti + 1
    }
    // Bucket each tuft to one of 3 hue buckets (apple / olive /
    // yellow) by sampling a LOW-frequency simplex noise field at
    // the tuft's world position. The previous trig hash on (x, z)
    // produced salt-and-pepper distribution — every blade was
    // essentially independent of its neighbours, so the eye read
    // the field as a noisy mix instead of a real meadow. Low-freq
    // simplex (0.085 ≈ ~7 m patches) groups nearby tufts into the
    // same hue band; a smaller secondary noise nudges the patch
    // edges so they're irregular instead of round blobs.
    var bucketCount = 3
    var bucketTufts = List.filled(bucketCount, 0)
    var tuftBucket  = List.filled(siteCount, 0)
    var bi = 0
    while (bi < siteCount) {
      if (tuftKeep[bi]) {
        var x = xs[bi]
        var z = zs[bi]
        var nLow  = Noise.simplex2(x * 0.085, z * 0.085, 4242)
        var nEdge = Noise.simplex2(x * 0.28,  z * 0.28,  5151)
        var h = (nLow * 0.78 + nEdge * 0.22) * 0.5 + 0.5
        if (h < 0) h = 0
        if (h > 1) h = 1
        var bucket = (h * bucketCount).floor
        if (bucket >= bucketCount) bucket = bucketCount - 1
        tuftBucket[bi]  = bucket
        bucketTufts[bucket] = bucketTufts[bucket] + 1
      }
      bi = bi + 1
    }

    _grassCount       = keptTufts * bladesPerSite
    _grassBucketCount = List.filled(bucketCount, 0)
    var scratches = List.filled(bucketCount, null)
    var slots     = List.filled(bucketCount, 0)
    var k = 0
    while (k < bucketCount) {
      _grassBucketCount[k] = bucketTufts[k] * bladesPerSite
      scratches[k] = Float32Array.new(_grassBucketCount[k] * 32)
      k = k + 1
    }

    var twoPiThird = 3.14159 * 2 / 3
    var n = 0
    while (n < siteCount) {
      if (tuftKeep[n]) {
        var x = xs[n]
        var zq = zs[n]
        var bucket = tuftBucket[n]
        var scratch = scratches[bucket]
        var baseYaw = (x * 7.31 + zq * 11.07).sin * 3.14159
        // Per-tuft (group) height bias from a low-frequency
        // simplex field — ~10 m patches of short, mid, and tall
        // grass like a real meadow. All blades within a tuft
        // share this bias so neighbouring tufts read as part of
        // the same patch instead of salt-and-pepper differences.
        // The freq (0.1) is intentionally lower than the hue
        // patch noise (0.085) so the height patches are LARGER
        // than hue patches — height carries more visual weight.
        var hN     = Noise.simplex2(x * 0.10, zq * 0.10, 7777)
        var hBias  = hN * 0.5 + 1.0   // 0.5..1.5 (short field → tall field)
        var b = 0
        while (b < bladesPerSite) {
          var yaw = baseYaw + b * twoPiThird
          // Per-blade variation cut from 0.8 → 0.30 so blades
          // within a tuft read as one coherent clump at the
          // patch height, not staggered individually.
          var rand = ((x * 17.3 + zq * 9.7 + b * 31.1).sin * 0.5 + 0.5)
          var scale = (0.85 + rand * 0.30) * hBias
          Renderer3D.writeInstanceXYZ(scratch, slots[bucket], x, heightAt(x, zq), zq, scale, yaw)
          slots[bucket] = slots[bucket] + 1
          b = b + 1
        }
      }
      n = n + 1
    }

    _grassBuffers = List.filled(bucketCount, null)
    var j = 0
    while (j < bucketCount) {
      if (_grassBucketCount[j] > 0) {
        var buf = device.createBuffer({
          "size":  _grassBucketCount[j] * 128,
          "usage": ["storage", "copy-dst"],
          "label": "grass-instances-" + j.toString
        })
        buf.writeFloats(0, scratches[j])
        _grassBuffers[j] = buf
      }
      j = j + 1
    }
  }

  trsY(x, y, z, scale, yawRad) {
    return Mat4.translation(x, y, z) * Mat4.rotationY(yawRad) * Mat4.scale(scale, scale, scale)
  }

  drawScene(scene, xform) {
    var meshes = scene.meshes
    var mi = 0
    while (mi < meshes.count) {
      var prims = meshes[mi].primitives
      var pj = 0
      while (pj < prims.count) {
        var prim = prims[pj]
        if (prim.mesh != null && prim.material != null) {
          _renderer3d.draw(prim.mesh, prim.material, xform)
        }
        pj = pj + 1
      }
      mi = mi + 1
    }
  }

  drawShadowScene(scene, xform) {
    var meshes = scene.meshes
    var mi = 0
    while (mi < meshes.count) {
      var prims = meshes[mi].primitives
      var pj = 0
      while (pj < prims.count) {
        var prim = prims[pj]
        if (prim.mesh != null) {
          _renderer3d.drawShadow(prim.mesh, xform)
        }
        pj = pj + 1
      }
      mi = mi + 1
    }
  }

  orbitEye {
    var cy = _yaw.cos
    var sy = _yaw.sin
    var cp = _pitch.cos
    var sp = _pitch.sin
    return Vec3.new(
      _target.x + _distance * cp * sy,
      _target.y + _distance * sp,
      _target.z + _distance * cp * cy)
  }

  resize(g, w, h) {
    _camera.setPerspective(55, w / h, 0.1, 200)
  }

  update(g) {
    // Snapshot mouse position every frame so the dragging branch
    // has a delta available the first frame the chart enters
    // `dragging`. Reading mouseX/Y on the active fiber's frame is
    // safe now that minor + major GC trace old fibers
    // unconditionally (project_fiber_set_reg_barrier.md).
    var mx = g.input.mouseX
    var my = g.input.mouseY
    var dmx = mx - _lastMx
    var dmy = my - _lastMy
    _lastMx = mx
    _lastMy = my

    if (_chart.activeStates.contains("paused")) return

    var dt = g.dt

    // Mouse drag: pixel deltas → orbit angles. Only consumes the
    // delta when the chart sits in `dragging`, which the Actions
    // emitter toggles via the MouseLeft press / release edges.
    if (_chart.activeStates.contains("dragging")) {
      _yaw   = _yaw   - dmx * 0.006
      _pitch = _pitch + dmy * 0.005
    }

    // Mouse wheel: zoom. `scrollY` is a per-frame delta that
    // `beginFrame_` zeros out, so reading it directly is the
    // canonical pattern — no Actions binding for scroll wheel.
    var sy = g.input.scrollY
    if (sy != 0) _distance = _distance - sy * 3.5

    // Keyboard fallbacks via Actions for users without a mouse.
    var yawRate   = Actions.value("orbit.right") - Actions.value("orbit.left")
    var pitchRate = Actions.value("orbit.down")  - Actions.value("orbit.up")
    var zoomRate  = Actions.value("zoom.out")    - Actions.value("zoom.in")
    _yaw      = _yaw      + yawRate   * dt * 1.6
    _pitch    = _pitch    + pitchRate * dt * 1.2
    _distance = _distance + zoomRate  * dt * 14.0

    // WASD pans the camera TARGET around the disc. Movement is
    // aligned with the camera's yaw — `pan.forward` moves you
    // toward where the camera looks (not world +Z), so navigation
    // is intuitive regardless of orbital angle.
    var fwdAxis   = Actions.value("pan.forward") - Actions.value("pan.back")
    var rightAxis = Actions.value("pan.right")   - Actions.value("pan.left")
    if (fwdAxis != 0 || rightAxis != 0) {
      var panSpeed = 12.0
      var cy = _yaw.cos
      var sy = _yaw.sin
      // Forward vector (camera-relative) projected to the horizontal
      // plane. With yaw=0 the camera looks along +Z so forward = +Z.
      var fwdX  = sy
      var fwdZ  = cy
      // Right vector is forward rotated -90° around Y.
      var rightX =  cy
      var rightZ = -sy
      _target.x = _target.x + (fwdX * fwdAxis + rightX * rightAxis) * panSpeed * dt
      _target.z = _target.z + (fwdZ * fwdAxis + rightZ * rightAxis) * panSpeed * dt
      // Clamp to the disc bounds so the camera can't fly off
      // into the void beyond the painted soil.
      var maxR = 20.0
      var r2 = _target.x * _target.x + _target.z * _target.z
      if (r2 > maxR * maxR) {
        var scale = maxR / r2.sqrt
        _target.x = _target.x * scale
        _target.z = _target.z * scale
      }
    }
    // Lower pitch floor (0.08 rad ≈ 4.6°) lets the camera drop
    // closer to ground level for a more "walking through the
    // garden" framing. With target.y = 2 and min distance 6,
    // eye.y at pitch 0.08 sits at 2 + 6*sin(0.08) ≈ 2.48 — still
    // a comfortable margin above the soil disc, no backface view.
    if (_pitch >  1.4) _pitch =  1.4
    if (_pitch <  0.08) _pitch =  0.08
    // Distance clamps — min 4 keeps the camera from clipping into
    // the player's "personal space" / grass; max 120 lets the user
    // pull back to see the whole 46 m disc plus the painted-sky
    // backdrop. Stays comfortably inside the perspective far
    // plane (200 m) and the OutlinePass fadeFar (~70 m), so far
    // props read as painted shapes once you're zoomed all the way
    // out.
    if (_distance <   4) _distance =   4
    if (_distance > 120) _distance = 120
  }

  draw(g) {
    var t = g.elapsed
    _camera.lookAt(orbitEye, _target, _upY)

    _renderer3d.beginFrame(g.pass, _camera)
    _renderer3d.setAmbient(_ambient, 1.0)
    _renderer3d.setEnvironment(_envTop, _envHorizon, _envBottom)
    _renderer3d.setWind(1.0, 0.25, 0.6)
    _renderer3d.setWindTime(t)
    // 4-arg opts the sun in as the shadow caster — the toon
    // pass samples the depth map baked at setup.
    _renderer3d.addDirectional(_sunDir, _sunColor, _sunIntensity, true)
    // Cool fill from the opposite quadrant lifts the shadow side
    // of every prop just enough to read as form (vs silhouette)
    // without competing with the warm key for which side reads
    // as "lit".
    _renderer3d.addDirectional(_fillDir, _fillColor, _fillIntensity)

    _renderer3d.draw(_ground, _groundMat, _groundTransform)
    var gb = 0
    while (gb < _grassBuffers.count) {
      if (_grassBuffers[gb] != null && _grassBucketCount[gb] > 0) {
        _renderer3d.drawMeshInstanced(_blade, _grassMats[gb], _grassBuffers[gb], _grassBucketCount[gb])
      }
      gb = gb + 1
    }

    var i = 0
    while (i < _propCount) {
      drawScene(_scenes[_propSceneIdx[i]], _propTransforms[i])
      i = i + 1
    }

    var f = 0
    while (f < _foliageCount) {
      drawScene(_foliage[_foliageSceneIdx[f]], _foliageTransforms[f])
      f = f + 1
    }

    var p = 0
    while (p < _petalCount) {
      drawScene(_petals[_petalSceneIdx[p]], _petalTransforms[p])
      p = p + 1
    }

    // Path pebbles main-pass draw — without this they cast tiny
    // shadows (line 510) but their meshes never render.
    var sk = 0
    while (sk < _stoneCount) {
      drawScene(_stoneScenes[_stoneSceneIdx[sk]], _stoneTransforms[sk])
      sk = sk + 1
    }

    // Fireflies — four perimeter emitters (compass points around
    // the disc). Compute dispatches run the WGSL integrate against
    // each system's storage buffer; drawBillboardN renders all
    // alive sparks per system in a single instanced draw. Bloom
    // picks up the HDR-amber pixels (start ~5.9 luma, well past
    // the 0.78 threshold) and turns each spark into a wide
    // amber halo through the postFX chain.
    _fireflies.compute(g.encoder)
    _fireflies2.compute(g.encoder)
    _fireflies3.compute(g.encoder)
    _fireflies4.compute(g.encoder)
    _fireflies.draw(_renderer3d)
    _fireflies2.draw(_renderer3d)
    _fireflies3.draw(_renderer3d)
    _fireflies4.draw(_renderer3d)

    // FPS readout to stdout — every ~60 frames so the log
    // doesn't flood. EMA dampens digit jitter.
    var dt = t - _lastElapsed
    _lastElapsed = t
    if (dt > 0.0001) {
      var instFps = 1.0 / dt
      _fpsEma = _fpsEma * 0.92 + instFps * 0.08
    }
    _fpsPrintTick = _fpsPrintTick + 1
    if (_fpsPrintTick >= 60) {
      _fpsPrintTick = 0
      System.print("FPS %(_fpsEma.floor)")
    }
  }
}

Game.run(NatureGarden)
