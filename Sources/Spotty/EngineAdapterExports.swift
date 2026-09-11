// The engine adapter is the only target that links the playback binary. SpottyCore consumes its
// typed observations, engine ports, renderer, and logging everywhere, so it is re-exported once
// here instead of being imported file by file. Adding a per-file import is not an error, but this
// file is what keeps the FFI boundary a package-graph fact rather than a source convention:
// nothing in SpottyCore can reach `SpottyPlaybackCore` through it.
@_exported import SpottyEngineAdapter
