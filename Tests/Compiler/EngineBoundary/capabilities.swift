import SpottyEngineAdapter
import SpottyRuntimeContracts

// Type-check only: a runtime package peer can compose audio preparation without constructing
// a renderer or acquiring PCM, output-control, or singleton access.
func useAudioPreparation() throws {
    let output: any AudioOutputPreparing = LiveAudioOutput()
    try output.prepareForPlayback()
}

func rejectRendererImplementationAccess() {
    // expected-error@+1 {{cannot find 'AudioRenderer' in scope}}
    _ = AudioRenderer.self
    // expected-error@+1 {{cannot find 'AudioRendererError' in scope}}
    _ = AudioRendererError.self
    // expected-error@+1 {{cannot find 'spottyAudioRendererResult' in scope}}
    _ = spottyAudioRendererResult
}
