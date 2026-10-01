//
//  AudioRenderer.swift
//  Spotty
//
//  Bridges librespot PCM output to AVSampleBufferAudioRenderer for AirPlay-compatible playback.
//  Audio data flows: Rust FFI callback -> ring buffer -> AVSampleBufferAudioRenderer -> AirPlay/speakers
//

import AVFoundation
import SpottyDomain
import CoreMedia
import OSLog
import Synchronization

nonisolated enum AudioRendererError: LocalizedError, Sendable {
    case formatDescription(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .formatDescription(status):
            "Spotty could not configure the system audio output (\(status))."
        }
    }
}

/// Audio renderer that bridges librespot's push model (Sink::write) to
/// AVSampleBufferAudioRenderer's receiver, with a bounded presentation-time pump.
///
/// Thread safety: `writeAudioData` is called from librespot's Rust player thread.
/// `feedRenderer` runs on a dedicated serial dispatch queue.
/// A ring buffer with lock-based synchronization bridges the two.
///
/// The write path may park briefly when the ring is full, but it cannot wait for space
/// that only `stop` / `flush` / route recreation can create. Those controls also run on
/// the player thread, so a full buffer uses one 500 ms backpressure wait and then drops.
///
final nonisolated class AudioRenderer: @unchecked Sendable {
    // MARK: - Constants

    private static let sampleRate: Float64 = 44100
    private static let channelCount = UInt32(StereoPCMBuffer.channels)
    private static let bytesPerSample = MemoryLayout<Float>.size  // 4

    /// Two seconds of complete stereo frames; storage never contains a partial channel pair.
    private static let ringBufferFrameCapacity = 88_200

    /// Maximum chunk size passed to Core Media.
    private static let feedChunkFrames = 1024

    // MARK: - AVFoundation Objects (recreated on output device change)

    private var renderer = AVSampleBufferAudioRenderer()
    private var synchronizer = AVSampleBufferRenderSynchronizer()
    /// Non-Sendable receiver: all live access stays on renderQueue.
    // Mutex's `inout sending` storage also permits exclusive ownership transfer on retirement.
    private let receiver = Mutex<AVSampleBufferAudioRenderer.Receiver?>(nil)

    /// Output gain (0...1) applied at the renderer. librespot's soft mixer is
    /// bypassed (NoOpVolume), so this is where playback volume is actually applied —
    /// at the output, which takes effect immediately instead of after the buffered
    /// PCM drains. Accessed only on `renderQueue` so it stays serialized with
    /// feeding and pipeline recreation.
    private var outputVolume: Float = 1.0

    // MARK: - Ring Buffer

    private let ringBuffer = StereoPCMBuffer(capacityFrames: ringBufferFrameCapacity)
    private let bufferLock = NSLock()

    /// Wake-up for a writer parked on a full buffer. Signal only while a wait is armed.
    private let writerSpace = PCMWriteSpace()
    private var outputControl = AudioOutputControlEpoch()

    // MARK: - Write Throttle (provides real-time pacing)

    /// Wall-clock time (monotonic) when writing started. Must be accessed with bufferLock held.
    private var writeStartTime: TimeInterval = 0

    /// Total f32 samples written since start. Must be accessed with bufferLock held.
    private var totalSamplesWritten: Int64 = 0

    /// Maximum seconds the writer can be ahead of real-time before sleeping.
    /// This replaces the backpressure that CoreAudio callbacks provided in the old rodio/cpal path.
    private static let maxBufferAheadSeconds: Double = 2.0

    // MARK: - State

    private let renderQueue = DispatchQueue(label: "dev.spotty.app.audio-renderer", qos: .userInteractive)
    private var pump = AudioRendererPump()
    private var pendingFeed: DispatchWorkItem?
    private var isRequestingData = false
    private var underrunCount: UInt64 = 0
    private var droppedSampleCount: UInt64 = 0
    private var throttleSeconds: TimeInterval = 0

    private var renderingEventTask: Task<Void, Never>?

    // MARK: - Audio Format (cached)

    private let formatDescription: CMAudioFormatDescription

    // MARK: - Init

    init() throws(AudioRendererError) {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(Self.bytesPerSample) * Self.channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Self.bytesPerSample) * Self.channelCount,
            mChannelsPerFrame: Self.channelCount,
            mBitsPerChannel: UInt32(Self.bytesPerSample * 8),
            mReserved: 0,
        )

        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &desc,
        )
        guard status == noErr, let formatDesc = desc else {
            throw AudioRendererError.formatDescription(status)
        }
        formatDescription = formatDesc
        receiver.withLock { $0 = synchronizer.sampleBufferReceiver(adding: renderer) }

        debugLog("AudioRenderer", "Initialized (44100Hz, 2ch, Float32)")
    }

    deinit {
        pendingFeed?.cancel()
        renderingEventTask?.cancel()
        receiver.withLock { $0?.flush() }
        retireReceiver()
    }

    // MARK: - Volume

    /// Sets the output gain (0...1) applied to playback. Takes effect immediately
    /// — it scales audio as it is played out, not the already-buffered PCM — so
    /// volume changes are not delayed by the render buffer.
    func setVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        renderQueue.async { [weak self] in
            guard let self else { return }
            outputVolume = clamped
            renderer.volume = clamped
        }
    }

    // MARK: - Push Side (called from Rust player thread)

    /// Write PCM samples into the ring buffer.
    /// Applies bounded backpressure when the buffer is full; drops rather than parking
    /// the player thread on space that only control operations can create.
    func writeAudioData(_ samples: UnsafePointer<Float>, count: Int) {
        var remaining = count
        var offset = 0

        // The wait belongs to this callback. A concurrent route reset may free space, but
        // cannot replenish this write's one bounded wait.
        var writeBudget = PCMWriteBudget()

        while remaining > 0 {
            bufferLock.lock()
            switch ringBuffer.write(UnsafeBufferPointer(start: samples.advanced(by: offset), count: remaining)) {
            case .rejectedInput:
                droppedSampleCount &+= UInt64(remaining)
                bufferLock.unlock()
                return
            case .full:
                guard writeBudget.takeWait(isRendering: outputControl.isRendering) else {
                    droppedSampleCount &+= UInt64(remaining)
                    bufferLock.unlock()
                    return
                }
                // Kick the pull side if an underrun stopped it; otherwise a full ring
                // waits for a consumer that is no longer asking for data.
                let needsRestart = !isRequestingData
                writerSpace.arm()
                bufferLock.unlock()
                if needsRestart {
                    renderQueue.async { [weak self] in
                        self?.startRequestingData()
                    }
                }
                _ = writerSpace.wait(timeoutMilliseconds: PCMWriteBudget.timeoutMilliseconds)
                continue
            case let .written(toWrite):
                totalSamplesWritten += Int64(toWrite)
                let samplesWritten = totalSamplesWritten
                let startTime = writeStartTime
                let needsRestart = outputControl.isRendering && !isRequestingData
                bufferLock.unlock()

                // If renderer stopped requesting data (buffer was empty), restart it
                if needsRestart {
                    renderQueue.async { [weak self] in
                        self?.startRequestingData()
                    }
                }

                // Time-based throttle: AVSampleBufferAudioRenderer eagerly accepts data
                // for buffering, providing no real-time backpressure. Without this check,
                // librespot decodes at full CPU speed (~7x), racing through tracks.
                let audioDuration = Double(samplesWritten) / (Self.sampleRate * Double(Self.channelCount))
                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let ahead = audioDuration - elapsed
                if ahead > Self.maxBufferAheadSeconds {
                    let sleepDuration = ahead - Self.maxBufferAheadSeconds
                    bufferLock.withLock { throttleSeconds += sleepDuration }
                    Thread.sleep(forTimeInterval: sleepDuration)
                }

                remaining -= toWrite
                offset += toWrite
            }
        }
    }

    // MARK: - Receiver Pump (renderQueue only)

    private func startRequestingData() {
        bufferLock.lock()
        guard outputControl.isRendering, !isRequestingData else {
            bufferLock.unlock()
            return
        }
        isRequestingData = true
        bufferLock.unlock()

        scheduleFeed(after: 0)
    }

    private func scheduleFeed(after delay: TimeInterval) {
        let generation = pump.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, pump.accepts(generation) else { return }
            pendingFeed = nil
            feedRenderer()
        }
        pendingFeed = work
        renderQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopRequestingData(resetPresentationTime: Bool = false) {
        pendingFeed?.cancel()
        pendingFeed = nil
        renderingEventTask?.cancel()
        renderingEventTask = nil
        pump.invalidate(resetPresentationTime: resetPresentationTime)
        bufferLock.withLock { isRequestingData = false }
    }

    private func feedRenderer() {
        renderingEventTask?.cancel()
        renderingEventTask = nil
        // Cancellation cannot retract an event already dispatched to renderQueue.
        pump.invalidate()
        while true {
            // Read a chunk from ring buffer
            bufferLock.lock()
            guard outputControl.isRendering, isRequestingData else {
                bufferLock.unlock()
                stopRequestingData()
                return
            }
            let requestedFrames = min(Self.feedChunkFrames, ringBuffer.availableFrames)

            if requestedFrames == 0 {
                // Buffer empty — stop requesting until more data arrives
                if outputControl.isRendering { underrunCount &+= 1 }
                isRequestingData = false
                bufferLock.unlock()
                observeRenderingEvents()
                return
            }

            // Immediate enqueue has no readiness backpressure. Admit a whole chunk only
            // if its end fits the existing two-second horizon, then sleep one chunk's
            // duration. The ring remains the bounded producer/consumer bridge.
            let chunkDuration = Double(requestedFrames) / Self.sampleRate
            if !pump.canEnqueue(
                duration: chunkDuration,
                playhead: synchronizer.currentTime(),
                maximumAhead: Self.maxBufferAheadSeconds)
            {
                bufferLock.unlock()
                scheduleFeed(after: Double(Self.feedChunkFrames) / Self.sampleRate)
                observeRenderingEvents()
                return
            }

            // Unique mutable Core Media storage becomes immutable after the ring copy.
            let chunkSize = requestedFrames * Int(Self.channelCount) * Self.bytesPerSample
            var chunk = CMMutableDataBlockBuffer(count: chunkSize)
            guard
                let frameCount = chunk.withContiguousMutableStorageIfAvailable({ storage in
                    ringBuffer.read(into: storage.bindMemory(to: Float.self))
                })
            else {
                isRequestingData = false
                bufferLock.unlock()
                stopRequestingData()
                debugLog("AudioRenderer", "Failed to allocate audio chunk")
                return
            }

            bufferLock.unlock()
            writerSpace.signalIfArmed()

            // The immutable Core Media wrappers own the allocation without copying PCM.
            let sample = CMReadySampleBuffer(
                audioDataBuffer: CMReadOnlyDataBlockBuffer(chunk),
                formatDescription: formatDescription,
                sampleCount: frameCount,
                presentationTimeStamp: pump.presentationTime,
            )
            guard let result = receiver.withLock({ $0?.enqueueImmediately(CMReadySampleBuffer(sample)) }) else {
                stopRequestingData()
                return
            }
            switch AudioRendererPump.action(for: result) {
            case .advance:
                pump.didEnqueue(frames: frameCount, sampleRate: CMTimeScale(Self.sampleRate))
            case .recreate:
                recoverRenderPipeline()
                return
            case .stop:
                stopRequestingData()
                return
            }
        }
    }

    // MARK: - Playback Control

    /// Called from Rust player thread via FFI callback. Synchronous dispatch
    /// ensures the caller can rely on state being fully updated on return
    /// (e.g. playback teardown expects flush to complete before proceeding).
    func start() {
        renderQueue.sync { [self] in
            bufferLock.lock()
            guard !outputControl.isRendering else {
                // Already rendering, so the full pipeline reset below is skipped — a
                // deliberate no-op, since flushing mid-playback would glitch the audio.
                //
                // But the throttle anchor must still be re-armed. It measures written
                // audio against wall clock *since the anchor*, so any period where the
                // writer was idle — an outage, a rebuild — banks credit against it. On the
                // next write the throttle sees a large deficit, never sleeps, and lets the
                // decoder run flat out until it catches up: playback races, EndOfTrack
                // fires early, and Spirc advances the track while the renderer still has
                // tens of seconds buffered.
                //
                // Re-anchoring is safe here: it only rebases the pacing budget and does
                // not touch the ring buffer or its contents.
                writeStartTime = ProcessInfo.processInfo.systemUptime
                totalSamplesWritten = 0
                bufferLock.unlock()
                debugLog("AudioRenderer", "Start while already rendering — re-anchored throttle")
                return
            }
            outputControl.beginStart()
            bufferLock.unlock()

            // Clear stale data from previous playback to prevent timestamp conflicts
            // and loss of real-time pacing (28x speed bug).
            resetAudioPipeline()
            synchronizer.setRate(1.0, time: .zero)
            startRequestingData()
            debugLog("AudioRenderer", "Started playback")
        }
    }

    func stop() {
        // Wake a parked writer before joining `renderQueue`. Clear rendering on this thread so
        // the writer can drop, but only tear down AVFoundation if a later start has not already
        // won the queue.
        bufferLock.lock()
        let capturedGeneration = outputControl.beginStop()
        isRequestingData = false
        bufferLock.unlock()
        writerSpace.signalIfArmed()
        guard let capturedGeneration else { return }

        renderQueue.sync { [self] in
            bufferLock.lock()
            let applyStop = outputControl.shouldApplyStop(capturedGeneration)
            bufferLock.unlock()
            guard applyStop else { return }

            synchronizer.setRate(0.0, time: synchronizer.currentTime())
            stopRequestingData()
            let metrics = metricsDescriptionLocked()
            debugLog("AudioRenderer", "Stopped playback")
            SpottyLog.audio.info("Audio session metrics: \(metrics, privacy: .public)")
        }
    }

    func flush() {
        // Reset the ring and wake a waiting writer without first joining `renderQueue`,
        // then serialize AVFoundation flush on that queue.
        resetRingCursorAndWakeWriter()

        renderQueue.sync { [self] in
            debugLog("AudioRenderer", "Flushing audio buffer")
            stopRequestingData(resetPresentationTime: true)
            receiver.withLock { $0?.flush() }

            bufferLock.lock()
            let rendering = outputControl.isRendering
            bufferLock.unlock()

            if rendering {
                synchronizer.setRate(1.0, time: .zero)
                startRequestingData()
            }
        }
    }

    // MARK: - Route Change Recovery

    /// Enqueue results report route changes during a burst. This supported, Sendable
    /// event sequence covers the period after a burst, including an empty PCM ring.
    /// Only the sequence crosses executors; the live receiver stays on renderQueue.
    private func observeRenderingEvents() {
        guard let events = receiver.withLock({ $0?.renderingEventsAfterFinishedEnqueuing }) else { return }
        let generation = pump.generation
        renderingEventTask = Task.detached { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.renderQueue.async { [weak self] in
                    guard let self, pump.accepts(generation) else { return }
                    switch event {
                    case .wasFlushedAutomatically, .outputConfigurationChanged, .failed:
                        recoverRenderPipeline()
                    @unknown default:
                        recoverRenderPipeline()
                    }
                }
            }
        }
    }

    private func recoverRenderPipeline() {
        guard bufferLock.withLock({ outputControl.isRendering }) else { return }
        debugLog("AudioRenderer", "Recreating pipeline after rendering event")
        recreateRenderPipeline()
        synchronizer.setRate(1.0, time: .zero)
        startRequestingData()
    }

    /// Transfer only the retired receiver to the asynchronous removal operation. No
    /// subsequent pump or control may access it; removal retains its old synchronizer.
    private func retireReceiver() {
        let retired = Mutex(
            receiver.withLock { current in
                let retired = current
                current = nil
                return retired
            })
        let retiredSynchronizer = synchronizer
        Task.detached {
            let transferred = retired.withLock { current in
                let transferred = current
                current = nil
                return transferred
            }
            guard let retiredReceiver = transferred else { return }
            _ = await retiredSynchronizer.removeReceiver(retiredReceiver, at: .invalid)
        }
    }

    /// Tear down the old renderer/synchronizer and create fresh ones.
    /// An output device change leaves the CoreAudio context in a broken state
    /// where the renderer accepts data but doesn't pace it.
    /// Must be called on renderQueue.
    private func recreateRenderPipeline() {
        let interval = SpottyLog.audioSignposter.beginInterval("Route recreation")
        defer { SpottyLog.audioSignposter.endInterval("Route recreation", interval) }
        stopRequestingData(resetPresentationTime: true)
        receiver.withLock { $0?.flush() }
        synchronizer.setRate(0.0, time: .invalid)
        retireReceiver()

        renderer = AVSampleBufferAudioRenderer()
        renderer.volume = outputVolume
        synchronizer = AVSampleBufferRenderSynchronizer()
        receiver.withLock { $0 = synchronizer.sampleBufferReceiver(adding: renderer) }

        resetRingBuffer()

        debugLog("AudioRenderer", "Render pipeline recreated")
    }

    // MARK: - Internal

    /// Discards buffered frames and wakes a parked writer. Safe from any thread.
    private func resetRingCursorAndWakeWriter() {
        bufferLock.lock()
        isRequestingData = false
        ringBuffer.reset()
        totalSamplesWritten = 0
        writeStartTime = ProcessInfo.processInfo.systemUptime
        bufferLock.unlock()
        writerSpace.signalIfArmed()
    }

    /// Resets the ring buffer indices, PTS, and unblocks any waiting writer.
    /// Must be called on renderQueue.
    private func resetRingBuffer() {
        resetRingCursorAndWakeWriter()
        pump.invalidate(resetPresentationTime: true)
    }

    /// Must be called on renderQueue. The ring-buffer counters are read under their lock so one
    /// bounded summary can be emitted instead of logging on the real-time path.
    private func metricsDescriptionLocked() -> String {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let formattedThrottle = String(format: "%.3f", throttleSeconds)
        return
            "underruns=\(underrunCount), droppedSamples=\(droppedSampleCount), throttleSeconds=\(formattedThrottle), bufferedSamples=\(ringBuffer.availableFrames * Int(Self.channelCount))"
    }

    /// Flushes the renderer and resets the ring buffer.
    /// Must be called on renderQueue.
    private func resetAudioPipeline() {
        stopRequestingData(resetPresentationTime: true)
        receiver.withLock { $0?.flush() }
        resetRingBuffer()
    }
}

/// Queue-owned scheduling/timeline state, separable from system audio for synthetic checks.
nonisolated struct AudioRendererPump {
    enum EnqueueAction: Equatable {
        case advance, recreate, stop
    }

    private(set) var generation: UInt64 = 0
    private(set) var presentationTime: CMTime = .zero

    mutating func invalidate(resetPresentationTime: Bool = false) {
        generation &+= 1
        if resetPresentationTime { presentationTime = .zero }
    }

    func accepts(_ captured: UInt64) -> Bool { captured == generation }

    func canEnqueue(duration: TimeInterval, playhead: CMTime, maximumAhead: TimeInterval) -> Bool {
        let end = presentationTime.seconds + duration
        let now = playhead.seconds
        return end.isFinite && now.isFinite && end - now <= maximumAhead
    }

    mutating func didEnqueue(frames: Int, sampleRate: CMTimeScale) {
        presentationTime = CMTimeAdd(presentationTime, CMTime(value: CMTimeValue(frames), timescale: sampleRate))
    }

    static func action(for result: AVSampleBufferAudioRenderer.Receiver.EnqueueResult) -> EnqueueAction {
        switch result {
        case .enqueued: .advance
        case let .enqueuedWithSuggestedFlush(reasons): reasons.isEmpty ? .advance : .recreate
        case .cancelledDueToFlush: .stop
        case .cancelledDueToError: .recreate
        @unknown default: .stop
        }
    }
}

/// The one process-wide renderer. PCM reaches it directly from the retained engine adapter's
/// decoder callback; it is never routed through observable UI state.
nonisolated let spottyAudioRendererResult: Result<AudioRenderer, AudioRendererError> = {
    do {
        return .success(try AudioRenderer())
    } catch {
        SpottyLog.audio.error("Audio renderer initialization failed")
        return .failure(error as? AudioRendererError ?? .formatDescription(-1))
    }
}()
