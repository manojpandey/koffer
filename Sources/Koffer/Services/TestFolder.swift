import AppKit
import Foundation

/// Creates the small, safe "Koffer Test" folder the first time the app runs.
enum TestFolder {
    static func createIfMissing(at path: String) {
        let fm: FileManager = FileManager.default
        if fm.fileExists(atPath: path) { return }
        let root: URL = URL(fileURLWithPath: path)
        let notes: URL = root.appendingPathComponent("notes")
        let pictures: URL = root.appendingPathComponent("pictures")
        do {
            try fm.createDirectory(at: notes, withIntermediateDirectories: true)
            try fm.createDirectory(at: pictures, withIntermediateDirectories: true)
        } catch {
            return
        }

        let readme: String = """
        This is Koffer's safe test folder. \
        Nothing in here matters, so feel free to add, rename or delete files. \
        Then press "Back up now" in Koffer to see exactly what it does.

        """
        write(readme, to: root.appendingPathComponent("README.txt"))
        write("Shopping list\n- bread\n- oranges\n- something nice for tea\n",
              to: notes.appendingPathComponent("shopping list.txt"))
        write("Ideas\nTry renaming this file, then back up again.\nKoffer should notice it moved.\n",
              to: notes.appendingPathComponent("ideas.txt"))

        let palettes: [(String, (UInt8, UInt8, UInt8), (UInt8, UInt8, UInt8))] = [
            ("sunrise.png", (255, 183, 94), (237, 80, 120)),
            ("ocean.png", (64, 196, 255), (20, 60, 160)),
            ("meadow.png", (190, 235, 120), (30, 130, 90))
        ]
        for entry in palettes {
            if let data = gradientPNG(from: entry.1, to: entry.2, size: 256) {
                try? data.write(to: pictures.appendingPathComponent(entry.0))
            }
        }
    }

    private static func write(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A size x size diagonal gradient, written straight into RGBA pixels.
    private static func gradientPNG(from a: (UInt8, UInt8, UInt8), to b: (UInt8, UInt8, UInt8), size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        guard let pixels = rep.bitmapData else { return nil }
        let rowBytes: Int = rep.bytesPerRow
        let denom: Double = Double(2 * (size - 1))
        for y in 0..<size {
            for x in 0..<size {
                let t: Double = Double(x + y) / denom
                let offset: Int = y * rowBytes + x * 4
                pixels[offset] = mix(a.0, b.0, t)
                pixels[offset + 1] = mix(a.1, b.1, t)
                pixels[offset + 2] = mix(a.2, b.2, t)
                pixels[offset + 3] = 255
            }
        }
        return rep.representation(using: .png, properties: [:])
    }

    private static func mix(_ from: UInt8, _ to: UInt8, _ t: Double) -> UInt8 {
        let v: Double = Double(from) + (Double(to) - Double(from)) * t
        return UInt8(max(0, min(255, v.rounded())))
    }
}
