import AudioToolbox
import Accelerate
import os

enum RecorderError: LocalizedError {
    case noInput(OSStatus)
    case deviceUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInput: String(localized: "No microphone is available")
        case .deviceUnavailable: String(localized: "The microphone could not be opened")
        }
    }
}

/// Captures the microphone as 16 kHz mono float samples, with a live level for the HUD.
///
/// An input-only Audio Queue: unlike AVAudioEngine it is not tied to the output device, so
/// Bluetooth headphones switching profiles or a sound playing never interrupt a recording, and
/// the queue delivers 16 kHz mono directly in 20 ms buffers. `start`/`stop` are called from the
/// main actor; callbacks run on a private serial queue and only touch lock-protected state.
final class AudioRecorder: @unchecked Sendable {
    let meter: LevelMeter

    private static let sampleRate = 16_000.0
    private static let framesPerBuffer: UInt32 = 320  // 20 ms
    private static let bufferCount = 6

    private let callbacks = DispatchQueue(label: "NoType.audio", qos: .userInteractive)
    private let samples = OSAllocatedUnfairLock<[Float]>(initialState: [])
    private let capturing = OSAllocatedUnfairLock(initialState: false)
    private var queue: AudioQueueRef?
    private(set) var isRunning = false

    /// Called on the main actor when the input device disappears mid-recording.
    var onInterruption: (@MainActor () -> Void)?

    init(meter: LevelMeter) {
        self.meter = meter
    }

    func start(deviceUID: String?) throws {
        samples.withLock {
            $0.removeAll(keepingCapacity: true)
            $0.reserveCapacity(Int(Self.sampleRate) * 120)
        }
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var created: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&created, &format, 0, callbacks) {
            [weak self] queue, buffer, _, _, _ in
            guard let self, self.capturing.withLock({ $0 }) else { return }
            self.consume(buffer)
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
        guard status == noErr, let queue = created else { throw RecorderError.noInput(status) }

        let context = Unmanaged.passUnretained(self).toOpaque()
        do {
            // A chosen microphone that has been unplugged falls back to the system default.
            if let deviceUID, AudioDevices.inputDevices().contains(where: { $0.uid == deviceUID }) {
                let uid = deviceUID as CFString
                try withExtendedLifetime(uid) {
                    var reference = Unmanaged.passUnretained(uid)
                    try check(AudioQueueSetProperty(
                        queue, kAudioQueueProperty_CurrentDevice, &reference,
                        UInt32(MemoryLayout<Unmanaged<CFString>>.size)))
                }
            }
            for _ in 0 ..< Self.bufferCount {
                var buffer: AudioQueueBufferRef?
                try check(AudioQueueAllocateBuffer(queue, Self.framesPerBuffer * 4, &buffer))
                if let buffer { try check(AudioQueueEnqueueBuffer(queue, buffer, 0, nil)) }
            }
            try check(AudioQueueAddPropertyListener(queue, kAudioQueueProperty_IsRunning, Self.runningChanged, context))
            capturing.withLock { $0 = true }
            try check(AudioQueueStart(queue, nil))
        } catch {
            capturing.withLock { $0 = false }
            AudioQueueDispose(queue, true)
            throw error
        }
        self.queue = queue
        isRunning = true
    }

    /// Stops capture and returns everything recorded since `start`.
    func stop() -> [Float] {
        if let queue {
            capturing.withLock { $0 = false }
            AudioQueueRemovePropertyListener(
                queue, kAudioQueueProperty_IsRunning, Self.runningChanged, Unmanaged.passUnretained(self).toOpaque())
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            self.queue = nil
            callbacks.sync {}  // let a callback already in flight finish appending
        }
        isRunning = false
        meter.update(0)
        return samples.withLock { $0 }
    }

    var sampleCount: Int { samples.withLock { $0.count } }

    func samples(from offset: Int) -> [Float] {
        samples.withLock { offset < $0.count ? Array($0[offset...]) : [] }
    }

    private func consume(_ buffer: AudioQueueBufferRef) {
        let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let data = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        let chunk = UnsafeBufferPointer(start: data, count: count)
        samples.withLockUnchecked { $0.append(contentsOf: chunk) }

        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(count))
        meter.update(LevelMeter.normalized(rms: rms))
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw RecorderError.deviceUnavailable(status) }
    }

    /// The queue stops on its own when its device goes away (unplugged, switched off).
    private static let runningChanged: AudioQueuePropertyListenerProc = { context, queue, _ in
        guard let context else { return }
        let recorder = Unmanaged<AudioRecorder>.fromOpaque(context).takeUnretainedValue()
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size)
        guard running == 0, recorder.capturing.withLock({ $0 }) else { return }
        Log.audio.notice("The input device stopped while recording")
        DispatchQueue.main.async {
            MainActor.assumeIsolated { recorder.onInterruption?() }
        }
    }
}
