import SceneKit
import SwiftUI

/// An external-camera view of the real saved/mapping landmark cloud. The gray
/// layer is the map; green points are only landmark IDs supported by the current
/// native relocalization or server PnP result.
struct SpatialPointCloudView: UIViewRepresentable {
    let map: SpatialMapRenderSnapshot
    let trail: [SIMD2<Float>]
    let pose: CameraPose?
    let localizationSupportPoints: [SpatialMapRenderPoint]
    let accentColor: Color

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = SCNScene()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = false
        context.coordinator.installCamera(in: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(
            view: view,
            map: map,
            trail: trail,
            pose: pose,
            localizationSupportPoints: localizationSupportPoints,
            accentColor: UIColor(accentColor)
        )
    }

    @MainActor
    final class Coordinator {
        private let mapNode = SCNNode()
        private let highlightNode = SCNNode()
        private let trailNode = SCNNode()
        private let phoneNode = SCNNode()
        private let cameraNode = SCNNode()
        private let cameraTargetNode = SCNNode()
        private var previousMap = SpatialMapRenderSnapshot.empty
        private var previousTrail: [SIMD2<Float>] = []
        private var previousSupportPoints: [SpatialMapRenderPoint] = []

        func installCamera(in view: SCNView) {
            guard let root = view.scene?.rootNode else { return }
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.fieldOfView = 52
            cameraNode.camera?.zNear = 0.01
            cameraNode.camera?.zFar = 1_000
            let look = SCNLookAtConstraint(target: cameraTargetNode)
            look.isGimbalLockEnabled = true
            cameraNode.constraints = [look]
            root.addChildNode(mapNode)
            root.addChildNode(highlightNode)
            root.addChildNode(trailNode)
            root.addChildNode(phoneNode)
            root.addChildNode(cameraTargetNode)
            root.addChildNode(cameraNode)
            view.pointOfView = cameraNode
        }

        func update(
            view: SCNView,
            map: SpatialMapRenderSnapshot,
            trail: [SIMD2<Float>],
            pose: CameraPose?,
            localizationSupportPoints: [SpatialMapRenderPoint],
            accentColor: UIColor
        ) {
            let mapChanged = map != previousMap
            if mapChanged {
                mapNode.geometry = Self.pointGeometry(
                    positions: map.points.map(\.position),
                    color: UIColor(white: 0.76, alpha: 0.72),
                    pointSize: 2.2
                )
                positionCamera(for: map)
                previousMap = map
            }

            if localizationSupportPoints != previousSupportPoints {
                highlightNode.geometry = Self.pointGeometry(
                    positions: localizationSupportPoints.map(\.position),
                    color: .systemGreen,
                    pointSize: 5.2
                )
                previousSupportPoints = localizationSupportPoints
            }

            if trail != previousTrail {
                trailNode.geometry = Self.lineGeometry(
                    positions: trail.map { SIMD3($0.x, map.bounds.minimum.y, $0.y) },
                    color: UIColor(white: 0.84, alpha: 0.76)
                )
                previousTrail = trail
            }

            updatePhoneNode(pose: pose, color: accentColor)
            view.setNeedsDisplay()
        }

        private func positionCamera(for map: SpatialMapRenderSnapshot) {
            guard map.sourceCount > 0 else {
                cameraTargetNode.position = SCNVector3(0, 0, 0)
                cameraNode.position = SCNVector3(0, 2.2, 4.5)
                return
            }
            let center = (map.bounds.minimum + map.bounds.maximum) * 0.5
            let extent = map.bounds.maximum - map.bounds.minimum
            let radius = max(max(extent.x, extent.y), max(extent.z, 1))
            cameraTargetNode.simdPosition = center
            cameraNode.simdPosition = center + SIMD3(radius * 0.68, radius * 0.48, radius * 1.18)
        }

        private func updatePhoneNode(pose: CameraPose?, color: UIColor) {
            guard let pose else {
                phoneNode.geometry = nil
                return
            }
            if phoneNode.geometry == nil {
                let pyramid = SCNPyramid(width: 0.13, height: 0.10, length: 0.20)
                pyramid.firstMaterial = Self.material(color: color)
                phoneNode.geometry = pyramid
            } else {
                phoneNode.geometry?.firstMaterial?.diffuse.contents = color
            }
            phoneNode.simdTransform = pose.mapFromCamera
        }

        private static func pointGeometry(
            positions: [SIMD3<Float>],
            color: UIColor,
            pointSize: CGFloat
        ) -> SCNGeometry? {
            guard !positions.isEmpty else { return nil }
            let vertices = positions.map { SCNVector3($0.x, $0.y, $0.z) }
            let source = SCNGeometrySource(vertices: vertices)
            let element = SCNGeometryElement(
                data: nil,
                primitiveType: .point,
                primitiveCount: vertices.count,
                bytesPerIndex: 0
            )
            element.pointSize = pointSize
            element.minimumPointScreenSpaceRadius = pointSize * 0.72
            element.maximumPointScreenSpaceRadius = pointSize * 1.35
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial = material(color: color)
            return geometry
        }

        private static func lineGeometry(
            positions: [SIMD3<Float>],
            color: UIColor
        ) -> SCNGeometry? {
            guard positions.count > 1 else { return nil }
            let vertices = positions.map { SCNVector3($0.x, $0.y, $0.z) }
            var indices: [UInt32] = []
            indices.reserveCapacity((vertices.count - 1) * 2)
            for index in 0..<(vertices.count - 1) {
                indices.append(UInt32(index))
                indices.append(UInt32(index + 1))
            }
            let source = SCNGeometrySource(vertices: vertices)
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial = material(color: color)
            return geometry
        }

        private static func material(color: UIColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.readsFromDepthBuffer = true
            material.writesToDepthBuffer = true
            return material
        }
    }
}

struct MapOverviewView: View {
    let map: SpatialMapRenderSnapshot
    let mesh: SpatialMeshRenderSnapshot
    let trail: [SIMD2<Float>]
    let pose: CameraPose?
    let accentColor: Color

    var body: some View {
        Canvas { context, size in
            let current = pose.map { SIMD2($0.position.x, $0.position.z) }
            let trailStep = max(1, trail.count / 300)
            var minX = Float.infinity
            var maxX = -Float.infinity
            var minZ = Float.infinity
            var maxZ = -Float.infinity

            func include(_ point: SIMD2<Float>) {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minZ = min(minZ, point.y)
                maxZ = max(maxZ, point.y)
            }

            if map.sourceCount > 0 {
                include(SIMD2(map.bounds.minimum.x, map.bounds.minimum.z))
                include(SIMD2(map.bounds.maximum.x, map.bounds.maximum.z))
            }
            if mesh.sourceTriangleCount > 0 {
                include(SIMD2(mesh.bounds.minimum.x, mesh.bounds.minimum.z))
                include(SIMD2(mesh.bounds.maximum.x, mesh.bounds.maximum.z))
            }
            for index in Swift.stride(from: 0, to: trail.count, by: trailStep) {
                include(trail[index])
            }
            if let current { include(current) }

            guard minX.isFinite else {
                context.draw(
                    Text("Landmarks appear as you move")
                        .font(.caption)
                        .foregroundStyle(.secondary),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
                return
            }

            minX -= 0.5
            maxX += 0.5
            minZ -= 0.5
            maxZ += 0.5
            let spanX = max(maxX - minX, 1)
            let spanZ = max(maxZ - minZ, 1)
            let scale = min((size.width - 20) / CGFloat(spanX), (size.height - 20) / CGFloat(spanZ))

            func project(_ point: SIMD2<Float>) -> CGPoint {
                CGPoint(
                    x: 10 + CGFloat(point.x - minX) * scale,
                    y: size.height - 10 - CGFloat(point.y - minZ) * scale
                )
            }

            if !mesh.triangles.isEmpty {
                var structuralPath = Path()
                for triangle in mesh.triangles {
                    structuralPath.move(to: project(SIMD2(triangle.first.x, triangle.first.z)))
                    structuralPath.addLine(to: project(SIMD2(triangle.second.x, triangle.second.z)))
                    structuralPath.addLine(to: project(SIMD2(triangle.third.x, triangle.third.z)))
                    structuralPath.closeSubpath()
                }
                context.stroke(
                    structuralPath,
                    with: .color(.cyan.opacity(0.22)),
                    lineWidth: 0.6
                )
            }

            let minimumHeight = map.bounds.minimum.y
            let heightSpan = max(map.bounds.maximum.y - minimumHeight, Float.ulpOfOne)
            var heightPaths = Array(repeating: Path(), count: 4)
            for point in map.points {
                let center = project(SIMD2(point.position.x, point.position.z))
                let normalizedHeight = (point.position.y - minimumHeight) / heightSpan
                let band = min(3, max(0, Int(normalizedHeight * 4)))
                let diameter = 1.8 + CGFloat(band) * 0.18
                heightPaths[band].addEllipse(
                    in: CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                )
            }
            for band in heightPaths.indices {
                let opacity = 0.24 + Double(band) * 0.10
                context.fill(heightPaths[band], with: .color(.white.opacity(opacity)))
            }

            if trail.count > 1 {
                var path = Path()
                path.move(to: project(trail[0]))
                for index in Swift.stride(from: trailStep, to: trail.count, by: trailStep) {
                    path.addLine(to: project(trail[index]))
                }
                if let last = trail.last { path.addLine(to: project(last)) }
                context.stroke(path, with: .color(.white.opacity(0.72)), lineWidth: 1.7)
            }

            if let pose, let current {
                let center = project(current)
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                    with: .color(accentColor)
                )

                let yaw = pose.eulerAngles.y
                let forward = SIMD2<Float>(-sin(yaw), -cos(yaw))
                let tipWorld = current + forward * 0.45
                var heading = Path()
                heading.move(to: center)
                heading.addLine(to: project(tipWorld))
                context.stroke(
                    heading,
                    with: .color(accentColor),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
            }
        }
        .background(.black)
        .overlay {
            Rectangle().stroke(.white.opacity(0.14), lineWidth: 0.75)
        }
        .accessibilityLabel("Top-down map overview")
    }
}

struct AttitudeInstrumentView: View {
    let pitch: Float?
    let roll: Float?
    let accentColor: Color

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = max(10, min(size.width, size.height) * 0.34)
                let pitchValue = CGFloat(pitch ?? 0)
                let rollValue = CGFloat(roll ?? 0)
                let pitchOffset = max(-radius * 0.62, min(radius * 0.62, pitchValue * radius))

                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(.blue.opacity(pitch == nil ? 0.10 : 0.62))
                )

                var horizon = Path()
                horizon.move(to: CGPoint(x: center.x - radius, y: center.y + pitchOffset))
                horizon.addLine(to: CGPoint(x: center.x + radius, y: center.y + pitchOffset))
                var rotatedContext = context
                rotatedContext.translateBy(x: center.x, y: center.y)
                rotatedContext.rotate(by: .radians(-rollValue))
                rotatedContext.translateBy(x: -center.x, y: -center.y)
                rotatedContext.stroke(
                    horizon,
                    with: .color(accentColor),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )

                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(.white.opacity(0.52)),
                    lineWidth: 0.8
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                    with: .color(.white)
                )
            }
            .overlay(alignment: .topLeading) {
                instrumentLabel("ATTITUDE", value: attitudeText)
            }
        }
        .background(.white.opacity(0.025))
        .overlay { Rectangle().stroke(.white.opacity(0.14), lineWidth: 0.75) }
        .accessibilityLabel("Map-frame pitch and roll")
    }

    private var attitudeText: String {
        guard let pitch, let roll else { return "--" }
        return String(format: "P%+.0f R%+.0f", degrees(pitch), degrees(roll))
    }
}

struct MapHeadingInstrumentView: View {
    let yaw: Float?
    let accentColor: Color

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = max(10, min(size.width, size.height) * 0.34)
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(.white.opacity(0.52)),
                    lineWidth: 0.8
                )
                guard let yaw else { return }
                let angle = CGFloat(yaw) - .pi / 2
                let tip = CGPoint(
                    x: center.x + cos(angle) * radius * 0.78,
                    y: center.y + sin(angle) * radius * 0.78
                )
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: tip)
                context.stroke(
                    needle,
                    with: .color(accentColor),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                    with: .color(.white)
                )
            }
            .overlay(alignment: .topLeading) {
                instrumentLabel("MAP HEADING", value: headingText)
            }
            .overlay(alignment: .top) {
                Text("N")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.56))
                    .padding(.top, 17)
            }
        }
        .background(.white.opacity(0.025))
        .overlay { Rectangle().stroke(.white.opacity(0.14), lineWidth: 0.75) }
        .accessibilityLabel("Heading in saved map coordinates")
    }

    private var headingText: String {
        guard let yaw else { return "--" }
        return String(format: "%+.0f DEG", degrees(yaw))
    }
}

private func instrumentLabel(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(title)
            .font(.system(size: 7, weight: .bold, design: .monospaced))
        Text(value)
            .font(.system(size: 6, weight: .medium, design: .monospaced))
    }
    .foregroundStyle(.white.opacity(0.66))
    .padding(5)
}

private func degrees(_ radians: Float) -> Float {
    radians * 180 / .pi
}
