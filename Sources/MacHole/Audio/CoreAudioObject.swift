import CoreAudio
import Foundation
import os.log

/// Lightweight, type-safe helpers around the Core Audio HAL property API.
///
/// The HAL is a C API built around `AudioObjectGetPropertyData`. These helpers
/// remove the repetitive `UnsafeMutablePointer` dance and surface readable Swift
/// values and errors instead.
enum CA {
    static let log = Logger(subsystem: "com.moontheripper.machole", category: "CoreAudio")

    /// A Core Audio error wrapped so it can be surfaced in the UI.
    struct Error: Swift.Error, CustomStringConvertible {
        let status: OSStatus
        let action: String
        var description: String {
            "\(action) failed (OSStatus \(status)\(Self.fourCC(status).map { ": \($0)" } ?? ""))"
        }

        /// Many Core Audio statuses are packed four-character codes.
        static func fourCC(_ status: OSStatus) -> String? {
            let value = UInt32(bitPattern: status)
            let bytes = [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff)
            ]
            guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
            return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
        }
    }

    // MARK: - Address helpers

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func hasProperty(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(objectID, &addr)
    }

    // MARK: - Reading scalar values

    /// Reads a fixed-size value (numbers, structs) from a Core Audio object.
    static func value<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        default defaultValue: T
    ) throws -> T {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        var result = defaultValue
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &result)
        guard status == noErr else { throw Error(status: status, action: "read property \(address.mSelector)") }
        return result
    }

    // MARK: - Reading arrays

    /// Reads a variable-length array of fixed-size elements.
    static func array<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        of type: T.Type
    ) throws -> [T] {
        var addr = address
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &dataSize)
        guard status == noErr else { throw Error(status: status, action: "size of property \(address.mSelector)") }
        let count = Int(dataSize) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let values = Array<T>(unsafeUninitializedCapacity: count) { buffer, initialized in
            var ioSize = dataSize
            status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &ioSize, buffer.baseAddress!)
            initialized = status == noErr ? count : 0
        }
        guard status == noErr else { throw Error(status: status, action: "read array property \(address.mSelector)") }
        return values
    }

    // MARK: - Reading strings

    /// Reads a `CFString`-backed property and returns it as a Swift `String`.
    static func string(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) throws -> String {
        var addr = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw)
            }
        }
        guard status == noErr else { throw Error(status: status, action: "read string property \(address.mSelector)") }
        return (cfStr as String?) ?? ""
    }

    // MARK: - Writing values

    static func setValue<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ value: T
    ) throws {
        var addr = address
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectSetPropertyData(objectID, &addr, 0, nil, size, &v)
        guard status == noErr else { throw Error(status: status, action: "write property \(address.mSelector)") }
    }

    // MARK: - System object

    static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }
}
