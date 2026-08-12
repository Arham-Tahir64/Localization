import SwiftUI

struct SpatialFeatureOverlay: View {
    let snapshot: FeaturePointSnapshot

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            var scanningPath = Path()
            var seekingPath = Path()
            var supportPath = Path()
            var matchGlowPath = Path()
            var matchCorePath = Path()

            for point in snapshot.points {
                let center = CGPoint(
                    x: CGFloat(point.position.x) * size.width,
                    y: CGFloat(point.position.y) * size.height
                )
                switch point.role {
                case .scanning:
                    scanningPath.addEllipse(in: pointRect(center: center, diameter: 3.2))
                case .seeking:
                    seekingPath.addEllipse(in: pointRect(center: center, diameter: 2.6))
                case .localizedSupport:
                    supportPath.addEllipse(in: pointRect(center: center, diameter: 3.4))
                case .mapIdentityMatch:
                    matchGlowPath.addEllipse(in: pointRect(center: center, diameter: 9))
                    matchCorePath.addEllipse(in: pointRect(center: center, diameter: 4.5))
                case .serverVerifiedInlier:
                    matchGlowPath.addEllipse(in: pointRect(center: center, diameter: 11))
                    matchCorePath.addEllipse(in: pointRect(center: center, diameter: 5.5))
                }
            }

            context.fill(scanningPath, with: .color(.cyan.opacity(0.76)))
            context.fill(seekingPath, with: .color(.white.opacity(0.54)))
            context.fill(supportPath, with: .color(.cyan.opacity(0.72)))
            context.fill(matchGlowPath, with: .color(.green.opacity(0.15)))
            context.fill(matchCorePath, with: .color(.green))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func pointRect(center: CGPoint, diameter: CGFloat) -> CGRect {
        CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
    }
}

struct SpatialScanReticle: View {
    let color: Color
    let isActive: Bool

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 1)

            Circle()
                .trim(from: 0.06, to: 0.34)
                .stroke(
                    AngularGradient(
                        colors: [.clear, color.opacity(0.35), color, .clear],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))

            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .shadow(color: color.opacity(0.8), radius: 5)

            ReticleCorners()
                .stroke(color.opacity(0.72), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .padding(8)
        }
        .frame(width: 74, height: 74)
        .opacity(isActive ? 1 : 0)
        .scaleEffect(isActive ? 1 : 0.82)
        .animation(.easeOut(duration: 0.3), value: isActive)
        .onAppear {
            guard isActive else { return }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            rotation = 0
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

private struct ReticleCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let segment = min(rect.width, rect.height) * 0.20
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + segment))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + segment, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - segment, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + segment))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - segment))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - segment, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + segment, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - segment))
        return path
    }
}

struct SpatialStatusCapsule: View {
    let title: String
    let detail: String
    let featureCount: Int
    let visibleFeatureCount: Int
    let sourceFeatureCount: Int
    let matchCount: Int
    let serverInlierCount: Int
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.caption.bold())
                    .tracking(0.8)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(featureCount.formatted())
                    .font(.caption.monospacedDigit().bold())
                Text(
                    serverInlierCount > 0
                        ? "\(serverInlierCount) PnP inliers"
                        : matchCount > 0
                        ? "\(matchCount) restored IDs"
                        : "\(visibleFeatureCount)/\(sourceFeatureCount) visible"
                )
                    .font(.caption2)
                    .foregroundStyle(
                        serverInlierCount > 0 || matchCount > 0
                            ? color
                            : .white.opacity(0.52)
                    )
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 42)
        .background(.black.opacity(0.92))
        .overlay {
            Rectangle().stroke(.white.opacity(0.14), lineWidth: 0.75)
        }
        .animation(.easeInOut(duration: 0.25), value: title)
        .animation(.easeInOut(duration: 0.25), value: color)
    }
}

struct SpatialGuidancePrompt: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.subheadline.bold())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.56), in: Capsule())
        .overlay {
            Capsule().stroke(color.opacity(0.28), lineWidth: 1)
        }
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: title)
    }
}

struct PoseInstrumentView: View {
    let pose: CameraPose?
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MAP POSE")
                    .font(.caption2.bold())
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.56))
                Spacer()
                Circle()
                    .fill(pose == nil ? Color.orange : accentColor)
                    .frame(width: 6, height: 6)
            }

            if let pose {
                HStack(spacing: 10) {
                    HeadingDial(yaw: pose.eulerAngles.y, accentColor: accentColor)
                        .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(positionText(pose))
                        Text(angleText(pose))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .font(.caption2.monospacedDigit())
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pose withheld")
                        .font(.caption.bold())
                    Text("Waiting for a verified map alignment")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.58))
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func positionText(_ pose: CameraPose) -> String {
        let p = pose.position
        return String(format: "X %+.1f\nY %+.1f\nZ %+.1f m", p.x, p.y, p.z)
    }

    private func angleText(_ pose: CameraPose) -> String {
        let scale = Float(180 / Double.pi)
        return String(
            format: "P %+.0f°  R %+.0f°",
            pose.eulerAngles.x * scale,
            pose.eulerAngles.z * scale
        )
    }
}

private struct HeadingDial: View {
    let yaw: Float
    let accentColor: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 3
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(.white.opacity(0.34)),
                lineWidth: 1
            )

            let angle = CGFloat(yaw) - .pi / 2
            let tip = CGPoint(
                x: center.x + cos(angle) * radius * 0.72,
                y: center.y + sin(angle) * radius * 0.72
            )
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: tip)
            context.stroke(
                needle,
                with: .color(accentColor),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                with: .color(.white)
            )
        }
        .overlay(alignment: .top) {
            Text("N")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 4)
        }
    }
}

struct LocalizationSuccessPulse: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(.green.opacity(expanded ? 0 : 0.9), lineWidth: 2)
            .frame(width: 86, height: 86)
            .scaleEffect(expanded ? 2.2 : 0.5)
            .onAppear {
                withAnimation(.easeOut(duration: 1.1)) {
                    expanded = true
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
