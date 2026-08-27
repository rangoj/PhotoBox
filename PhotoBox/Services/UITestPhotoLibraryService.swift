#if DEBUG
actor UITestPhotoLibraryService: PhotoLibraryServing {
    private var authorization: PhotoAuthorization
    private let requestedAuthorization: PhotoAuthorization

    init(
        authorization: PhotoAuthorization,
        requestedAuthorization: PhotoAuthorization? = nil
    ) {
        self.authorization = authorization
        self.requestedAuthorization = requestedAuthorization ?? authorization
    }

    func authorizationStatus() -> PhotoAuthorization {
        authorization
    }

    func requestAuthorization() -> PhotoAuthorization {
        authorization = requestedAuthorization
        return authorization
    }

    func scanLibrary(screenshotAgeDays: Int) -> AsyncStream<LibraryScanSnapshot> {
        AsyncStream { continuation in
            var snapshot = LibraryScanSnapshot.idle
            snapshot.phase = .completed
            continuation.yield(snapshot)
            continuation.finish()
        }
    }
}
#endif
