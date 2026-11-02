import Foundation
import DisplayCore
import DisplayNative

struct DesktopMode: Codable, Identifiable, Hashable {
    let id: UInt32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isCurrent: Bool
    var label: String {
        "\(width) × \(height) · \(String(format: "%.0f", refreshRate)) Hz" +
        (pixelWidth > width ? " · HiDPI" : "")
    }
}

struct DisplaySnapshot: Decodable, Identifiable {
    let id: UInt32
    let uuid: String
    let name: String
    let vendorID: UInt32?
    let productID: UInt32?
    let builtIn: Bool
    let isMain: Bool
    let connectionModes: [ConnectionMode]
    let currentConnection: ConnectionMode?
    let desktopModes: [DesktopMode]
    let brightness: Double?
    let error: String?
    var currentDesktop: DesktopMode? { desktopModes.first(where: \.isCurrent) }
}

struct NativeSnapshot: Decodable {
    let displays: [DisplaySnapshot]
    let error: String?
}

struct ExtraSnapshot: Decodable {
    var hdrSupported: Bool = false
    var hdrEnabled: Bool = false
    var rotation: Int = 0
    var profileName: String?
    var rotationSupported: Bool = false
    var controlsError: String?
}

struct SavedConfiguration: Codable {
    var version = 1
    var policies: [String: DisplayPolicy] = [:]
    var paused = false
    var pendingChange: PendingChange?
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
}

struct PendingChange: Codable {
    enum Phase: String, Codable { case awaitingConfirmation, reverting }
    let displayUUID: String
    let displayName: String
    let previousConnection: ModeTarget?
    let previousDesktop: DesktopMode?
    let previousRotation: Int?
    let previousHDR: Bool?
    let expectedConnection: ModeTarget?
    let expectedDesktop: DesktopMode?
    let expectedRotation: Int?
    let expectedHDR: Bool?
    let expires: Date
    var phase: Phase = .awaitingConfirmation
    var recoveryAttempts = 0
}

enum NativeFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

func nativeResult(_ result: UnsafeMutablePointer<CChar>?) throws {
    if let result {
        defer { DKFree(result) }
        throw NativeFailure.message(String(cString: result))
    }
}

func nativeJSON<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: T.Type) throws -> T {
    guard let pointer else { throw NativeFailure.message("The display service returned no data.") }
    defer { DKFree(pointer) }
    return try JSONDecoder().decode(type, from: Data(String(cString: pointer).utf8))
}
