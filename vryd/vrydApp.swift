//
//  vrydApp.swift
//  vryd
//
//  Created by Stratton Keele on 2/11/26.
//

import SwiftUI

@main
struct vrydApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(backend: BackendFactory.makeBackend())
        }
    }
}
