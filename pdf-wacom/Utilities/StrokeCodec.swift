import Cocoa

// 페이지별 stroke를 binary로 직렬화한다.
// 헤더: magic("PNST") + version(u16) + pageIndex(u32) + strokeCount(u32)
// stroke: id(uuid 16) + rgba(u8x4) + width(f32) + createdAt(f64) + pointCount(u32)
//         + points (x:f32, y:f32, t:f32) * pointCount
enum StrokeCodec {

    static let magic: [UInt8] = Array("PNST".utf8)
    static let version: UInt16 = 1

    enum DecodeError: Error {
        case truncated
        case badMagic
        case unsupportedVersion(UInt16)
        case trailingData
        case invalidCount
        case invalidNumber
    }

    static func encode(_ pageStrokes: PageStrokes) -> Data {
        var data = Data()
        data.append(contentsOf: magic)
        data.appendLE(version)
        data.appendLE(UInt32(pageStrokes.pageIndex))
        data.appendLE(UInt32(pageStrokes.strokes.count))
        for stroke in pageStrokes.strokes {
            data.append(contentsOf: stroke.id.byteArray)
            let (r, g, b, a) = stroke.color.rgba255
            data.append(contentsOf: [r, g, b, a])
            data.appendLE(Float(stroke.width).bitPattern)
            data.appendLE(stroke.createdAt.timeIntervalSince1970.bitPattern)
            data.appendLE(UInt32(stroke.points.count))
            for p in stroke.points {
                data.appendLE(p.x.bitPattern)
                data.appendLE(p.y.bitPattern)
                data.appendLE(p.t.bitPattern)
            }
        }
        return data
    }

    static func decode(_ data: Data) throws -> PageStrokes {
        var cursor = data.startIndex
        guard data.count >= 14 else { throw DecodeError.truncated }
        let magicBytes = Array(data[cursor..<cursor + 4])
        guard magicBytes == magic else { throw DecodeError.badMagic }
        cursor += 4
        let version: UInt16 = try data.readLE(at: &cursor)
        guard version == Self.version else { throw DecodeError.unsupportedVersion(version) }
        let pageIndex: UInt32 = try data.readLE(at: &cursor)
        let strokeCount: UInt32 = try data.readLE(at: &cursor)
        guard Int(strokeCount) <= (data.endIndex - cursor) / Self.minimumEncodedStrokeByteCount else {
            throw DecodeError.truncated
        }

        let result = PageStrokes(pageIndex: Int(pageIndex))
        for _ in 0..<Int(strokeCount) {
            let id = try data.readUUID(at: &cursor)
            let r: UInt8 = try data.readByte(at: &cursor)
            let g: UInt8 = try data.readByte(at: &cursor)
            let b: UInt8 = try data.readByte(at: &cursor)
            let a: UInt8 = try data.readByte(at: &cursor)
            let widthBits: UInt32 = try data.readLE(at: &cursor)
            let createdAtBits: UInt64 = try data.readLE(at: &cursor)
            let pointCount: UInt32 = try data.readLE(at: &cursor)
            guard Int(pointCount) <= Self.maximumPointCountPerStroke else { throw DecodeError.invalidCount }
            guard Int(pointCount) <= (data.endIndex - cursor) / Self.encodedPointByteCount else {
                throw DecodeError.truncated
            }

            let width = Float(bitPattern: widthBits)
            let createdAt = Double(bitPattern: createdAtBits)
            guard width.isFinite, width > 0, createdAt.isFinite else { throw DecodeError.invalidNumber }

            let stroke = Stroke(
                id: id,
                color: NSColor(rgba255: (r, g, b, a)),
                width: CGFloat(width),
                createdAt: Date(timeIntervalSince1970: createdAt)
            )
            for _ in 0..<Int(pointCount) {
                let xBits: UInt32 = try data.readLE(at: &cursor)
                let yBits: UInt32 = try data.readLE(at: &cursor)
                let tBits: UInt32 = try data.readLE(at: &cursor)
                let x = Float(bitPattern: xBits)
                let y = Float(bitPattern: yBits)
                let t = Float(bitPattern: tBits)
                guard x.isFinite, y.isFinite, t.isFinite else { throw DecodeError.invalidNumber }
                stroke.append(StrokePoint(
                    x: x,
                    y: y,
                    t: t
                ))
            }
            result.add(stroke, notify: false)
        }
        guard cursor == data.endIndex else { throw DecodeError.trailingData }
        return result
    }

    private static let minimumEncodedStrokeByteCount = 36
    private static let encodedPointByteCount = 12
    private static let maximumPointCountPerStroke = 1_000_000
}

// MARK: - Helpers

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        let v = value.littleEndian
        Swift.withUnsafeBytes(of: v) { buf in
            append(contentsOf: buf)
        }
    }

    func readLE<T: FixedWidthInteger>(at cursor: inout Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard cursor + size <= endIndex else { throw StrokeCodec.DecodeError.truncated }
        let value: T = self[cursor..<cursor + size].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        cursor += size
        return T(littleEndian: value)
    }

    func readByte(at cursor: inout Int) throws -> UInt8 {
        guard cursor < endIndex else { throw StrokeCodec.DecodeError.truncated }
        let v = self[cursor]
        cursor += 1
        return v
    }

    func readUUID(at cursor: inout Int) throws -> UUID {
        guard cursor + 16 <= endIndex else { throw StrokeCodec.DecodeError.truncated }
        let bytes = Array(self[cursor..<cursor + 16])
        cursor += 16
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

extension UUID {
    var byteArray: [UInt8] {
        let u = self.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }
}

extension NSColor {
    typealias RGBA8 = (UInt8, UInt8, UInt8, UInt8)

    var rgba255: RGBA8 {
        let c = usingColorSpace(.deviceRGB) ?? self
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (clamp255(r), clamp255(g), clamp255(b), clamp255(a))
    }

    convenience init(rgba255: RGBA8) {
        self.init(srgbRed: CGFloat(rgba255.0) / 255,
                  green: CGFloat(rgba255.1) / 255,
                  blue: CGFloat(rgba255.2) / 255,
                  alpha: CGFloat(rgba255.3) / 255)
    }
}

private func clamp255(_ v: CGFloat) -> UInt8 {
    let scaled = (v * 255).rounded()
    return UInt8(Swift.max(0, Swift.min(255, scaled)))
}
