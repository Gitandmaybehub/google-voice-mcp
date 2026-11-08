import Foundation
import XCTest
@testable import GVoiceKit

final class DoorTests: XCTestCase {
    /// A door given as a symlink runs from the real script's folder, and a missing door means no send.
    func testDoorFollowsSymlinkAndMissingDoorIsNil() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gvoice-door-\(UUID().uuidString)")
        let real = dir.appendingPathComponent("tools/bridge/door.py")
        try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "print('{}')\n".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("send_door")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: dir) }

        let door = try XCTUnwrap(SendDoor.locate(environment: ["GVOICE_SEND_DOOR": link.path]))
        XCTAssertEqual(door.script, real.resolvingSymlinksInPath().path)
        XCTAssertNil(SendDoor.locate(environment: ["GVOICE_SEND_DOOR": dir.appendingPathComponent("missing").path]))
    }
}
