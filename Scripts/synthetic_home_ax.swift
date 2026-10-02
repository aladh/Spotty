import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation

/// One causal Home diagnostic. Never admits a live bundle or a playback action.
@MainActor
private final class HomeAXDiagnostic {
    struct Identity: Decodable {
        let runID: String
        let pid: Int32
        let executable: String
        let startIdentity: String
    }

    struct Failure: Error { let reason: String }
    let root: URL
    let identity: Identity
    let expectedHead: String
    let expectedSource: String
    let expectedExecutable: String
    let nonce = UUID().uuidString
    var measurement = false
    var measuredWindow: HomeAXProtocol.MeasuredWindow?
    var sections = 12
    var homePublicationAdmitted = false
    var deadlineMachTime: UInt64 = 0
    var evidence: [String: Any] = ["performanceMeasurement": false, "activationAttempted": false]
    var attributeErrors: [String: Int] = [:]

    init(root: URL, head: String, source: String, executable: String) throws {
        self.root = root.resolvingSymlinksInPath()
        expectedHead = head
        expectedSource = source
        expectedExecutable = executable
        identity = try JSONDecoder().decode(
            Identity.self, from: Data(contentsOf: self.root.appendingPathComponent("process.json")))
        evidence["runID"] = identity.runID
        evidence["pid"] = identity.pid
        evidence["nonce"] = nonce
    }

    func json(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure(reason: "invalid metadata")
        }
        return value
    }

    func validateTarget(verifySafety: Bool = true) throws {
        try checkDeadline()
        guard AXIsProcessTrusted(), identity.pid > 0,
            let running = NSRunningApplication(processIdentifier: identity.pid), !running.isTerminated,
            running.bundleIdentifier == "dev.spotty.demo",
            let executable = running.executableURL?.resolvingSymlinksInPath(),
            executable == URL(fileURLWithPath: identity.executable).resolvingSymlinksInPath(),
            let bundle = running.bundleURL, let resources = Bundle(url: bundle)?.resourceURL
        else { throw Failure(reason: "owned Demo identity or existing Accessibility access unavailable") }
        let digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedExecutable else { throw Failure(reason: "signed executable changed") }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(identity.pid), "-o", "lstart="]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["LC_ALL": "C", "LANG": "C", "TZ": "UTC"], uniquingKeysWith: { _, value in value })
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                == identity.startIdentity
        else { throw Failure(reason: "owned process birth changed") }
        let launch = try json(resources.appendingPathComponent("launch.json"))
        let manifest = try json(root.appendingPathComponent("manifest.json"))
        let scenario = try json(resources.appendingPathComponent("scenario.json"))
        measurement = scenario["homePresentedMeasurement"] as? Bool == true
        sections = scenario["homePresentedProbeSections"] as? Int ?? 0
        let source = launch["source"] as? [String: Any]
        guard (launch as NSDictionary).isEqual(to: manifest), launch["schemaVersion"] as? Int == 1,
            launch["runID"] as? String == identity.runID, UUID(uuidString: identity.runID) != nil,
            URL(fileURLWithPath: launch["runRoot"] as? String ?? "").resolvingSymlinksInPath() == root,
            launch["automated"] as? Bool == false,
            source?["revision"] as? String == expectedHead, source?["sourceSHA256"] as? String == expectedSource,
            source?["untrackedFileCount"] as? Int == 0,
            (launch["engine"] as? [String: Any])?["usedForPlayback"] as? Bool == false,
            scenario["mode"] as? String == "browsing", (sections == 12 || (measurement && sections == 120)),
            scenario["guiShellRegression"] as? Bool != true, scenario["expandedLibrary"] as? Bool != true,
            scenario["acceptanceScenarioID"] == nil
        else { throw Failure(reason: "only the exact admitted interactive synthetic Home run is admitted") }
        evidence["performanceMeasurement"] = measurement
        if verifySafety { _ = try safety() }
        try checkDeadline()
    }

    func safetyObservation() throws -> (status: [String: Any], predicates: [String: Bool], observation: [String: Any]) {
        let status = try json(root.appendingPathComponent("run-status.json"))
        let observedAt = Date().timeIntervalSince1970
        let predicates = HomeAXProtocol.safetyPredicates(
            status, runID: identity.runID, pid: identity.pid, sections: sections,
            measurement: measurement, populatedAlready: homePublicationAdmitted, now: observedAt)
        let failed = predicates.filter { !$0.value }.map(\.key).sorted()
        let observation: [String: Any] = [
            "pulse": status, "observedAtSeconds": observedAt, "observedMachTime": mach_absolute_time(),
            "pulseAgeSeconds": (status["recordedAtSeconds"] as? Double).map { observedAt - $0 } as Any? ?? NSNull(),
            "predicates": predicates, "failedPredicates": failed, "expectedSections": sections,
            "measurement": measurement, "homePublicationAdmitted": homePublicationAdmitted,
        ]
        evidence["lastSafetyObservation"] = observation
        return (status, predicates, observation)
    }

    func safety() throws -> [String: Any] {
        let (status, predicates, observation) = try safetyObservation()
        let failed = predicates.filter { !$0.value }.map(\.key).sorted()
        guard failed.isEmpty else {
            evidence["rejectedSafetyObservation"] = observation
            throw Failure(reason: "synthetic safety pulse rejected: \(failed.joined(separator: ", "))")
        }
        evidence["lastSafetyPulse"] = status
        return status
    }

    func publicationPulse() throws -> [String: Any]? {
        let (status, predicates, observation) = try safetyObservation()
        if HomeAXProtocol.mayWaitForPublicationPulse(
            status, predicates: predicates, measurement: measurement,
            populatedAlready: homePublicationAdmitted, now: observation["observedAtSeconds"] as? Double ?? .nan)
        {
            try validateTarget(verifySafety: false)
            try checkDeadline()
            if evidence["firstPendingPublicationPulse"] == nil {
                evidence["firstPendingPublicationPulse"] = observation
            }
            evidence["lastPendingPublicationPulse"] = observation
            evidence["pendingPublicationPulseCount"] = (evidence["pendingPublicationPulseCount"] as? Int ?? 0) + 1
            return nil
        }
        let failed = predicates.filter { !$0.value }.map(\.key).sorted()
        guard failed.isEmpty else {
            evidence["rejectedSafetyObservation"] = observation
            throw Failure(reason: "synthetic safety pulse rejected: \(failed.joined(separator: ", "))")
        }
        evidence["lastSafetyPulse"] = status
        return status
    }

    func checkDeadline() throws {
        if deadlineMachTime != 0, mach_absolute_time() >= deadlineMachTime {
            throw Failure(reason: "shared ten-second deadline reached")
        }
    }

    func readRPC<Value>(
        _ element: AXUIElement, operation: () throws -> (AXError, Value)
    ) throws -> (AXError, Value?) {
        let started = mach_absolute_time()
        return try HomeAXProtocol.read(
            before: { attempt in
                try self.checkDeadline()
                if attempt > 1 {
                    Thread.sleep(forTimeInterval: 0.025)
                    try self.validateTarget()
                }
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success, pid == self.identity.pid else {
                    throw Failure(reason: "AX read element differs from exact Demo PID")
                }
                let code = AXUIElementSetMessagingTimeout(element, 0.5)
                guard code == .success else {
                    self.evidence["messagingTimeoutError"] = code.rawValue
                    throw Failure(reason: "AX messaging timeout setup failed")
                }
                try self.checkDeadline()
            }, operation: operation,
            observed: { attempt, code in
                if code != .success || attempt > 1 {
                    let receipt: [String: Any] = [
                        "attempt": attempt, "code": code.rawValue, "startedMachTime": started,
                        "observedMachTime": mach_absolute_time(),
                        "rpc": self.evidence["activeAXRPC"] as Any? ?? NSNull(),
                        "traversal": self.evidence["externalTraversal"] as Any? ?? NSNull(),
                        "attributeResult": self.evidence["lastAXRPC"] as Any? ?? NSNull(),
                        "countResult": self.evidence["lastChildCountRPC"] as Any? ?? NSNull(),
                        "pageResult": self.evidence["lastChildPageRPC"] as Any? ?? NSNull(),
                    ]
                    var history = self.evidence["readRPCRecovery"] as? [[String: Any]] ?? []
                    if history.count < 64 { history.append(receipt) }
                    self.evidence["readRPCRecovery"] = history
                    self.evidence["lastReadRPCRecovery"] = receipt
                }
                try self.checkDeadline()
            })
    }

    func attribute(_ element: AXUIElement, _ name: String, requireComplete: Bool = false) throws -> CFTypeRef? {
        evidence["activeAXRPC"] = ["operation": "attribute", "attribute": name]
        try checkDeadline()
        let (result, returned) = try readRPC(element) {
            var value: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            self.evidence["lastAXRPC"] = [
                "attribute": name, "code": code.rawValue, "typeID": value.map { CFGetTypeID($0) } as Any? ?? NSNull(),
            ]
            if code != .success { self.attributeErrors["\(name):\(code.rawValue)", default: 0] += 1 }
            return (code, value)
        }
        let value = returned ?? nil
        if result != .success {
            if result == .apiDisabled { throw Failure(reason: "Accessibility access unavailable") }
            if requireComplete, result != .attributeUnsupported, result != .noValue {
                throw Failure(reason: "incomplete target traversal attribute: \(name):\(result.rawValue)")
            }
        }
        try checkDeadline()
        return result == .success ? value : nil
    }

    func frame(_ element: AXUIElement, requireComplete: Bool = false) throws -> CGRect? {
        guard let point = try attribute(element, kAXPositionAttribute, requireComplete: requireComplete),
            CFGetTypeID(point) == AXValueGetTypeID(),
            let size = try attribute(element, kAXSizeAttribute, requireComplete: requireComplete),
            CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(point, to: AXValue.self), .cgPoint, &position),
            AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions),
            position.x.isFinite, position.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite
        else { return nil }
        return CGRect(origin: position, size: dimensions)
    }

    struct AXNode: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    func discover(_ window: AXUIElement) throws -> AXUIElement? {
        let attempt = (evidence["discoveryAttempts"] as? Int ?? 0) + 1
        evidence["discoveryAttempts"] = attempt
        for key in [
            "exactLabelObservation", "lastVisitedNode", "lastTraversalOwner", "lastChildCountRPC", "lastChildPageRPC",
            "lastAXRPC",
        ] {
            evidence.removeValue(forKey: key)
        }
        var samples: [[String: Any]] = []
        var history: [[String: Any]] = []
        var complete = false
        var current: [String: Any] = ["phase": "window-frame", "attempt": attempt, "complete": false]
        evidence["externalTraversal"] = current
        defer {
            current["complete"] = complete
            current["samples"] = samples
            current["history"] = history
            evidence["externalTraversal"] = current
            evidence["attributeErrors"] = attributeErrors
        }
        guard let windowFrame = try frame(window, requireComplete: true), !windowFrame.isEmpty else {
            throw Failure(reason: "owned window frame unavailable")
        }
        let target = try HomeAXProtocol.traverse(
            root: AXNode(element: window), limit: measurement ? 10_000 : 1_500,
            visit: { node, path in
                var owner: pid_t = 0
                let ownerCode = AXUIElementGetPid(node.element, &owner)
                self.evidence["lastTraversalOwner"] = ["path": path, "code": ownerCode.rawValue, "pid": owner]
                try self.checkDeadline()
                guard ownerCode == .success, owner == self.identity.pid else {
                    throw Failure(reason: "AX descendant differs from exact Demo PID")
                }
                let roleValue = try self.attribute(node.element, kAXRoleAttribute, requireComplete: true)
                guard let role = roleValue as? String else {
                    throw Failure(reason: "AX node role unavailable or malformed")
                }
                var sample: [String: Any] = ["role": role, "path": path]
                self.evidence["lastVisitedNode"] = sample
                // Only buttons can be the exact detail target. Other roles still enumerate all children.
                if role == kAXButtonRole as String {
                    let title =
                        try HomeAXProtocol.windowString(
                            self.attribute(node.element, kAXTitleAttribute, requireComplete: true)) ?? ""
                    let label =
                        try HomeAXProtocol.windowString(
                            self.attribute(node.element, kAXDescriptionAttribute, requireComplete: true)) ?? ""
                    sample["title"] = title
                    sample["label"] = label
                    self.evidence["lastVisitedNode"] = sample
                    if title == "Synthetic album 0-0" || label == "Synthetic album 0-0" {
                        let enabled = try HomeAXProtocol.enabled(
                            self.attribute(node.element, kAXEnabledAttribute, requireComplete: true))
                        guard let bounds = try self.frame(node.element, requireComplete: true),
                            HomeAXProtocol.validFrame(bounds)
                        else { throw Failure(reason: "exact-label target state or geometry unavailable") }
                        sample["enabled"] = enabled
                        sample["frame"] = NSStringFromRect(bounds)
                        self.evidence["lastVisitedNode"] = sample
                        self.evidence["exactLabelObservation"] = sample.merging(
                            ["intersectsOwnedWindow": bounds.intersects(windowFrame)],
                            uniquingKeysWith: { _, value in value })
                        if samples.count < 64 { samples.append(sample) }
                        return HomeAXProtocol.isDetailTarget(
                            role: role, title: title, label: label, enabled: enabled, frame: bounds, window: windowFrame
                        )
                    }
                }
                if samples.count < 64 { samples.append(sample) }
                return false
            },
            count: { node, _ in
                var count = 0
                self.evidence["activeAXRPC"] = ["operation": "child-count", "attribute": kAXChildrenAttribute]
                try self.checkDeadline()
                let (code, returned) = try self.readRPC(node.element) {
                    var count = 0
                    let code = AXUIElementGetAttributeValueCount(node.element, kAXChildrenAttribute as CFString, &count)
                    self.evidence["lastChildCountRPC"] = ["code": code.rawValue, "count": count]
                    return (code, count)
                }
                count = returned ?? 0
                try self.checkDeadline()
                if code == .attributeUnsupported || code == .noValue { return 0 }
                guard code == .success else { throw Failure(reason: "AX child-count RPC failed: \(code.rawValue)") }
                return count
            },
            page: { node, _, offset, requested in
                self.evidence["activeAXRPC"] = [
                    "operation": "child-page", "attribute": kAXChildrenAttribute,
                    "offset": offset, "requested": requested,
                ]
                try self.checkDeadline()
                let (code, returned) = try self.readRPC(node.element) {
                    var value: CFArray?
                    let code = AXUIElementCopyAttributeValues(
                        node.element, kAXChildrenAttribute as CFString, offset, requested, &value)
                    self.evidence["lastChildPageRPC"] = [
                        "code": code.rawValue, "offset": offset, "requested": requested,
                        "returnedCount": value.map(CFArrayGetCount) as Any? ?? NSNull(),
                        "returnedTypeID": value.map { CFGetTypeID($0) } as Any? ?? NSNull(),
                    ]
                    return (code, value)
                }
                let value = returned ?? nil
                try self.checkDeadline()
                guard code == .success else {
                    throw Failure(reason: "AX child page failed or has malformed members")
                }
                return try HomeAXProtocol.childPage(value, requested: requested).map { AXNode(element: $0) }
            },
            progress: { observation in
                current = [
                    "phase": observation.phase, "attempt": attempt, "path": observation.path,
                    "depth": observation.depth,
                    "pathTruncated": observation.depth > observation.path.count,
                    "inspectedElements": observation.inspected, "returnedEdges": observation.edges,
                    "revisitedElements": observation.revisited, "matches": observation.matches,
                    "childCount": observation.childCount as Any? ?? NSNull(),
                    "offset": observation.offset as Any? ?? NSNull(),
                    "requested": observation.requested as Any? ?? NSNull(), "complete": false,
                ]
                if history.count < 64 { history.append(current) }
                self.evidence["externalTraversal"] = current
                try self.checkDeadline()
            })
        complete = true
        return target?.element
    }

    func awaitOwnedWindow(_ application: AXUIElement) throws -> AXUIElement {
        var queries = evidence["windowQueries"] as? [[String: Any]] ?? []
        var attempts = evidence["windowQueryAttempts"] as? Int ?? 0
        while true {
            try checkDeadline()
            guard let pulse = try publicationPulse() else {
                evidence["windowAdmissionPhase"] = "passively waiting for a fresh Home publication pulse"
                Thread.sleep(forTimeInterval: 0.025)
                continue
            }
            let home = pulse["homeProbe"] as? [String: Any]
            guard
                try HomeAXProtocol.mayQueryWindows(
                    sectionCount: home?["sectionCount"] as? Int, expectedSections: sections,
                    onHome: home?["onHome"] as? Bool == true, populatedAlready: homePublicationAdmitted)
            else {
                evidence["windowAdmissionPhase"] = "waiting for exact Home sections before AX window query"
                Thread.sleep(forTimeInterval: 0.025)
                continue
            }
            homePublicationAdmitted = true
            try validateTarget()
            evidence["windowAdmissionPhase"] = "querying owned public AX windows after Home publication"
            AXUIElementSetMessagingTimeout(application, 0.5)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
            if result != .success {
                attributeErrors["\(kAXWindowsAttribute):\(result.rawValue)", default: 0] += 1
            }
            let windows = value as? [AXUIElement]
            attempts += 1
            let sample: [String: Any] = [
                "observedMachTime": mach_absolute_time(), "apiResultCode": result.rawValue,
                "returnedTypeID": value.map { CFGetTypeID($0) } as Any? ?? NSNull(),
                "arrayValue": windows != nil, "windowCount": windows?.count as Any? ?? NSNull(),
                "publishedSectionCount": home?["sectionCount"] as Any? ?? NSNull(),
            ]
            if queries.count < 64 { queries.append(sample) }
            evidence["windowQueries"] = queries
            evidence["lastWindowQuery"] = sample
            evidence["windowQueryAttempts"] = attempts
            try checkDeadline()
            let disposition = try HomeAXProtocol.WindowQuery(
                resultCode: result.rawValue, arrayValue: windows != nil, windowCount: windows?.count
            ).disposition(measuredIdentity: measuredWindow != nil)
            if disposition == .pending {
                Thread.sleep(forTimeInterval: 0.025)
                continue
            }
            var windowSamples: [[String: Any]] = []
            var candidates: [HomeAXProtocol.WindowCandidate] = []
            for window in windows ?? [] {
                var owner: pid_t = 0
                let ownerResult = AXUIElementGetPid(window, &owner)
                guard ownerResult == .success, owner == identity.pid else {
                    throw Failure(reason: "AX window inventory owner differs from exact Demo PID")
                }
                let roleValue = try attribute(window, kAXRoleAttribute)
                let markerValue = try attribute(window, kAXIdentifierAttribute)
                evidence["lastWindowAttributeTypes"] = [
                    "role": roleValue.map { CFGetTypeID($0) } as Any? ?? NSNull(),
                    "identifier": markerValue.map { CFGetTypeID($0) } as Any? ?? NSNull(),
                    "ownerPID": owner,
                ]
                let role = try HomeAXProtocol.windowString(roleValue)
                let marker = try HomeAXProtocol.windowString(markerValue)
                let geometry = try frame(window)
                windowSamples.append([
                    "ownerResultCode": ownerResult.rawValue, "ownerPID": owner,
                    "role": role as Any? ?? NSNull(), "identifier": marker as Any? ?? NSNull(),
                    "frame": geometry.map(NSStringFromRect) as Any? ?? NSNull(),
                ])
                evidence["lastWindowPublicSamples"] = windowSamples
                candidates.append(.init(pid: owner, role: role, identifier: marker, frame: geometry))
            }
            var selected: Int?
            if disposition == .ready {
                if let measuredWindow {
                    selected = try HomeAXProtocol.measuredWindowIndex(in: candidates, identity: measuredWindow)
                } else {
                    selected = 0
                }
            }
            if let selected, let windows {
                try validateTarget()
                evidence["windowAdmissionPhase"] =
                    measuredWindow == nil
                    ? "unique exact-PID window admitted" : "unique run-and-nonce marked captured window admitted"
                return windows[selected]
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    func run() throws {
        try validateTarget()
        guard (try safety()["homeProbe"] as? [String: Any])?["onHome"] as? Bool == true else {
            throw Failure(reason: "owned Demo is not on Home")
        }
        for name in [
            "home-ax-request.json", "home-ax-armed.json", "home-ax-external.json",
            "home-ax-observed.json", "home-presented-measurement.json", "home-presented-measurement.failure.json",
            "home-measurement-accepted.json",
        ] {
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else {
                throw Failure(reason: "prior attempt evidence exists")
            }
        }
        var base = mach_timebase_info_data_t()
        guard mach_timebase_info(&base) == KERN_SUCCESS, base.numer > 0, base.denom > 0 else {
            throw Failure(reason: "Mach timebase unavailable")
        }
        let started = mach_absolute_time()
        deadlineMachTime = started + UInt64(10e9 * Double(base.denom) / Double(base.numer))
        evidence["startedMachTime"] = started
        evidence["deadlineMachTime"] = deadlineMachTime
        let request = HomeAXProtocol.Request(
            runID: identity.runID, pid: identity.pid, nonce: nonce,
            startedMachTime: started, deadlineMachTime: deadlineMachTime)
        try HomeAXProtocol.publish(
            JSONEncoder().encode(request), to: root.appendingPathComponent("home-ax-request.json"))
        let armedPath = root.appendingPathComponent("home-ax-armed.json")
        while !FileManager.default.fileExists(atPath: armedPath.path) {
            try checkDeadline()
            Thread.sleep(forTimeInterval: 0.025)
        }
        let armed = try json(armedPath)
        guard armed["externalRequestNonce"] as? String == nonce,
            armed["sourceSHA256"] as? String == expectedSource, armed["connected"] as? Bool == true
        else { throw Failure(reason: "app handshake mismatch") }
        evidence["internalTraversal"] = armed["accessibility"]
        if measurement {
            guard let binding = armed["measuredWindow"] else { throw Failure(reason: "measured window binding absent") }
            let decoded = try JSONDecoder().decode(
                HomeAXProtocol.MeasuredWindow.self, from: JSONSerialization.data(withJSONObject: binding))
            try decoded.validate(runID: identity.runID, nonce: nonce, pid: identity.pid)
            measuredWindow = decoded
            evidence["measuredWindow"] = binding
        }
        let application = AXUIElementCreateApplication(identity.pid)
        let window = try awaitOwnedWindow(application)
        var target: AXUIElement?
        repeat {
            let pulse = try safety()
            if (pulse["homeProbe"] as? [String: Any])?["sectionCount"] as? Int == sections {
                target = try discover(window)
            }
            if target == nil { Thread.sleep(forTimeInterval: 0.025) }
        } while target == nil && mach_absolute_time() < deadlineMachTime
        guard var target else { throw Failure(reason: "exact visible Home target unavailable") }
        try validateTarget()
        guard (try safety()["homeProbe"] as? [String: Any])?["onHome"] as? Bool == true else {
            throw Failure(reason: "Home changed before action")
        }
        var actions: CFArray?
        let actionResult = AXUIElementCopyActionNames(target, &actions)
        evidence["targetActionsResult"] = actionResult.rawValue
        evidence["targetActions"] = actions as? [String] ?? []
        guard actionResult == .success,
            (actions as? [String])?.contains(kAXPressAction) == true
        else { throw Failure(reason: "exact target has no public Press action") }
        evidence["discoveredMachTime"] = mach_absolute_time()
        if measurement {
            try HomeAXProtocol.publish(
                JSONEncoder().encode(HomeAXProtocol.Observation(nonce: nonce, observedMachTime: mach_absolute_time())),
                to: root.appendingPathComponent("home-ax-observed.json"))
            let measuredPath = root.appendingPathComponent("home-presented-measurement.json")
            while !FileManager.default.fileExists(atPath: measuredPath.path) {
                try checkDeadline()
                let pulse = try safety()
                guard (pulse["homeProbe"] as? [String: Any])?["onHome"] as? Bool == true,
                    !FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("home-presented-measurement.failure.json").path)
                else { throw Failure(reason: "Home measurement failed or navigated before capture finished") }
                Thread.sleep(forTimeInterval: 0.025)
            }
            let measured = try json(measuredPath)
            guard measured["externalRequestNonce"] as? String == nonce,
                measured["sourceSHA256"] as? String == expectedSource,
                measured["measuredBeforeNavigation"] as? Bool == true
            else { throw Failure(reason: "pre-navigation Home measurement receipt mismatch") }
            try validateTarget()
            guard (try safety()["homeProbe"] as? [String: Any])?["onHome"] as? Bool == true else {
                throw Failure(reason: "Home changed after measurement")
            }
            let freshWindow = try awaitOwnedWindow(application)
            guard let freshTarget = try discover(freshWindow) else {
                throw Failure(reason: "exact visible enabled unique target unavailable after measurement")
            }
            target = freshTarget
            var freshActions: CFArray?
            let freshActionResult = AXUIElementCopyActionNames(target, &freshActions)
            evidence["postMeasurementTargetActionsResult"] = freshActionResult.rawValue
            evidence["postMeasurementTargetActions"] = freshActions as? [String] ?? []
            try checkDeadline()
            guard freshActionResult == .success, (freshActions as? [String])?.contains(kAXPressAction) == true else {
                throw Failure(reason: "fresh exact target has no public Press action")
            }
            evidence["homeMeasurementCompletedBeforeActivation"] = true
        }
        evidence["activationAttempted"] = true
        try checkDeadline()
        let pressed = AXUIElementPerformAction(target, kAXPressAction as CFString)
        evidence["activationResult"] = pressed.rawValue
        guard pressed == .success else { throw Failure(reason: "public Press failed") }
        while true {
            try checkDeadline()
            let status = try safety()
            if (status["homeProbe"] as? [String: Any])?["exactDetailSelected"] as? Bool == true { break }
            Thread.sleep(forTimeInterval: 0.025)
        }
        try validateTarget()
        if measurement {
            let acceptedPath = root.appendingPathComponent("home-measurement-accepted.json")
            while !FileManager.default.fileExists(atPath: acceptedPath.path) {
                try checkDeadline()
                _ = try safety()
                Thread.sleep(forTimeInterval: 0.025)
            }
            let accepted = try json(acceptedPath)
            guard accepted["externalRequestNonce"] as? String == nonce,
                accepted["selectionConfirmed"] as? Bool == true
            else { throw Failure(reason: "app functional confirmation mismatch") }
        }
        try checkDeadline()
        let finalPulse = try safety()
        guard (finalPulse["homeProbe"] as? [String: Any])?["sectionCount"] as? Int == sections,
            (finalPulse["homeProbe"] as? [String: Any])?["exactDetailSelected"] as? Bool == true
        else { throw Failure(reason: "final exact-section functional safety confirmation unavailable") }
        evidence["selectionObservedMachTime"] = mach_absolute_time()
        evidence["passed"] = true
    }

    func save(error: Error? = nil) throws {
        if let error { evidence["passed"] = false; evidence["error"] = String(describing: error) }
        evidence["attributeErrors"] = attributeErrors
        try HomeAXProtocol.publish(
            JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
            to: root.appendingPathComponent("home-ax-external.json"))
    }
}

@main
private struct HomeAXMain {
    @MainActor static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--preflight"] {
            print(AXIsProcessTrusted() ? "Existing Accessibility access available" : "Accessibility access unavailable")
            exit(AXIsProcessTrusted() ? 0 : 1)
        }
        guard CommandLine.arguments.count == 5 else {
            print("Usage: synthetic-home-ax RUN_ROOT EXPECTED_HEAD EXPECTED_SOURCE_SHA256 EXPECTED_SIGNED_EXE_SHA256")
            exit(2)
        }
        var diagnostic: HomeAXDiagnostic?
        do {
            let run = try HomeAXDiagnostic(
                root: URL(fileURLWithPath: CommandLine.arguments[1]), head: CommandLine.arguments[2],
                source: CommandLine.arguments[3], executable: CommandLine.arguments[4])
            diagnostic = run
            try run.run()
            try run.save()
        } catch {
            do { try diagnostic?.save(error: error) } catch {
                FileHandle.standardError.write(Data("Home AX evidence write failed: \(error)\n".utf8))
            }
            FileHandle.standardError.write(Data("Home AX diagnostic failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
