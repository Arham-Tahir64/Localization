# Spatial mesh fidelity correction

Date: 2026-08-11

## Previous discrepancy

HouseMapper enabled ARKit scene reconstruction and drew each live `ARMeshAnchor`
over the camera, but saved only `ARWorldMap.rawFeaturePoints` into its app-owned
spatial sidecar. Reload therefore had no explicit surface vertices, normals,
topology, classifications, or mesh-anchor transforms. The mini-map could only draw
a height-banded landmark scatter, which explains why the saved map looked unlike
the dense structured reference.

## Implemented data path

1. At save time the app snapshots `ARFrame.anchors`, which is ARKit's current list
   of session anchors, and selects real `ARMeshAnchor` values.
2. Metal-backed ARKit buffers are copied with their declared offset and stride.
   Only the documented float3 vertex/normal, triangle, 16/32-bit-index, and uchar
   classification layouts are accepted; unsupported layouts fail explicitly.
3. Each anchor remains in its local coordinate frame and retains the exact
   column-major rigid `T_map_anchor` transform.
4. Schema 2 stores vertices, normals, indexed triangle topology, and optional
   per-face ARKit classification beside the full landmark set. Schema 1 landmark-
   only snapshots still decode.
5. Reload validates IDs, transforms, finite geometry, normal counts, indices,
   classifications, map identity, and exact combined bounds.
6. The map panel applies `T_map_anchor` and batches the actual selected triangle
   edges into one top-down Canvas path behind the real landmarks and tracked pose.

No surface is inferred from point proximity and no decorative map geometry is
generated.

## Scope and remaining validation

The generic-device Debug test build and Release build prove compilation and test
target membership, while deterministic XCTest cases cover schema round-trip,
legacy decode, invalid topology, duplicate anchors, transforms, and render edges.
Host microbenchmarks cover exact codec equality and render-model construction.

Because ARKit camera/LiDAR sessions do not run in Simulator, the next physical
iPhone validation must record the observed mesh-anchor/triangle counts, saved
package size, save latency, reload counts, Canvas frame time, memory, and thermal
state. A newly created map is required to exercise schema 2; existing schema 1
packages remain valid but cannot contain mesh data that the old build never saved.
