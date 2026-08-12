import Foundation

private struct MeshFixture {
    let anchor: SpatialMeshAnchorRecord
    let triangleCount: Int
}

private func makeGridMesh(minimumTriangleCount: Int) throws -> MeshFixture {
    let cellsPerSide = Int(ceil(sqrt(Double(minimumTriangleCount) / 2)))
    let verticesPerSide = cellsPerSide + 1
    var vertices: [Vector3Record] = []
    var normals: [Vector3Record] = []
    vertices.reserveCapacity(verticesPerSide * verticesPerSide)
    normals.reserveCapacity(verticesPerSide * verticesPerSide)
    for z in 0..<verticesPerSide {
        for x in 0..<verticesPerSide {
            vertices.append(
                Vector3Record(
                    x: Float(x) * 0.04,
                    y: Float((x &* 17 + z &* 31) % 13) * 0.003,
                    z: -Float(z) * 0.04
                )
            )
            normals.append(Vector3Record(x: 0, y: 1, z: 0))
        }
    }

    var faces: [SpatialMeshFaceRecord] = []
    faces.reserveCapacity(cellsPerSide * cellsPerSide * 2)
    for z in 0..<cellsPerSide {
        for x in 0..<cellsPerSide {
            let first = UInt32(z * verticesPerSide + x)
            let second = first + 1
            let third = UInt32((z + 1) * verticesPerSide + x)
            let fourth = third + 1
            let classification = (x + z) % 8
            faces.append(
                SpatialMeshFaceRecord(
                    firstVertexIndex: first,
                    secondVertexIndex: third,
                    thirdVertexIndex: second,
                    classificationRawValue: classification
                )
            )
            faces.append(
                SpatialMeshFaceRecord(
                    firstVertexIndex: second,
                    secondVertexIndex: third,
                    thirdVertexIndex: fourth,
                    classificationRawValue: classification
                )
            )
        }
    }

    return try MeshFixture(
        anchor: SpatialMeshAnchorRecord(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            mapFromAnchor: SpatialTransformRecord(
                values: [
                    1, 0, 0, 0,
                    0, 1, 0, 0,
                    0, 0, 1, 0,
                    3, 0.5, -2, 1
                ]
            ),
            vertices: vertices,
            normals: normals,
            faces: faces
        ),
        triangleCount: faces.count
    )
}

for requestedTriangleCount in [10_000, 100_000] {
    let fixture = try makeGridMesh(minimumTriangleCount: requestedTriangleCount)
    let mapID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let snapshot = try SpatialMapSnapshot(
        mapID: mapID,
        landmarks: [],
        meshAnchors: [fixture.anchor]
    )

    let encodeStart = DispatchTime.now().uptimeNanoseconds
    let data = try SpatialMapSnapshotCodec.encode(snapshot)
    let encodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1_000_000

    let decodeStart = DispatchTime.now().uptimeNanoseconds
    let decoded = try SpatialMapSnapshotCodec.decode(data, expectedMapID: mapID)
    let decodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000
    precondition(decoded == snapshot)

    let renderIterations = requestedTriangleCount == 10_000 ? 100 : 20
    let renderStart = DispatchTime.now().uptimeNanoseconds
    var renderChecksum = 0
    for iteration in 0..<renderIterations {
        let render = SpatialMeshRenderSnapshot.make(
            meshAnchors: snapshot.meshAnchors,
            maximumTriangleCount: 1_499 + (iteration & 1)
        )
        renderChecksum &+= render.triangles.count
        renderChecksum &+= Int(render.bounds.maximum.x - render.bounds.minimum.x)
        if let first = render.triangles.first {
            renderChecksum &+= Int(first.first.x.bitPattern & 0xFF)
        }
    }
    let renderMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - renderStart)
        / Double(renderIterations) / 1_000_000

    let formattedEncode = String(format: "%.3f", encodeMilliseconds)
    let formattedDecode = String(format: "%.3f", decodeMilliseconds)
    let formattedRender = String(format: "%.4f", renderMilliseconds)
    print(
        "triangles=\(fixture.triangleCount) vertices=\(fixture.anchor.vertices.count) "
            + "bytes=\(data.count) "
            + "encode_ms=\(formattedEncode) "
            + "decode_ms=\(formattedDecode) "
            + "render_lod_ms=\(formattedRender) "
            + "checksum=\(renderChecksum)"
    )
}
