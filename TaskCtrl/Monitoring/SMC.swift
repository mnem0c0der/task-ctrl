import Foundation
import IOKit

/// Reads values from the System Management Controller: total power draw,
/// fan speeds and the like. Read-only; nothing here writes to the SMC.
final class SMC {
    // Mirrors the kernel's SMCParamStruct; the layout must stay 80 bytes.
    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct Param {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let handleEvent: UInt32 = 2
    private static let readKeyCommand: UInt8 = 5
    private static let keyInfoCommand: UInt8 = 9
    private static let floatType = fourCC("flt ")

    private var connection: io_connect_t = 0

    init?() {
        guard MemoryLayout<Param>.size == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Value of a four-character key holding a float, e.g. "PSTR". Nil when
    /// this Mac has no such key or stores it in another format.
    func float(_ key: String) -> Double? {
        var query = Param()
        query.key = Self.fourCC(key)
        query.command = Self.keyInfoCommand
        guard let info = call(&query),
              info.keyInfo.dataType == Self.floatType,
              info.keyInfo.dataSize == 4
        else { return nil }

        var read = Param()
        read.key = query.key
        read.keyInfo.dataSize = info.keyInfo.dataSize
        read.command = Self.readKeyCommand
        guard let value = call(&read) else { return nil }
        let number = withUnsafeBytes(of: value.bytes) { $0.loadUnaligned(as: Float.self) }
        return number.isFinite ? Double(number) : nil
    }

    private func call(_ input: inout Param) -> Param? {
        var output = Param()
        var size = MemoryLayout<Param>.size
        let result = IOConnectCallStructMethod(
            connection, Self.handleEvent, &input, MemoryLayout<Param>.size, &output, &size
        )
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private static func fourCC(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
