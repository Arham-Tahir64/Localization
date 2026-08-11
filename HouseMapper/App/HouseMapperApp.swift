import SwiftUI

@main
struct HouseMapperApp: App {
    @StateObject private var mapLibrary = MapLibrary()
    @StateObject private var validationStore = ValidationStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(mapLibrary)
                .environmentObject(validationStore)
        }
    }
}
