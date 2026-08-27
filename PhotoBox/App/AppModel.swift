import Observation
import Photos

@MainActor
@Observable
final class AppModel {
    private let library: any PhotoLibraryServing

    @ObservationIgnored
    private var scanTask: Task<Void, Never>?

    var authorization: PhotoAuthorization = .notDetermined
    var hasLoadedAuthorization = false
    var scan = LibraryScanSnapshot.idle
    var screenshotAgeDays = 30

    init(library: (any PhotoLibraryServing)? = nil) {
        self.library = library ?? LivePhotoLibraryService()
    }

    deinit {
        scanTask?.cancel()
    }

    func refreshAuthorization(forceScan: Bool = false) async {
        let latest = await library.authorizationStatus()
        let changed = latest != authorization
        authorization = latest
        hasLoadedAuthorization = true

        if latest.canReadLibrary, forceScan || changed || scan.phase == .idle {
            startScan()
        } else if !latest.canReadLibrary {
            scanTask?.cancel()
            scan = .idle
        }
    }

    func requestPhotoAccess() async {
        authorization = await library.requestAuthorization()
        hasLoadedAuthorization = true
        if authorization.canReadLibrary {
            startScan()
        }
    }

    func rescan() {
        guard authorization.canReadLibrary else { return }
        startScan()
    }

    func updateScreenshotAge(_ days: Int) {
        guard screenshotAgeDays != days else { return }
        screenshotAgeDays = days
        rescan()
    }

    private func startScan() {
        scanTask?.cancel()
        scan = .starting
        let ageDays = screenshotAgeDays
        let library = library

        scanTask = Task { [weak self] in
            let updates = await library.scanLibrary(screenshotAgeDays: ageDays)
            for await update in updates {
                guard !Task.isCancelled else { return }
                self?.scan = update
            }
        }
    }
}
