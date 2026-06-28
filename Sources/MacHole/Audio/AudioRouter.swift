import CoreAudio
import Foundation
import os.log

/// A single live redirection: one app's audio captured by a process tap and
/// played out through a private aggregate device wrapping the chosen output.
///
/// Lifetime owns three Core Audio resources that must be torn down in order:
/// the IOProc, the aggregate device, and the process tap.
@available(macOS 14.4, *)
final class AudioRoute {
    let processObjectID: AudioObjectID
    let deviceUID: String

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.moontheripper.machole.route")

    init(process: AudioObjectID, deviceUID: String) {
        self.processObjectID = process
        self.deviceUID = deviceUID
    }

    /// Creates the tap + aggregate and starts forwarding audio.
    func start() throws {
        // 1. Tap the process. `mutedWhenTapped` silences it on its original
        //    device only while we are actively redirecting it.
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "MacHole Tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != 0 else {
            throw CA.Error(status: tapStatus, action: "create process tap")
        }
        tapID = newTap

        let tapUID = try CA.string(tapID, CA.address(kAudioTapPropertyUID))

        // 2. Build a private aggregate device: the chosen output as the main
        //    sub-device, fed by our tap.
        let aggregateUID = "com.moontheripper.machole.\(UUID().uuidString)"
        let description2: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "MacHole Route",
            kAudioAggregateDeviceMainSubDeviceKey as String: deviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: deviceUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]

        var newAggregate: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(description2 as CFDictionary, &newAggregate)
        guard aggStatus == noErr, newAggregate != 0 else {
            throw CA.Error(status: aggStatus, action: "create aggregate device")
        }
        aggregateID = newAggregate

        // 3. Forward tap input straight to the device's output buffers.
        var newProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue) {
            _, inInputData, _, outOutputData, _ in
            AudioRoute.forward(input: inInputData, to: outOutputData)
        }
        guard ioStatus == noErr, let procID = newProcID else {
            throw CA.Error(status: ioStatus, action: "install IO proc")
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            throw CA.Error(status: startStatus, action: "start aggregate device")
        }

        CA.log.info("Route started: process \(self.processObjectID) -> \(self.deviceUID, privacy: .public)")
    }

    /// Copies each input buffer into the matching output buffer, clamped to the
    /// smaller byte size; any leftover output is silenced to avoid noise.
    private static func forward(
        input: UnsafePointer<AudioBufferList>,
        to output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let pairs = min(inList.count, outList.count)
        for index in 0..<pairs {
            let src = inList[index]
            var dst = outList[index]
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            let copyBytes = min(Int(src.mDataByteSize), Int(dst.mDataByteSize))
            memcpy(dstData, srcData, copyBytes)
            if Int(dst.mDataByteSize) > copyBytes {
                memset(dstData.advanced(by: copyBytes), 0, Int(dst.mDataByteSize) - copyBytes)
            }
            dst.mDataByteSize = UInt32(copyBytes)
            outList[index] = dst
        }
        // Silence any output buffers we had no input for.
        for index in pairs..<outList.count {
            let buffer = outList[index]
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }

    func stop() {
        if let procID = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        CA.log.info("Route stopped: process \(self.processObjectID)")
    }

    deinit { stop() }
}

/// Owns every active route, keyed by an app's stable routing key.
@available(macOS 14.4, *)
final class AudioRouter {
    static let shared = AudioRouter()

    private var routes: [String: AudioRoute] = [:]

    /// Whether per-app routing is supported on this OS.
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// Route (or re-route) an app to a device. Replaces any existing route.
    /// Returns nil on success, or an error message on failure.
    @discardableResult
    func route(process: AudioProcess, toDeviceUID deviceUID: String) -> String? {
        removeRoute(forKey: process.routingKey)
        let route = AudioRoute(process: process.id, deviceUID: deviceUID)
        do {
            try route.start()
            routes[process.routingKey] = route
            return nil
        } catch {
            CA.log.error("Failed to route \(process.displayName, privacy: .public): \(String(describing: error))")
            return String(describing: error)
        }
    }

    func removeRoute(forKey key: String) {
        guard let route = routes.removeValue(forKey: key) else { return }
        route.stop()
    }

    func activeDeviceUID(forKey key: String) -> String? {
        routes[key]?.deviceUID
    }

    var activeRouteKeys: Set<String> { Set(routes.keys) }

    func removeAll() {
        routes.values.forEach { $0.stop() }
        routes.removeAll()
    }
}
