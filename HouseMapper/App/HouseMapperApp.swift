import SwiftUI

@main
struct HouseMapperApp: App {
    @StateObject private var mapLibrary = MapLibrary()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(mapLibrary)
        }
    }
}
