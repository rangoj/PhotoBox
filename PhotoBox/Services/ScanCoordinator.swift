import Foundation

nonisolated enum ScanStartMode: Sendable {
    case resume
    case restart
}

actor ScanCoordinator {
    typealias CheckpointSink = @Sendable (ScanCheckpoint) async -> Void

    private let reader: any PhotoLibraryReading
    private let checkpointWriter: CheckpointWriter
    private var activeToken: UUID?
    private var activeTask: Task<Void, Never>?
    private var completedScanDescriptors: [PhotoAssetDescriptor]?
    private var partialScanDescriptors: [PhotoAssetDescriptor]?
    private var lastPublishedPartialCount = 0

    init(
        reader: any PhotoLibraryReading,
        checkpointSink: @escaping CheckpointSink
    ) {
        self.reader = reader
        self.checkpointWriter = CheckpointWriter(sink: checkpointSink)
    }

    func start(
        screenshotAgeDays: Int,
        mode: ScanStartMode,
        checkpoint: ScanCheckpoint?
    ) async -> AsyncStream<LibraryScanSnapshot> {
        activeTask?.cancel()
        completedScanDescriptors = nil
        partialScanDescriptors = nil
        lastPublishedPartialCount = 0

        let token = UUID()
        activeToken = token
        let (stream, continuation) = AsyncStream.makeStream(of: LibraryScanSnapshot.self)
        let isResume = mode == .resume && checkpoint != nil
        let scanID = isResume ? checkpoint!.id : UUID().uuidString
        let startingSnapshot = isResume ? checkpoint!.snapshot : .starting

        if !isResume {
            await checkpointWriter.persist(ScanCheckpoint(
                id: scanID,
                stage: .enumerating,
                processedAssetIDs: [],
                discoveredCount: 0,
                snapshot: startingSnapshot,
                updatedAt: .now
            ))
        }
        guard isActive(token) else {
            continuation.finish()
            return stream
        }
        let task = Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            await self.performScan(
                token: token,
                screenshotAgeDays: screenshotAgeDays,
                mode: mode,
                checkpoint: checkpoint,
                scanID: scanID,
                continuation: continuation
            )
        }
        activeTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func cancelCurrent() {
        activeTask?.cancel()
    }

    func takeCompletedDescriptors() -> [PhotoAssetDescriptor]? {
        defer { completedScanDescriptors = nil }
        return completedScanDescriptors
    }

    func takePartialDescriptors() -> [PhotoAssetDescriptor]? {
        defer { partialScanDescriptors = nil }
        return partialScanDescriptors
    }

    private func performScan(
        token: UUID,
        screenshotAgeDays: Int,
        mode: ScanStartMode,
        checkpoint: ScanCheckpoint?,
        scanID: String,
        continuation: AsyncStream<LibraryScanSnapshot>.Continuation
    ) async {
        let isResume = mode == .resume && checkpoint != nil
        var snapshot = isResume ? checkpoint!.snapshot : .starting
        let checkpointProcessedSet = Set(isResume ? checkpoint!.processedAssetIDs : [])
        var processedIDs: [String] = []
        var processedSet: Set<String> = []

        snapshot.discoveredCount = 0
        snapshot.processedCount = 0
        snapshot.localCount = 0
        snapshot.iCloudOnlyCount = 0
        snapshot.unavailableCount = 0
        snapshot.screenshotCount = 0
        snapshot.largeVideoCount = 0
        snapshot.errorMessage = nil
        snapshot.phase = .discovering
        continuation.yield(snapshot)

        let descriptorSource: PhotoLibraryDescriptorStream
        do {
            descriptorSource = try await reader.assetDescriptorStream(
                screenshotAgeDays: screenshotAgeDays
            )
        } catch {
            guard isActive(token), !Task.isCancelled else {
                await finishCancelledIfCurrent(
                    token: token,
                    scanID: scanID,
                    processedIDs: processedIDs,
                    snapshot: snapshot,
                    continuation: continuation
                )
                return
            }
            await finishFailedIfCurrent(
                token: token,
                scanID: scanID,
                snapshot: snapshot,
                error: error,
                continuation: continuation
            )
            return
        }
        guard isActive(token), !Task.isCancelled else {
            await finishCancelledIfCurrent(
                token: token,
                scanID: scanID,
                processedIDs: processedIDs,
                snapshot: snapshot,
                continuation: continuation
            )
            return
        }

        snapshot.discoveredCount = descriptorSource.discoveredCount
        snapshot.phase = .checkingLocalAvailability
        continuation.yield(snapshot)
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -screenshotAgeDays,
            to: .now
        ) ?? .distantPast

        var descriptors: [PhotoAssetDescriptor] = []
        descriptors.reserveCapacity(descriptorSource.discoveredCount)
        var lastCheckpointedCount = 0
        do {
            for try await descriptor in descriptorSource.stream {
                descriptors.append(descriptor)
                guard !processedSet.contains(descriptor.id) else { continue }
                processedSet.insert(descriptor.id)
                guard isActive(token), !Task.isCancelled else {
                    await finishCancelledIfCurrent(
                        token: token,
                        scanID: scanID,
                        processedIDs: processedIDs,
                        snapshot: snapshot,
                        continuation: continuation
                    )
                    return
                }

                switch descriptor.availability {
                case .local:
                    snapshot.localCount += 1
                    if descriptor.isScreenshot,
                       let creationDate = descriptor.creationDate,
                       creationDate < cutoff {
                        snapshot.screenshotCount += 1
                    }
                    if descriptor.mediaType == .video, descriptor.duration >= 60 {
                        snapshot.largeVideoCount += 1
                    }
                case .iCloudOnly:
                    snapshot.iCloudOnlyCount += 1
                case .unavailable:
                    snapshot.unavailableCount += 1
                }

                processedIDs.append(descriptor.id)
                snapshot.processedCount = processedIDs.count
                // Checkpointed assets still contribute to current-scope counts,
                // but skip downstream analysis work during resume.
                if checkpointProcessedSet.contains(descriptor.id) {
                    continue
                }
                let shouldFlush = processedIDs.count == 1
                    || processedIDs.count - lastCheckpointedCount >= 50
                if shouldFlush {
                    partialScanDescriptors = descriptors
                    lastPublishedPartialCount = descriptors.count
                    continuation.yield(snapshot)
                    await checkpointWriter.persist(ScanCheckpoint(
                        id: scanID,
                        stage: .checkingAvailability,
                        processedAssetIDs: processedIDs,
                        discoveredCount: descriptorSource.discoveredCount,
                        snapshot: snapshot,
                        updatedAt: .now
                    ))
                    lastCheckpointedCount = processedIDs.count
                }
            }
        } catch {
            guard isActive(token), !Task.isCancelled else {
                await finishCancelledIfCurrent(
                    token: token,
                    scanID: scanID,
                    processedIDs: processedIDs,
                    snapshot: snapshot,
                    continuation: continuation
                )
                return
            }
            await finishFailedIfCurrent(
                token: token,
                scanID: scanID,
                snapshot: snapshot,
                error: error,
                continuation: continuation
            )
            return
        }

        guard isActive(token), !Task.isCancelled else {
            await finishCancelledIfCurrent(
                token: token,
                scanID: scanID,
                processedIDs: processedIDs,
                snapshot: snapshot,
                continuation: continuation
            )
            return
        }

        // PhotoKit can change between fetch and descriptor emission. Treat the
        // successfully emitted set as the completed scope so progress reaches
        // a truthful 100% instead of retaining a stale fetch count.
        snapshot.discoveredCount = descriptors.count
        snapshot.phase = .completed
        if lastPublishedPartialCount != descriptors.count {
            partialScanDescriptors = descriptors
        }
        continuation.yield(snapshot)
        await checkpointWriter.persist(ScanCheckpoint(
            id: scanID,
            stage: .completed,
            processedAssetIDs: processedIDs,
            discoveredCount: descriptorSource.discoveredCount,
            snapshot: snapshot,
            updatedAt: .now
        ))
        completedScanDescriptors = descriptors
        continuation.finish()
    }

    private func finishCancelledIfCurrent(
        token: UUID,
        scanID: String,
        processedIDs: [String],
        snapshot: LibraryScanSnapshot,
        continuation: AsyncStream<LibraryScanSnapshot>.Continuation
    ) async {
        guard isActive(token) else {
            continuation.finish()
            return
        }
        var cancelled = snapshot
        cancelled.phase = .cancelled
        continuation.yield(cancelled)
        await checkpointWriter.persist(ScanCheckpoint(
            id: scanID,
            stage: .cancelled,
            processedAssetIDs: processedIDs,
            discoveredCount: snapshot.discoveredCount,
            snapshot: cancelled,
            updatedAt: .now
        ))
        continuation.finish()
    }

    private func finishFailedIfCurrent(
        token: UUID,
        scanID: String,
        snapshot: LibraryScanSnapshot,
        error: Error,
        continuation: AsyncStream<LibraryScanSnapshot>.Continuation
    ) async {
        guard isActive(token) else {
            continuation.finish()
            return
        }
        var failed = snapshot
        failed.phase = .failed
        let detail: String
        if let error = error as? PhotoLibraryReadError {
            detail = error.message
        } else {
            detail = "读取照片时发生错误"
        }
        failed.errorMessage = "无法读取当前可访问范围：\(detail)"
        continuation.yield(failed)
        await checkpointWriter.persist(ScanCheckpoint(
            id: scanID,
            stage: .failed,
            processedAssetIDs: [],
            discoveredCount: failed.discoveredCount,
            snapshot: failed,
            updatedAt: .now
        ))
        continuation.finish()
    }

    private func isActive(_ token: UUID) -> Bool {
        activeToken == token
    }
}

private actor CheckpointWriter {
    private let sink: ScanCoordinator.CheckpointSink
    private var tail: Task<Void, Never>?

    init(sink: @escaping ScanCoordinator.CheckpointSink) {
        self.sink = sink
    }

    func persist(_ checkpoint: ScanCheckpoint) async {
        let previous = tail
        let task = Task { [sink] in
            if let previous {
                await previous.value
            }
            await sink(checkpoint)
        }
        tail = task
        await task.value
    }
}
