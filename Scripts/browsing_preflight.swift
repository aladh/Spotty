// Read-only rendering preflight. No app launch, capture, grant request, or settings mutation.
import AppKit

func sessionBoolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
        CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
        return nil
    }
    return number.boolValue
}

let session = CGSessionCopyCurrentDictionary() as? [String: Any]
let onConsole = sessionBoolean(session?[kCGSessionOnConsoleKey as String]) == true
let loginDone = sessionBoolean(session?[kCGSessionLoginDoneKey as String]) == true
let lockValue = session?["CGSSessionScreenIsLocked"]
let explicitLock = sessionBoolean(lockValue)
let locked: Bool?
let lockEvidence: String
if let explicitLock {
    locked = explicitLock
    lockEvidence = "explicit"
} else if lockValue == nil, session != nil, onConsole, loginDone {
    // WindowServer can omit this private dictionary key while unlocked. This is
    // an inference from a complete active session, not a documented security API.
    locked = false
    lockEvidence = "implicit-unlocked"
} else {
    // Missing sessions and malformed flags never establish rendering eligibility.
    locked = nil
    lockEvidence = "unknown"
}

var displayCount: UInt32 = 0
let displayResult = CGGetActiveDisplayList(0, nil, &displayCount)
let reducedMotion: Bool? = session == nil ? nil : NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

// Serialize only this fixed allowlist; the session dictionary contains private
// account/host information and must never be logged or written to the run manifest.
let result: [String: Any] = [
    "schemaVersion": 1,
    "session": [
        "available": session != nil,
        "onConsole": onConsole,
        "loginDone": loginDone,
        "locked": locked as Any? ?? NSNull(),
        "lockEvidence": lockEvidence,
    ],
    "displayCount": displayResult == .success ? displayCount as Any : NSNull(),
    "reducedMotion": reducedMotion as Any? ?? NSNull(),
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
