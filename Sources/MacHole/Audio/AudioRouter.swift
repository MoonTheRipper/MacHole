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
    let processObjectIDs: [AudioObjectID]
    let deviceUID: String

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.moontheripper.machole.route")

    init(processes: [AudioObjectID], deviceUID: String) {
        self.processObjectIDs = processes
        self.deviceUID = deviceUID
    }

    /// Creates the tap + aggregate and starts forwarding audio.
    func start() throws {
        guard !processObjectIDs.isEmpty else {
            throw CA.Error(status: kAudio_ParamError, action: "create process tap (no audio processes)")
        }

        // 1. Tap the app's audio process(es). `mutedWhenTapped` silences them on
        //    their original device only while we are actively redirecting.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
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

        CA.log.info("Route started: \(self.processObjectIDs.count) process(es) -> \(self.deviceUID, privacy: .public)")
    }

    /// Forwards tapped audio into the output device's buffers.
    ///
    /// When both sides are a single interleaved buffer but have different channel
    /// counts (e.g. a stereo tap feeding a multi-channel audio interface), we map
    /// sample-by-sample so the audio lands on the right channels instead of being
    /// byte-copied out of alignment. Matching formats take the plain byte-copy
    /// path, so the common stereo→stereo case is unchanged.
    private static func forward(
        input: UnsafePointer<AudioBufferList>,
        to output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        if inList.count == 1, outList.count == 1,
           inList[0].mNumberChannels != outList[0].mNumberChannels,
           inList[0].mNumberChannels > 0, outList[0].mNumberChannels > 0,
           let src = inList[0].mData, let dst = outList[0].mData {
            let inCh = Int(inList[0].mNumberChannels)
            let outCh = Int(outList[0].mNumberChannels)
            let bytesPerSample = MemoryLayout<Float>.size // Core Audio taps deliver 32-bit float
            let inFrames = Int(inList[0].mDataByteSize) / (bytesPerSample * inCh)
            let outFrames = Int(outList[0].mDataByteSize) / (bytesPerSample * outCh)
            let frames = min(inFrames, outFrames)
            if frames > 0 {
                let srcF = src.assumingMemoryBound(to: Float.self)
                let dstF = dst.assumingMemoryBound(to: Float.self)
                let copyCh = min(inCh, outCh)
                memset(dst, 0, Int(outList[0].mDataByteSize))
                for frame in 0..<frames {
                    for channel in 0..<copyCh {
                        dstF[frame * outCh + channel] = srcF[frame * inCh + channel]
                    }
                }
                return
            }
        }

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
        CA.log.info("Route stopped: \(self.processObjectIDs.count) process(es)")
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
        let route = AudioRoute(processes: process.audioObjectIDs, deviceUID: deviceUID)
        do {
            try route.start()
            routes[process.routingKey] = route
            return nil
        } catch {
            CA.log.error("Failed to route \(process.displayName, privacy: .public): \(String(describing: error))")
            return friendlyMessage(for: error, app: process.displayName)
        }
    }

    /// Turns a raw Core Audio failure into something a person can act on.
    private func friendlyMessage(for error: Error, app: String) -> String {
        let detail = String(describing: error)
        if detail.contains("process tap") {
            return "Couldn’t capture \(app)’s audio. If this keeps happening, allow MacHole under System Settings ▸ Privacy & Security ▸ Microphone, then try again."
        }
        if detail.contains("aggregate") || detail.contains("start") {
            return "Couldn’t send \(app) to that device. It may be in use or disconnected — pick another device or reconnect it."
        }
        return "Couldn’t route \(app). \(detail)"
    }

    /// Stops any active route whose destination device is no longer present
    /// (e.g. an interface was unplugged). The assignment is kept so the route is
    /// restored automatically when the device comes back.
    func dropRoutes(whereDeviceMissing existingUIDs: Set<String>) {
        let dead = routes.filter { !existingUIDs.contains($0.value.deviceUID) }.map(\.key)
        for key in dead {
            routes[key]?.stop()
            routes.removeValue(forKey: key)
            CA.log.info("Dropped route for missing device, key=\(key, privacy: .public)")
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
