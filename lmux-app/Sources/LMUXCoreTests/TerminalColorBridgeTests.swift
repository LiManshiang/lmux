import XCTest
@testable import LMUXCore

final class TerminalColorBridgeTests: XCTestCase {
    func testHexComponentClamps() {
        XCTAssertEqual(TerminalColorBridge.hexComponent(0.0), "00")
        XCTAssertEqual(TerminalColorBridge.hexComponent(1.0), "FF")
        XCTAssertEqual(TerminalColorBridge.hexComponent(0.5), "80")
        // Out-of-range values clamp to 0...255.
        XCTAssertEqual(TerminalColorBridge.hexComponent(-0.5), "00")
        XCTAssertEqual(TerminalColorBridge.hexComponent(1.5), "FF")
    }

    func testDoubleTupleHex() {
        XCTAssertEqual(TerminalColorBridge.hex((0.0, 0.0, 0.0)), "#000000")
        XCTAssertEqual(TerminalColorBridge.hex((1.0, 0.0, 0.0)), "#FF0000")
        XCTAssertEqual(TerminalColorBridge.hex((0.0, 1.0, 0.0)), "#00FF00")
        XCTAssertEqual(TerminalColorBridge.hex((0.0, 0.0, 1.0)), "#0000FF")
        XCTAssertEqual(TerminalColorBridge.hex((1.0, 1.0, 1.0)), "#FFFFFF")
    }

    func testUInt16TupleHex() {
        // UInt16 values are 0...65535; the high byte is the 8-bit channel.
        XCTAssertEqual(TerminalColorBridge.hex((0xFFFF as UInt16, 0x0000 as UInt16, 0x0000 as UInt16)), "#FF0000")
        XCTAssertEqual(TerminalColorBridge.hex((0x0000 as UInt16, 0xFFFF as UInt16, 0x0000 as UInt16)), "#00FF00")
        XCTAssertEqual(TerminalColorBridge.hex((0x0000 as UInt16, 0x0000 as UInt16, 0xFFFF as UInt16)), "#0000FF")
        XCTAssertEqual(TerminalColorBridge.hex((0xAAAA as UInt16, 0xBBBB as UInt16, 0xCCCC as UInt16)), "#AABBCC")
        XCTAssertEqual(TerminalColorBridge.hex((0x0000 as UInt16, 0x0000 as UInt16, 0x0000 as UInt16)), "#000000")
    }

    func testDraculaPaletteRoundTrip() {
        // Dracula's ansi[1] = (0xFF55, 0x5555, 0x5555) -> #FF5555 (red).
        let red: (UInt16, UInt16, UInt16) = (0xFF55, 0x5555, 0x5555)
        XCTAssertEqual(TerminalColorBridge.hex(red), "#FF5555")
        // ansi[4] = blue-ish: high bytes 0xBD, 0xF9, 0x93 -> #BDF993.
        let blue: (UInt16, UInt16, UInt16) = (0xBD93, 0xF9BD, 0x93F9)
        XCTAssertEqual(TerminalColorBridge.hex(blue), "#BDF993")
    }
}
