import ARKit
import SwiftUI

struct ARSceneView: UIViewRepresentable {
    @ObservedObject var controller: ARSessionController

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        Task { @MainActor [weak controller, weak view] in
            guard let controller, let view else { return }
            controller.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Void) {
        uiView.session.pause()
        uiView.delegate = nil
        uiView.session.delegate = nil
    }
}
