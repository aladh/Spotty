import SpottyHarnessSupport

// Keep existing test callers on their shared API; runnable Demo primitives never import Testing.
public typealias HarnessResponseGate<Value: Sendable> = SpottyHarnessSupport.HarnessResponseGate<Value>
public typealias HarnessSuspension = SpottyHarnessSupport.HarnessSuspension
#if os(macOS)
    public typealias HomePresentedFrameCollector = SpottyHarnessSupport.HomePresentedFrameCollector
#endif
