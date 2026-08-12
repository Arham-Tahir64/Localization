import SwiftUI

struct MapOverviewView: View {
    let map: SpatialMapRenderSnapshot
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
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .accessibilityLabel("Top-down map overview")
    }
}
