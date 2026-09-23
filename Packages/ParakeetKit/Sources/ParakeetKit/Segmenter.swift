import Foundation

/// Cuts long audio into segments of at most 30 s in the middle of pauses, where the pauses come
/// from the checkpoint's VAD head (the model card describes this long-form segmentation).
public enum Segmenter {
    static let sampleRate = Double(Features.sampleRate)
    public static let segmentSeconds = 30.0
    /// Speech is marked one block at a time, so long files never need one huge pass.
    static let blockSeconds = 120.0
    static let minPauseSeconds = 0.2
    static let minSegmentSeconds = 1.0
    static let frameSeconds = 0.08
    static let speechThreshold: Float = 0.5
    static let minSpeechSeconds = 0.1
    static let minGapSeconds = 0.1
    static let pauseEpsilon = 1e-6

    /// Once this much audio is pending, a live recording commits a segment at the next good pause.
    static let progressiveSeconds = 20.0

    public struct Span: Equatable, Sendable {
        public var start: Double
        public var end: Double
        var middle: Double { (start + end) / 2 }
    }

    /// Runs of frames the head calls speech; gaps under 0.1 s are bridged, runs under 0.1 s dropped.
    static func speechRegions(_ probabilities: [Float], duration: Double) -> [Span] {
        var regions: [Span] = []
        var runStart: Int?
        for index in 0 ... probabilities.count {
            let speaking = index < probabilities.count && probabilities[index] >= speechThreshold
            if speaking, runStart == nil {
                runStart = index
            } else if !speaking, let start = runStart {
                let span = Span(start: Double(start) * frameSeconds, end: Double(index) * frameSeconds)
                if let last = regions.last, span.start - last.end < minGapSeconds {
                    regions[regions.count - 1].end = span.end
                } else {
                    regions.append(span)
                }
                runStart = nil
            }
        }
        return regions
            .filter { $0.end - $0.start >= minSpeechSeconds }
            .map { Span(start: $0.start, end: min($0.end, duration)) }
    }

    /// Gaps of at least 0.2 s between (and around) the speech regions.
    static func pauses(_ speech: [Span], duration: Double) -> [Span] {
        let least = minPauseSeconds - pauseEpsilon
        var result: [Span] = []
        var previous = 0.0
        for region in speech.sorted(by: { $0.start < $1.start }) {
            if region.start - previous >= least { result.append(Span(start: previous, end: region.start)) }
            previous = max(previous, region.end)
        }
        if duration - previous >= least { result.append(Span(start: previous, end: duration)) }
        return result
    }

    /// The middle of the last pause inside (1 s, 30 s), else of any pause whose middle lands
    /// there, else the 30 s cap.
    static func nextCut(_ pauses: [Span]) -> Double {
        var inside = pauses.filter { $0.start >= minSegmentSeconds && $0.end <= segmentSeconds }
        if inside.isEmpty {
            inside = pauses.filter { (minSegmentSeconds ... segmentSeconds).contains($0.middle) }
        }
        return inside.last?.middle ?? segmentSeconds
    }

    /// Contiguous pieces of a finished recording of `count` samples, each at most 30 s and cut in
    /// a pause; pieces with no speech in them are left out.
    static func segments(count: Int, speech: [Span]) -> [Range<Int>] {
        let cap = Int(segmentSeconds * sampleRate)
        guard count > cap else { return [0 ..< count] }
        var ranges: [Range<Int>] = []
        var regions = speech
        var start = 0
        var cuts = 0
        while count - start > cap {
            let cut = nextCut(pauses(regions, duration: Double(count - start) / sampleRate))
            let index = Int((cut * sampleRate).rounded())
            let seconds = Double(index) / sampleRate
            if hasSpeech(regions, before: seconds) { ranges.append(start ..< start + index) }
            start += index
            cuts += 1
            regions = regions.filter { $0.end > seconds }.map { Span(start: max($0.start - seconds, 0), end: $0.end - seconds) }
        }
        let remainder = Double(count - start) / sampleRate
        if !(cuts > 0 && (count - start < Features.minimumSamples || !hasSpeech(regions, before: remainder))) {
            ranges.append(start ..< count)
        }
        return ranges
    }

    /// For a recording in progress: an offset into the pending audio to commit up to, or `nil`
    /// to wait for more. Prefers a real pause (0.3 s or more, possibly still going on) at least
    /// 5 s in; at 30 s it falls back to the regular cut.
    static func progressiveCut(count: Int, speech: [Span]) -> Int? {
        let duration = Double(count) / sampleRate
        guard duration >= progressiveSeconds else { return nil }
        let pauses = pauses(speech, duration: duration)
        if let pause = pauses.last(where: { $0.start >= minSegmentSeconds && $0.end - $0.start >= 0.3 && $0.middle >= 5 }) {
            return Int(pause.middle * sampleRate)
        }
        guard duration >= segmentSeconds else { return nil }
        return Int((nextCut(pauses) * sampleRate).rounded())
    }

    private static func hasSpeech(_ regions: [Span], before seconds: Double) -> Bool {
        regions.contains { $0.end > 0 && $0.start < seconds }
    }
}
