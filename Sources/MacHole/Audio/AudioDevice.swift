import CoreAudio
import Foundation

/// A hardware (or virtual) audio output device the user can route audio to.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    /// Whether this device exposes output channels (we only route to outputs).
    let hasOutput: Bool

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool { lhs.uid == rhs.uid }
    func hash(into hasher: inout Hasher) { hasher.combine(uid) }
}

enum AudioDevices {
    /// Returns every device on the system that can play audio out, sorted by name.
    static func allOutputDevices() -> [AudioDevice] {
        let address = CA.address(kAudioHardwarePropertyDevices)
        let ids: [AudioObjectID]
        do {
            ids = try CA.array(CA.systemObject, address, of: AudioObjectID.self)
        } catch {
            CA.log.error("Could not list devices: \(String(describing: error))")
            return []
        }

        return ids.compactMap { device(for: $0) }
            .filter { $0.hasOutput }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The system's current default output device, if any.
    static func defaultOutputDevice() -> AudioDevice? {
        let address = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        guard let id = try? CA.value(CA.systemObject, address, default: AudioObjectID(0)), id != 0 else {
            return nil
        }
        return device(for: id)
    }

    /// Builds a full `AudioDevice` from a raw object id.
    static func device(for id: AudioObjectID) -> AudioDevice? {
        let uid = (try? CA.string(id, CA.address(kAudioDevicePropertyDeviceUID))) ?? ""
        guard !uid.isEmpty else { return nil }
        let name = (try? CA.string(id, CA.address(kAudioObjectPropertyName))) ?? uid
        return AudioDevice(id: id, uid: uid, name: name, hasOutput: outputChannelCount(of: id) > 0)
    }

    /// Counts output channels by summing the output stream configuration.
    static func outputChannelCount(of device: AudioObjectID) -> Int {
        var address = CA.address(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeOutput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else {
            return 0
        }
        let listPtr = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return listPtr.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Resolves a saved device UID back to a live device (devices come and go).
    static func device(withUID uid: String) -> AudioDevice? {
        allOutputDevices().first { $0.uid == uid }
    }
}
