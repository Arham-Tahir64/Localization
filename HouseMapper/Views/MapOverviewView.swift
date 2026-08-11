import SwiftUI

struct MapOverviewView: View {
    let mapPoints: [SIMD2<Float>]
    let trail: [SIMD2<Float>]
    let pose: CameraPose?

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

            mapPoints.forEach(include)
            for index in Swift.stride(from: 0, to: trail.count, by: trailStep) {
                include(trail[index])
            }
            if let current { include(current) }

            guard minX.isFinite else {
                context.draw(
                    Text("Map appears as you move")
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

            var mapPointPath = Path()
            for point in mapPoints {
                let center = project(point)
                let rect = CGRect(x: center.x - 1.2, y: center.y - 1.2, width: 2.4, height: 2.4)
                mapPointPath.addEllipse(in: rect)
            }
            context.fill(mapPointPath, with: .color(.cyan.opacity(0.45)))

            if trail.count > 1 {
                var path = Path()
                path.move(to: project(trail[0]))
                for index in Swift.stride(from: trailStep, to: trail.count, by: trailStep) {
                    path.addLine(to: project(trail[index]))
                }
                if let last = trail.last { path.addLine(to: project(last)) }
                context.stroke(path, with: .color(.yellow), lineWidth: 2)
            }

            if let pose, let current {
                let center = project(current)
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                    with: .color(.orange)
                )

                let yaw = pose.eulerAngles.y
                let forward = SIMD2<Float>(-sin(yaw), -cos(yaw))
                let tipWorld = current + forward * 0.45
                var heading = Path()
                heading.move(to: center)
                heading.addLine(to: project(tipWorld))
                context.stroke(heading, with: .color(.orange), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .accessibilityLabel("Top-down map overview")
    }
}
