import SpottyRuntimeContracts

package nonisolated struct LiveAudioOutput: AudioOutputPreparing {
    package init() {}

    package func prepareForPlayback() throws {
        try spottyAudioRendererResult.get().setVolume(1)
    }
}
