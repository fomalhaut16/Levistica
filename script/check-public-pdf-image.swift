#!/usr/bin/env swift
// Inspect only a fixed public-PDF screenshot. This is a readiness heuristic,
// not OCR, PDF validation, a zoom measurement, or a general image classifier.
import Foundation
import CoreGraphics
import ImageIO

func emit(_ value: [String: Any], status: Int32 = 0) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(status)
}

guard CommandLine.arguments.count == 2 else {
    emit(["schema": 1, "validImage": false, "paperReady": false, "reason": "argument-required"], status: 2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
      attributes.isRegularFile == true, attributes.isSymbolicLink != true,
      let size = attributes.fileSize, size > 0, size <= 10 * 1024 * 1024,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else {
    emit(["schema": 1, "validImage": false, "paperReady": false, "reason": "invalid-image"], status: 2)
}
guard (320...4096).contains(width), (240...4096).contains(height) else {
    emit(["schema": 1, "validImage": true, "paperReady": false, "reason": "ineligible-size",
          "width": width, "height": height])
}
guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    emit(["schema": 1, "validImage": false, "paperReady": false, "reason": "decode-failed"], status: 2)
}
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let result: [String: Any] = pixels.withUnsafeMutableBytes { storage in
    guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return ["schema": 1, "validImage": false, "paperReady": false, "reason": "bitmap-failed"]
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = storage.bindMemory(to: UInt8.self)
    func white(_ offset: Int) -> Bool {
        bytes[offset] >= 240 && bytes[offset + 1] >= 240 && bytes[offset + 2] >= 240 && bytes[offset + 3] >= 240
    }
    var spans: [(left: Int, right: Int, y: Int)] = []
    for y in 0..<height {
        var start = 0, longestStart = 0, longestLength = 0
        for x in 0...width {
            if x == width || !white((y * width + x) * 4) {
                if x - start > longestLength { longestStart = start; longestLength = x - start }
                start = x + 1
            }
        }
        if longestLength >= width / 2 && longestLength <= width * 98 / 100 {
            spans.append((longestStart, longestStart + longestLength, y))
        }
    }
    var output: [String: Any] = ["schema": 1, "validImage": true, "paperReady": false,
                               "width": width, "height": height, "qualifyingRows": spans.count,
                               "paperWidth": 0, "inkPixels": 0, "checkedPixels": 0]
    guard spans.count >= max(40, height / 8) else { return output }
    let left = spans.map(\.left).sorted()[spans.count / 2]
    let right = spans.map(\.right).sorted()[spans.count / 2]
    let top = (spans.first?.y ?? 0) + 12, bottom = (spans.last?.y ?? 0) - 12
    guard right - left >= width / 2, bottom - top >= height / 4 else { return output }
    var ink = 0, whitePixels = 0, checked = 0
    for y in top..<bottom {
        for x in (left + 12)..<(right - 12) {
            let offset = (y * width + x) * 4
            checked += 1
            if white(offset) { whitePixels += 1 }
            if bytes[offset] <= 100 && bytes[offset + 1] <= 100 && bytes[offset + 2] <= 100 && bytes[offset + 3] >= 240 { ink += 1 }
        }
    }
    output["paperWidth"] = right - left
    output["inkPixels"] = ink
    output["checkedPixels"] = checked
    output["paperReady"] = checked > 0 && whitePixels >= checked / 2 && ink >= max(500, checked / 1000)
    return output
}
emit(result, status: result["validImage"] as? Bool == true ? 0 : 2)
