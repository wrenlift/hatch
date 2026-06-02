// mesh-lod-pick — drive MeshLOD.pickIndex / meshAt over a list of
// instances at varying camera distances. A real foliage / crowd
// pass packs each instance's transform into the per-LOD bucket
// MeshLOD returned, then calls Renderer3D.drawInstancedLOD with
// the parallel-array of buffers.

import "@hatch:gpu" for MeshLOD, Lod

// Stand-in for a real Mesh — MeshLOD never reads any GPU state in
// the pure-Wren API path, just stashes the references.
class StubMesh {
  construct new(label) { _label = label }
  label { _label }
}

var hi  = StubMesh.new("highRes")
var mid = StubMesh.new("midRes")
var lo  = StubMesh.new("lowRes")
var lod = MeshLOD.fromDistances([hi, mid, lo], [10, 30])  // 0 < 10 < 30 < ∞

var instances = [
  [5, 0, 0],     // close
  [15, 0, 0],    // mid
  [50, 0, 0],    // far
  [0, 0, 100]    // very far
]
var eye = [0, 0, 0]

System.print("MeshLOD with thresholds [10m, 30m]:")
for (inst in instances) {
  var i = lod.pickIndex(eye[0], eye[1], eye[2], inst[0], inst[1], inst[2])
  System.print("  instance at (%(inst[0]), %(inst[1]), %(inst[2])) → tier %(i) (%(lod.meshAt(i).label))")
}

// Lod.selectN for callers that haven't built a MeshLOD yet — same
// shape, just returns the bucket index.
System.print("\nLod.selectN with squared thresholds [100, 900] (10m, 30m):")
for (inst in instances) {
  var i = Lod.selectN(0, 0, 0, inst[0], inst[1], inst[2], [100, 900])
  System.print("  instance at (%(inst[0]), %(inst[1]), %(inst[2])) → tier %(i)")
}
