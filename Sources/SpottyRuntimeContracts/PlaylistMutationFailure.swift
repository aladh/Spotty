/// A write rejection is distinct from transport failure; neither permits automatic replay.
public enum PlaylistMutationFailure: Error, Equatable, Sendable {
    case rejected
    case failed
}
