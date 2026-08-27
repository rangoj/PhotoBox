import Photos

nonisolated enum PhotoAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted

    nonisolated init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .limited:
            self = .limited
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .denied
        }
    }

    nonisolated var canReadLibrary: Bool {
        self == .authorized || self == .limited
    }
}
