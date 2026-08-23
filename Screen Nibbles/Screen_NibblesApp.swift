//
//  Screen_NibblesApp.swift
//  Screen Nibbles
//

import SwiftUI
import SwiftData

@main
struct Screen_NibblesApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Video.self, Stitch.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
