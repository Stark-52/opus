import XCTest
import AppKit
@testable import Opus

final class OpusThemeTests: XCTestCase {
    private func components(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

    func testContextColorThresholds() {
        // Nominal jusqu'à 70 % inclus, ambre jusqu'à 85 % inclus, rouge au-delà.
        XCTAssertEqual(components(OpusTheme.contextColor(fraction: 0.0)).1,
                       components(OpusTheme.cyan).1, accuracy: 0.001)
        XCTAssertEqual(components(OpusTheme.contextColor(fraction: 0.70)).1,
                       components(OpusTheme.cyan).1, accuracy: 0.001)
        XCTAssertEqual(components(OpusTheme.contextColor(fraction: 0.71)).1,
                       components(OpusTheme.amber).1, accuracy: 0.001)
        XCTAssertEqual(components(OpusTheme.contextColor(fraction: 0.85)).1,
                       components(OpusTheme.amber).1, accuracy: 0.001)
        XCTAssertEqual(components(OpusTheme.contextColor(fraction: 0.86)).1,
                       components(OpusTheme.red).1, accuracy: 0.001)
        XCTAssertEqual(components(OpusTheme.contextColor(fraction: 2.0)).1,
                       components(OpusTheme.red).1, accuracy: 0.001)
    }

    func testCreamAlphaHelper() {
        XCTAssertEqual(OpusTheme.cream(0.55).alphaComponent, 0.55, accuracy: 0.001)
        XCTAssertEqual(OpusTheme.cream(1.0).alphaComponent, 1.0, accuracy: 0.001)
    }

    func testMetricsAreTheSpecValues() {
        XCTAssertEqual(OpusTheme.radiusPanel, 14)
        XCTAssertEqual(OpusTheme.radiusControl, 8)
        XCTAssertEqual(OpusTheme.insetPanel, 14)
        XCTAssertEqual(OpusTheme.controlGap, 6)
        XCTAssertEqual(OpusTheme.railHeight, 3)
        XCTAssertEqual(OpusTheme.dotSize, 6)
    }

    func testActivityColorMapping() {
        // .working → cyan
        XCTAssertEqual(components(OpusTheme.activityColor(.working)!).0,
                       components(OpusTheme.cyan).0, accuracy: 0.001)
        // .needsInput → red
        XCTAssertEqual(components(OpusTheme.activityColor(.needsInput)!).0,
                       components(OpusTheme.red).0, accuracy: 0.001)
        // .done → green
        XCTAssertEqual(components(OpusTheme.activityColor(.done)!).0,
                       components(OpusTheme.green).0, accuracy: 0.001)
        // .idle → nil
        XCTAssertNil(OpusTheme.activityColor(.idle))
    }
}
