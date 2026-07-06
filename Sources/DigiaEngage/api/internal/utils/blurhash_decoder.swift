import UIKit

/// Decodes a [BlurHash](https://blurha.sh/) string into a small `UIImage` used
/// as a blurred placeholder while the real image loads.
///
/// Self-contained implementation of the reference BlurHash decode algorithm (no
/// third-party dependency — same call as the Android SDK's vendored decoder).
/// The dashboard auto-computes these hashes; here we turn them back into a
/// low-resolution bitmap that SwiftUI upscales — the upscale is what produces
/// the smooth blur.
enum BlurHashDecoder {
    private static let alphabet =
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"

    private static let charValues: [Character: Int] = {
        var map = [Character: Int]()
        for (i, c) in alphabet.enumerated() { map[c] = i }
        return map
    }()

    /// Decode `blurHash` to a `width`×`height` image. Returns `nil` for a blank
    /// or malformed hash so callers can fall back to no placeholder.
    /// `punch` adjusts contrast (1 = as encoded).
    static func decode(_ blurHash: String, width: Int, height: Int, punch: Float = 1) -> UIImage? {
        guard blurHash.count >= 6, width > 0, height > 0 else { return nil }
        let chars = Array(blurHash)

        guard let sizeFlag = decode83(chars[0 ..< 1]) else { return nil }
        let numX = (sizeFlag % 9) + 1
        let numY = (sizeFlag / 9) + 1
        guard chars.count == 4 + 2 * numX * numY else { return nil }

        guard let quantMaxAc = decode83(chars[1 ..< 2]) else { return nil }
        let maxAc = Float(quantMaxAc + 1) / 166

        var colors: [(Float, Float, Float)] = []
        colors.reserveCapacity(numX * numY)
        guard let dc = decode83(chars[2 ..< 6]) else { return nil }
        colors.append(decodeDc(dc))
        for i in 1 ..< numX * numY {
            let from = 4 + i * 2
            guard let ac = decode83(chars[from ..< from + 2]) else { return nil }
            colors.append(decodeAc(ac, maxAc: maxAc * punch))
        }

        return composeImage(width: width, height: height, numX: numX, numY: numY, colors: colors)
    }

    private static func decode83(_ chars: ArraySlice<Character>) -> Int? {
        var value = 0
        for c in chars {
            guard let digit = charValues[c] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func decodeDc(_ value: Int) -> (Float, Float, Float) {
        (
            srgbToLinear((value >> 16) & 255),
            srgbToLinear((value >> 8) & 255),
            srgbToLinear(value & 255)
        )
    }

    private static func decodeAc(_ value: Int, maxAc: Float) -> (Float, Float, Float) {
        (
            signPow((Float(value / (19 * 19)) - 9) / 9, 2) * maxAc,
            signPow((Float((value / 19) % 19) - 9) / 9, 2) * maxAc,
            signPow((Float(value % 19) - 9) / 9, 2) * maxAc
        )
    }

    private static func composeImage(
        width: Int, height: Int, numX: Int, numY: Int, colors: [(Float, Float, Float)]
    ) -> UIImage? {
        let bytesPerRow = width * 3
        guard let data = CFDataCreateMutable(kCFAllocatorDefault, bytesPerRow * height) else {
            return nil
        }
        CFDataSetLength(data, bytesPerRow * height)
        guard let pixels = CFDataGetMutableBytePtr(data) else { return nil }

        // Precompute the cosine bases so the inner loop stays cheap.
        let cosX = (0 ..< width).map { x in
            (0 ..< numX).map { i in cos(Float.pi * Float(x) * Float(i) / Float(width)) }
        }
        let cosY = (0 ..< height).map { y in
            (0 ..< numY).map { j in cos(Float.pi * Float(y) * Float(j) / Float(height)) }
        }

        for y in 0 ..< height {
            for x in 0 ..< width {
                var r: Float = 0
                var g: Float = 0
                var b: Float = 0
                for j in 0 ..< numY {
                    for i in 0 ..< numX {
                        let basis = cosX[x][i] * cosY[y][j]
                        let color = colors[j * numX + i]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let offset = y * bytesPerRow + x * 3
                pixels[offset] = UInt8(linearToSrgb(r))
                pixels[offset + 1] = UInt8(linearToSrgb(g))
                pixels[offset + 2] = UInt8(linearToSrgb(b))
            }
        }

        guard let provider = CGDataProvider(data: data),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 24,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func signPow(_ value: Float, _ exp: Float) -> Float {
        copysign(pow(abs(value), exp), value)
    }

    private static func srgbToLinear(_ value: Int) -> Float {
        let v = Float(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ value: Float) -> Int {
        let v = min(max(value, 0), 1)
        let s = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return Int(s * 255 + 0.5)
    }
}
