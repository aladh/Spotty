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

public nonisolated enum AudioRendererError: LocalizedError, Sendable {
    case formatDescription(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .formatDescription(status):
            "Spotty could not configure the system audio output (\(status))."
        }
    }
}

/// Audio renderer that bridges librespot's push model (Sink::write) to
/// AVSampleBufferAudioRenderer's pull model (requestMediaDataWhenReady).
///
/// Thread safety: `writeAudioData` is called from librespot's Rust player thread.
/// `feedRenderer` runs on a dedicated serial dispatch queue.
/// A ring buffer with lock-based synchronization bridges the two.
///
/// The write path may park briefly when the ring is full, but it cannot wait for space
/// that only `stop` / `flush` / route recreation can create. Those controls also run on
/// the player thread, so a full buffer uses one 500 ms backpressure wait and then drops.
///
public final nonisolated class AudioRenderer: @unchecked Sendable {
    // MARK: - Constants

    private static let sampleRate: Float64 = 44100
    private static let channelCount: UInt32 = 2
    private static let bytesPerSample = MemoryLayout<Float>.size  // 4

    /// Ring buffer capacity in f32 samples (~2 seconds of stereo audio)
    private static let ringBufferCapacity = 176_400  // 44100 * 2ch * 2s

    /// Chunk size for feeding renderer (~1024 frames = 2048 stereo samples)
    private static let feedChunkSamples = 2048

    // MARK: - AVFoundation Objects (recreated on output device change)

    private var renderer = AVSampleBufferAudioRenderer()
    private var synchronizer = AVSampleBufferRenderSynchronizer()

    /// Output gain (0...1) applied at the renderer. librespot's soft mixer is
    /// bypassed (NoOpVolume), so this is where playback volume is actually applied —
    /// at the output, which takes effect immediately instead of after the buffered
    /// PCM drains. Accessed only on `renderQueue` so it stays serialized with
    /// feeding and pipeline recreation.
    private var outputVolume: Float = 1.0

    // MARK: - Ring Buffer

    private let ringBuffer: UnsafeMutablePointer<Float>
    private var cursor = PCMBufferCursor(capacity: ringBufferCapacity)
    private let bufferLock = NSLock()

    /// Wake-up for a writer parked on a full buffer. Signal only while a wait is armed.
    private let writerSpace = PCMWriteSpace()
    private var writeBackpressure = PCMWriteBackpressure()
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
    private var currentPTS: CMTime = .zero
    private var isRequestingData = false
    private var underrunCount: UInt64 = 0
    private var droppedSampleCount: UInt64 = 0
    private var throttleSeconds: TimeInterval = 0

    // MARK: - Route Change Observation

    private var routeChangeObserver: (any NSObjectProtocol)?

    // MARK: - Audio Format (cached)

    private let formatDescription: CMAudioFormatDescription

    // MARK: - Init

    public init() throws(AudioRendererError) {
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
        ringBuffer = .allocate(capacity: Self.ringBufferCapacity)
        ringBuffer.initialize(repeating: 0, count: Self.ringBufferCapacity)
        synchronizer.addRenderer(renderer)

        // Recover from output device changes (AirPlay ↔ local speaker)
        observeRouteChanges()

        debugLog("AudioRenderer", "Initialized (44100Hz, 2ch, Float32)")
    }

    deinit {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        renderer.stopRequestingMediaData()
        synchronizer.removeRenderer(renderer, at: .invalid)
        ringBuffer.deallocate()
    }

    // MARK: - Volume

    /// Sets the output gain (0...1) applied to playback. Takes effect immediately
    /// — it scales audio as it is played out, not the already-buffered PCM — so
    /// volume changes are not delayed by the render buffer. The caller is expected
    /// to have applied any perceptual curve already (see SpotifyPlayer).
    public func setVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        renderQueue.async { [weak self] in
            guard let self else { return }
            outputVolume = clamped
            renderer.volume = clamped
        }
    }

    // MARK: - Ring Buffer Helpers

    /// Number of samples available for reading. Must be called with bufferLock held.
    private var availableSamples: Int {
        cursor.available
    }

    /// Free space in the ring buffer (-1 to distinguish full from empty). Must be called with bufferLock held.
    private var freeSpace: Int {
        cursor.free
    }

    // MARK: - Push Side (called from Rust player thread)

    /// Write PCM samples into the ring buffer.
    /// Applies bounded backpressure when the buffer is full; drops rather than parking
    /// the player thread on space that only control operations can create.
    public func writeAudioData(_ samples: UnsafePointer<Float>, count: Int) {
        var remaining = count
        var offset = 0

        bufferLock.lock()
        writeBackpressure.beginWrite()
        bufferLock.unlock()

        while remaining > 0 {
            bufferLock.lock()
            switch writeBackpressure.admit(
                freeSpace: freeSpace,
                remaining: remaining,
                isRendering: outputControl.isRendering
            ) {
            case .dropRemaining:
                droppedSampleCount &+= UInt64(remaining)
                bufferLock.unlock()
                return
            case .waitForSpace:
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
                _ = writerSpace.wait(timeoutMilliseconds: PCMWriteBackpressure.waitTimeoutMilliseconds)
                continue
            case let .write(toWrite):
                copyIntoRing(samples, offset: offset, count: toWrite)
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

    /// Copies `count` samples from `samples[offset...]` into the ring at the current write
    /// cursor, wrapping as needed, and advances the cursor. Must be called with `bufferLock` held.
    private func copyIntoRing(_ samples: UnsafePointer<Float>, offset: Int, count: Int) {
        let firstChunk = min(count, Self.ringBufferCapacity - cursor.writeIndex)
        ringBuffer.advanced(by: cursor.writeIndex)
            .update(from: samples.advanced(by: offset), count: firstChunk)

        if firstChunk < count {
            let secondChunk = count - firstChunk
            ringBuffer.update(from: samples.advanced(by: offset + firstChunk), count: secondChunk)
        }

        cursor.advanceWrite(by: count)
    }

    // MARK: - Pull Side (called on renderQueue by AVSampleBufferAudioRenderer)

    private func startRequestingData() {
        bufferLock.lock()
        guard outputControl.isRendering, !isRequestingData else {
            bufferLock.unlock()
            return
        }
        isRequestingData = true
        bufferLock.unlock()

        renderer.requestMediaDataWhenReady(on: renderQueue) { [weak self] in
            self?.feedRenderer()
        }
    }

    private func feedRenderer() {
        while renderer.isReadyForMoreMediaData {
            // Read a chunk from ring buffer
            bufferLock.lock()
            let available = availableSamples
            let toRead = min(Self.feedChunkSamples, available)

            if toRead == 0 {
                // Buffer empty — stop requesting until more data arrives
                if outputControl.isRendering { underrunCount &+= 1 }
                isRequestingData = false
                bufferLock.unlock()
                renderer.stopRequestingMediaData()
                return
            }

            // Allocate through the same allocator Core Media will use to release the block.
            let chunkSize = toRead * Self.bytesPerSample
            guard let chunk = CFAllocatorAllocate(kCFAllocatorDefault, chunkSize, 0) else {
                isRequestingData = false
                bufferLock.unlock()
                renderer.stopRequestingMediaData()
                debugLog("AudioRenderer", "Failed to allocate audio chunk")
                return
            }

            // Copy with wrap-around
            let firstChunk = min(toRead, Self.ringBufferCapacity - cursor.readIndex)
            chunk.copyMemory(
                from: ringBuffer.advanced(by: cursor.readIndex),
                byteCount: firstChunk * Self.bytesPerSample,
            )
            if firstChunk < toRead {
                let secondChunk = toRead - firstChunk
                chunk.advanced(by: firstChunk * Self.bytesPerSample)
                    .copyMemory(from: ringBuffer, byteCount: secondChunk * Self.bytesPerSample)
            }

            cursor.advanceRead(by: toRead)
            bufferLock.unlock()
            writerSpace.signalIfArmed()

            // Create CMBlockBuffer from chunk data
            var blockBuffer: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: chunk,
                blockLength: chunkSize,
                blockAllocator: kCFAllocatorDefault,  // Core Media will free the block
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: chunkSize,
                flags: 0,
                blockBufferOut: &blockBuffer,
            )

            guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
                CFAllocatorDeallocate(kCFAllocatorDefault, chunk)
                debugLog("AudioRenderer", "Failed to create CMBlockBuffer: \(status)")
                return
            }

            // Create CMSampleBuffer
            let frameCount = toRead / Int(Self.channelCount)
            var sampleBuffer: CMSampleBuffer?
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: formatDescription,
                sampleCount: frameCount,
                presentationTimeStamp: currentPTS,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer,
            )

            guard status == noErr, let sample = sampleBuffer else {
                debugLog("AudioRenderer", "Failed to create CMSampleBuffer: \(status)")
                return
            }

            // Advance presentation time
            currentPTS = CMTimeAdd(
                currentPTS,
                CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(Self.sampleRate)),
            )

            // Enqueue
            renderer.enqueue(sample)
        }
    }

    // MARK: - Playback Control

    /// Called from Rust player thread via FFI callback. Synchronous dispatch
    /// ensures the caller can rely on state being fully updated on return
    /// (e.g. playback teardown expects flush to complete before proceeding).
    public func start() {
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

    public func stop() {
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
            renderer.stopRequestingMediaData()
            let metrics = metricsDescriptionLocked()
            debugLog("AudioRenderer", "Stopped playback")
            SpottyLog.audio.info("Audio session metrics: \(metrics, privacy: .public)")
        }
    }

    public func flush() {
        // Reset the ring and wake a waiting writer without first joining `renderQueue`,
        // then serialize AVFoundation flush on that queue.
        resetRingCursorAndWakeWriter()

        renderQueue.sync { [self] in
            debugLog("AudioRenderer", "Flushing audio buffer")
            currentPTS = .zero
            renderer.stopRequestingMediaData()
            renderer.flush()

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

    /// Observe the renderer's auto-flush notification, which fires when the
    /// output device changes (e.g. AirPlay ↔ local speaker). After an auto-flush
    /// the renderer's internal CoreAudio context is broken (FigSync/timebase errors),
    /// so we must recreate the renderer and synchronizer entirely.
    private func observeRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil,
        ) { [weak self] notification in
            guard let self else { return }

            let flushTime =
                (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?
                .timeValue ?? .zero
            debugLog("AudioRenderer", "Renderer auto-flushed (output device changed, time: \(flushTime))")

            // Recreate pipeline on renderQueue (async since this fires on an arbitrary thread)
            renderQueue.async { [self] in
                bufferLock.lock()
                let rendering = outputControl.isRendering
                bufferLock.unlock()

                guard rendering else { return }

                debugLog("AudioRenderer", "Recreating pipeline after output device change")
                recreateRenderPipeline()
                synchronizer.setRate(1.0, time: .zero)
                startRequestingData()
            }
        }
    }

    /// Tear down the old renderer/synchronizer and create fresh ones.
    /// An output device change leaves the CoreAudio context in a broken state
    /// where the renderer accepts data but doesn't pace it.
    /// Must be called on renderQueue.
    private func recreateRenderPipeline() {
        let interval = SpottyLog.audioSignposter.beginInterval("Route recreation")
        defer { SpottyLog.audioSignposter.endInterval("Route recreation", interval) }
        renderer.stopRequestingMediaData()
        renderer.flush()
        synchronizer.removeRenderer(renderer, at: .invalid)

        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }

        renderer = AVSampleBufferAudioRenderer()
        renderer.volume = outputVolume
        synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)

        resetRingBuffer()
        observeRouteChanges()

        debugLog("AudioRenderer", "Render pipeline recreated")
    }

    // MARK: - Internal

    /// Resets ring indices and the wait budget, and wakes a parked writer. Safe from any thread.
    private func resetRingCursorAndWakeWriter() {
        bufferLock.lock()
        isRequestingData = false
        cursor.reset()
        totalSamplesWritten = 0
        writeStartTime = ProcessInfo.processInfo.systemUptime
        writeBackpressure.beginWrite()
        bufferLock.unlock()
        writerSpace.signalIfArmed()
    }

    /// Resets the ring buffer indices, PTS, and unblocks any waiting writer.
    /// Must be called on renderQueue.
    private func resetRingBuffer() {
        resetRingCursorAndWakeWriter()
        currentPTS = .zero
    }

    /// Must be called on renderQueue. The ring-buffer counters are read under their lock so one
    /// bounded summary can be emitted instead of logging on the real-time path.
    private func metricsDescriptionLocked() -> String {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let formattedThrottle = String(format: "%.3f", throttleSeconds)
        return
            "underruns=\(underrunCount), droppedSamples=\(droppedSampleCount), throttleSeconds=\(formattedThrottle), bufferedSamples=\(cursor.available)"
    }

    /// Flushes the renderer and resets the ring buffer.
    /// Must be called on renderQueue.
    private func resetAudioPipeline() {
        renderer.stopRequestingMediaData()
        renderer.flush()
        resetRingBuffer()
    }
}

/// The one process-wide renderer. PCM reaches it directly from the retained engine adapter's
/// decoder callback; it is never routed through observable UI state.
public nonisolated let spottyAudioRendererResult: Result<AudioRenderer, AudioRendererError> = {
    do {
        return .success(try AudioRenderer())
    } catch {
        SpottyLog.audio.error("Audio renderer initialization failed")
        return .failure(error as? AudioRendererError ?? .formatDescription(-1))
    }
}()
