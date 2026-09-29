import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: test_macos_photo_location_visual <preview.png>\n", stderr)
    exit(2)
}

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard
    let image = NSImage(contentsOf: imageURL),
    let data = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: data)
else {
    fputs("could not decode preview image\n", stderr)
    exit(2)
}

var sampledPixels = 0
var warmPixels = 0

for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
    for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            continue
        }
        sampledPixels += 1
        if color.redComponent > 0.22,
           color.redComponent > color.blueComponent * 1.18,
           color.redComponent > color.greenComponent * 1.05 {
            warmPixels += 1
        }
    }
}

let warmCoverage = sampledPixels == 0 ? 0 : Double(warmPixels) / Double(sampledPixels)
guard warmCoverage >= 0.018 else {
    fputs(
        String(format: "location photography coverage too low: %.4f (need >= 0.0180)\n", warmCoverage),
        stderr
    )
    exit(1)
}

print(String(format: "location photography coverage %.4f", warmCoverage))
