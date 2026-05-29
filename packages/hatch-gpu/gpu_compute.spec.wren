// @hatch:gpu — compute pipeline + storage buffer integration.
//
// Smoke test for the new ComputePipeline / ComputePass surface:
// upload a Float32Array into a storage buffer, dispatch a
// `data[i] *= 2.0` compute shader, copy to a staging buffer, read
// back, and assert every element doubled. Also covers the readInto
// fast path used by larger workloads.

import "./gpu" for
  Gpu, Device, Buffer, ShaderModule, BindGroupLayout, BindGroup,
  PipelineLayout, ComputePipeline, CommandEncoder, ComputePass
import "@hatch:time"   for Clock
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// Doubles every element of a flat storage<float32> array. The
// caller dispatches `ceil(count / 64)` workgroups.
var DOUBLE_SHADER = "
@group(0) @binding(0) var<storage, read_write> data: array<f32>;

@compute @workgroup_size(64)
fn double_inplace(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i < arrayLength(&data)) {
    data[i] = data[i] * 2.0;
  }
}
"

class ComputeHarness {
  construct new(device, count) {
    _device = device
    _count = count
    _byteSize = count * 4

    _shader = device.createShaderModule({ "code": DOUBLE_SHADER })

    _bgl = device.createBindGroupLayout({
      "entries": [{
        "binding":    0,
        "visibility": ["compute"],
        "kind":       "storage"
      }]
    })
    _layout = device.createPipelineLayout({ "bindGroupLayouts": [_bgl] })

    _pipeline = device.createComputePipeline({
      "module":     _shader,
      "entryPoint": "double_inplace",
      "layout":     _layout
    })

    _data = device.createBuffer({
      "size":  _byteSize,
      "usage": ["storage", "copy-src", "copy-dst"]
    })
    _staging = device.createBuffer({
      "size":  _byteSize,
      "usage": ["copy-dst", "map-read"]
    })
    _bindGroup = device.createBindGroup({
      "layout":  _bgl,
      "entries": [{ "binding": 0, "buffer": _data }]
    })
  }

  device { _device }
  data { _data }
  staging { _staging }

  upload(floats) { _data.writeFloats(0, floats) }

  // Dispatch the doubling kernel, copy result into the staging
  // buffer, and submit. Caller follows up with `readback` once
  // the GPU drains.
  run {
    var enc = _device.createCommandEncoder()
    var pass = enc.beginComputePass()
    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, _bindGroup)
    var groups = ((_count + 63) / 64).floor
    pass.dispatchWorkgroups(groups)
    pass.end
    enc.copyBufferToBuffer(_data, _staging, _byteSize)
    _device.submit([enc.finish])
  }

  readback {
    var out = Float32Array.new(_count)
    _staging.readInto(out)
    return out
  }

  destroy {
    _data.destroy
    _staging.destroy
    _bindGroup.destroy
    _pipeline.destroy
    _layout.destroy
    _bgl.destroy
    _shader.destroy
  }
}

Test.describe("ComputePipeline + ComputePass") {
  Test.it("doubles a small Float32Array via storage buffer + compute dispatch") {
    var device = Gpu.requestDevice()
    var input = Float32Array.fromList([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0])
    var h = ComputeHarness.new(device, 8)
    h.upload(input)
    h.run
    var out = h.readback
    for (i in 0...8) Expect.that(out[i]).toBe((i + 1) * 2)
    h.destroy
    device.destroy
  }

  Test.it("dispatch is idempotent across multiple encoder cycles") {
    var device = Gpu.requestDevice()
    var input = Float32Array.fromList([1.0, 2.0, 3.0, 4.0])
    var h = ComputeHarness.new(device, 4)
    h.upload(input)
    h.run                                // [2,4,6,8]
    var first = h.readback
    // Re-upload the *output* and double it again.
    h.upload(first)
    h.run                                // [4,8,12,16]
    var second = h.readback
    for (i in 0...4) Expect.that(second[i]).toBe((i + 1) * 4)
    h.destroy
    device.destroy
  }

  Test.it("readInto rejects a typed array of the wrong byte length") {
    var device = Gpu.requestDevice()
    var h = ComputeHarness.new(device, 4)
    h.upload(Float32Array.fromList([1.0, 2.0, 3.0, 4.0]))
    h.run
    var wrongSize = Float32Array.new(8)  // 32 bytes vs 16
    var e = Fiber.new { h.staging.readInto(wrongSize) }.try()
    Expect.that(e).toContain("byte length")
    h.destroy
    device.destroy
  }

  Test.it("handles a workload larger than a single workgroup (8192 elements)") {
    var device = Gpu.requestDevice()
    var n = 8192
    var input = Float32Array.new(n)
    for (i in 0...n) input[i] = (i + 1) * 1.0
    var h = ComputeHarness.new(device, n)
    h.upload(input)
    h.run
    var out = h.readback
    // Spot-check a handful of indices instead of all 8k.
    Expect.that(out[0]).toBe(2)
    Expect.that(out[63]).toBe(128)
    Expect.that(out[64]).toBe(130)
    Expect.that(out[n - 1]).toBe(n * 2)
    h.destroy
    device.destroy
  }
}

// Exit-gate microbench. Logs the per-run submit + readback wall
// clock for a 1M-element doubling pass. Asserts only correctness
// — the wall-clock floor is read off the printed line by hand so
// host-hardware variance doesn't flake CI.
Test.describe("ComputePipeline exit-gate") {
  Test.it("doubles 1M Float32 in a single 4096-workgroup dispatch") {
    var device = Gpu.requestDevice()
    var n = 1024 * 1024
    var byteSize = n * 4
    var group = 256
    var groups = ((n + group - 1) / group).floor
    var runs = 5

    var src = "
@group(0) @binding(0) var<storage, read_write> data: array<f32>;
@compute @workgroup_size(256)
fn double_inplace(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i < arrayLength(&data)) { data[i] = data[i] * 2.0; }
}
"
    var shader = device.createShaderModule({ "code": src })
    var bgl = device.createBindGroupLayout({
      "entries": [{ "binding": 0, "visibility": ["compute"], "kind": "storage" }]
    })
    var layout = device.createPipelineLayout({ "bindGroupLayouts": [bgl] })
    var pipeline = device.createComputePipeline({
      "module": shader, "entryPoint": "double_inplace", "layout": layout
    })
    var data = device.createBuffer({
      "size":  byteSize,
      "usage": ["storage", "copy-src", "copy-dst"]
    })
    var staging = device.createBuffer({
      "size":  byteSize,
      "usage": ["copy-dst", "map-read"]
    })
    var bg = device.createBindGroup({
      "layout": bgl, "entries": [{ "binding": 0, "buffer": data }]
    })

    var seed = Float32Array.new(n)
    for (i in 0...n) seed[i] = 1.0
    data.writeFloats(0, seed)

    // Warmup pass eats shader compile + queue init.
    {
      var enc = device.createCommandEncoder()
      var pass = enc.beginComputePass()
      pass.setPipeline(pipeline)
      pass.setBindGroup(0, bg)
      pass.dispatchWorkgroups(groups)
      pass.end
      enc.copyBufferToBuffer(data, staging, byteSize)
      device.submit([enc.finish])
      var sink = Float32Array.new(n)
      staging.readInto(sink)
    }

    var dispatch = 0
    var readback = 0
    var lastFirst = 0
    for (r in 0...runs) {
      data.writeFloats(0, seed)
      var t0 = Clock.mono * 1000
      var enc = device.createCommandEncoder()
      var pass = enc.beginComputePass()
      pass.setPipeline(pipeline)
      pass.setBindGroup(0, bg)
      pass.dispatchWorkgroups(groups)
      pass.end
      enc.copyBufferToBuffer(data, staging, byteSize)
      device.submit([enc.finish])
      var t1 = Clock.mono * 1000
      var out = Float32Array.new(n)
      staging.readInto(out)
      var t2 = Clock.mono * 1000
      dispatch = dispatch + (t1 - t0)
      readback = readback + (t2 - t1)
      lastFirst = out[0]
    }

    System.print("[bench] 1M Float32 doubling, workgroup=256, groups=%(groups), runs=%(runs)")
    System.print("[bench] submit            mean: %(dispatch / runs) ms")
    System.print("[bench] readback + memcpy mean: %(readback / runs) ms")

    Expect.that(lastFirst).toBe(2)

    data.destroy
    staging.destroy
    bg.destroy
    pipeline.destroy
    layout.destroy
    bgl.destroy
    shader.destroy
    device.destroy
  }
}

Test.run()
