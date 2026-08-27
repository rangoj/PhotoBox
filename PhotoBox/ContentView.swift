//
//  ContentView.swift
//  PhotoBox
//
//  Created by rango on 2026/8/27.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-authorized") {
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(authorization: .authorized)))
        } else if arguments.contains("--ui-testing-limited") {
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(authorization: .limited)))
        } else if arguments.contains("--ui-testing-denied") {
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(authorization: .denied)))
        } else if arguments.contains("--ui-testing-restricted") {
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(authorization: .restricted)))
        } else if arguments.contains("--ui-testing-not-determined") {
            _model = State(initialValue: AppModel(library: UITestPhotoLibraryService(
                authorization: .notDetermined,
                requestedAuthorization: .authorized
            )))
        } else {
            _model = State(initialValue: AppModel())
        }
        #else
        _model = State(initialValue: AppModel())
        #endif
    }

    var body: some View {
        Group {
            if !model.hasLoadedAuthorization {
                ProgressView()
            } else {
                switch model.authorization {
                case .notDetermined:
                    PermissionEducationView {
                        Task { await model.requestPhotoAccess() }
                    }
                case .authorized, .limited:
                    MainTabView(model: model)
                case .denied, .restricted:
                    PermissionRecoveryView(isRestricted: model.authorization == .restricted)
                }
            }
        }
        .task {
            await model.refreshAuthorization()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refreshAuthorization(forceScan: true) }
        }
    }
}

#Preview {
    ContentView()
}
