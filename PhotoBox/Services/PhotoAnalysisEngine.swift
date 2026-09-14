import CoreImage
import Foundation
import ImageIO
import Vision

nonisolated struct PhotoGroupRecommendation: Equatable, Sendable {
    let groupID: String
    let recommendedKeepID: String?
    let reasons: [RecommendationReason]
    let confidence: Double
}

nonisolated protocol PhotoAnalysisEngine: Sendable {
    func recommendation(for group: PhotoCandidateGroup) -> PhotoGroupRecommendation
}

nonisolated struct LocalPhotoAnalysisEngine: PhotoAnalysisEngine {
    let minimumWinningMargin: Double

    init(minimumWinningMargin: Double = 0.12) {
        self.minimumWinningMargin = minimumWinningMargin
    }

    func recommendation(for group: PhotoCandidateGroup) -> PhotoGroupRecommendation {
        // A missing or iCloud-only candidate makes the comparison incomplete;
        // do not turn the remaining visible item into an automatic recommendation.
        guard group.candidates.count > 1,
              group.candidates.allSatisfy({ $0.asset.availability == .local }) else {
            return noRecommendation(for: group.id)
        }
        let ranked = group.candidates.sorted { first, second in
            if first.isProtectedByDefault != second.isProtectedByDefault {
                return first.isProtectedByDefault
            }
            if first.quality.score != second.quality.score {
                return first.quality.score > second.quality.score
            }
            let firstPixels = first.asset.pixelWidth * first.asset.pixelHeight
            let secondPixels = second.asset.pixelWidth * second.asset.pixelHeight
            if firstPixels != secondPixels { return firstPixels > secondPixels }
            return first.id < second.id
        }
        let winner = ranked[0]
        let runnerUp = ranked[1]

        if winner.isProtectedByDefault != runnerUp.isProtectedByDefault {
            let reasons = protectionReasons(for: winner)
            return PhotoGroupRecommendation(
                groupID: group.id,
                recommendedKeepID: winner.id,
                reasons: reasons,
                confidence: 1
            )
        }

        let margin = winner.quality.score - runnerUp.quality.score
        guard margin >= minimumWinningMargin else { return noRecommendation(for: group.id) }
        let reasons = qualityReasons(winner: winner, runnerUp: runnerUp)
        guard !reasons.isEmpty else { return noRecommendation(for: group.id) }
        return PhotoGroupRecommendation(
            groupID: group.id,
            recommendedKeepID: winner.id,
            reasons: reasons,
            confidence: min(1, margin / max(minimumWinningMargin, 0.001))
        )
    }

    func similarityDistance(
        between first: PhotoThumbnail,
        and second: PhotoThumbnail
    ) throws -> Float {
        let firstPrint = try featurePrint(for: first.data)
        let secondPrint = try featurePrint(for: second.data)
        var distance: Float = 0
        try firstPrint.computeDistance(&distance, to: secondPrint)
        return distance
    }

    func qualitySignals(for thumbnail: PhotoThumbnail) -> PhotoQualitySignals? {
        guard let source = CGImageSourceCreateWithData(thumbnail.data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let sourceImage = CIImage(cgImage: cgImage)
        let width = 64
        let height = 64
        let scale = min(
            Double(width) / sourceImage.extent.width,
            Double(height) / sourceImage.extent.height
        )
        let image = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            image,
            toBitmap: &pixels,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        var luminance = [Double](repeating: 0, count: width * height)
        for index in luminance.indices {
            let offset = index * 4
            luminance[index] = (
                0.2126 * Double(pixels[offset])
                    + 0.7152 * Double(pixels[offset + 1])
                    + 0.0722 * Double(pixels[offset + 2])
            ) / 255
        }
        let mean = luminance.reduce(0, +) / Double(luminance.count)
        let exposure = max(0, 1 - abs(mean - 0.5) * 2)
        let completeness = Double(luminance.count { $0 > 0.05 && $0 < 0.95 })
            / Double(luminance.count)
        var edgeTotal = 0.0
        var edgeCount = 0
        for y in 1..<height {
            for x in 1..<width {
                let index = y * width + x
                edgeTotal += abs(luminance[index] - luminance[index - 1])
                edgeTotal += abs(luminance[index] - luminance[index - width])
                edgeCount += 2
            }
        }
        let sharpness = min(1, edgeTotal / Double(max(edgeCount, 1)) * 5)
        return PhotoQualitySignals(
            sharpness: sharpness,
            exposure: exposure,
            completeness: completeness
        )
    }

    private func featurePrint(for data: Data) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(data: data).perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw PhotoAnalysisError.missingFeaturePrint
        }
        return observation
    }

    private func protectionReasons(for candidate: PhotoCandidate) -> [RecommendationReason] {
        if candidate.manualProtection { return [.protected] }
        if candidate.asset.isFavorite { return [.favorite] }
        if candidate.asset.isEdited { return [.edited] }
        return []
    }

    private func qualityReasons(
        winner: PhotoCandidate,
        runnerUp: PhotoCandidate
    ) -> [RecommendationReason] {
        var reasons: [RecommendationReason] = []
        if winner.quality.sharpness > runnerUp.quality.sharpness + 0.05 { reasons.append(.sharper) }
        if winner.quality.exposure > runnerUp.quality.exposure + 0.05 { reasons.append(.balancedExposure) }
        if winner.quality.completeness > runnerUp.quality.completeness + 0.05 {
            reasons.append(.completeSubject)
        }
        if winner.asset.pixelWidth * winner.asset.pixelHeight
            > runnerUp.asset.pixelWidth * runnerUp.asset.pixelHeight {
            reasons.append(.higherResolution)
        }
        return reasons
    }

    private func noRecommendation(for groupID: String) -> PhotoGroupRecommendation {
        PhotoGroupRecommendation(
            groupID: groupID,
            recommendedKeepID: nil,
            reasons: [],
            confidence: 0
        )
    }
}

nonisolated enum PhotoAnalysisError: Error {
    case missingFeaturePrint
}
