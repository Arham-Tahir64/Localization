import SwiftUI

struct MapOverviewView: View {
    let mapPoints: [SIMD2<Float>]
    let trail: [SIMD2<Float>]
    let pose: CameraPose?

    var body: some View {
        Canvas { context, size in
            let current = pose.map { SIMD2($0.position.x, $0.position.z) }
            let allPoints = mapPoints + trail + (current.map { [$0] } ?? [])
            guard !allPoints.isEmpty else {
                context.draw(
                    Text("Map appears as you move")
                        .font(.caption)
                        .foregroundStyle(.secondary),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
                return
            }

            let xValues = allPoints.map(\.x)
            let zValues = allPoints.map(\.y)
            let minX = (xValues.min() ?? -1) - 0.5
            let maxX = (xValues.max() ?? 1) + 0.5
            let minZ = (zValues.min() ?? -1) - 0.5
            let maxZ = (zValues.max() ?? 1) + 0.5
            let spanX = max(maxX - minX, 1)
            let spanZ = max(maxZ - minZ, 1)
            let scale = min((size.width - 20) / CGFloat(spanX), (size.height - 20) / CGFloat(spanZ))

            func project(_ point: SIMD2<Float>) -> CGPoint {
                CGPoint(
                    x: 10 + CGFloat(point.x - minX) * scale,
                    y: size.height - 10 - CGFloat(point.y - minZ) * scale
                )
            }

            for point in mapPoints {
                let center = project(point)
                let rect = CGRect(x: center.x - 1.2, y: center.y - 1.2, width: 2.4, height: 2.4)
                context.fill(Path(ellipseIn: rect), with: .color(.cyan.opacity(0.45)))
            }

            if trail.count > 1 {
                var path = Path()
                path.move(to: project(trail[0]))
                for point in trail.dropFirst() {
                    path.addLine(to: project(point))
                }
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
