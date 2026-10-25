// Packs an .iconset's PNGs into an .icns file byte for byte.
//
// iconutil re-encodes the PNGs, which undoes oxipng and doubles the file.
// The format is simple: "icns" and the total length, then for each image its
// type, its length including this 8-byte header, and the PNG data.
//
// Usage: swift pack-icns.swift <name.iconset> <out.icns>

import Foundation

/// iconset file name to icns type. icp4 and icp5 take PNG data, unlike the
/// ARGB ic04 and ic05 that iconutil writes for 16 and 32 px.
let types: [(file: String, type: String)] = [
    ("icon_16x16.png", "icp4"), ("icon_16x16@2x.png", "ic11"),
    ("icon_32x32.png", "icp5"), ("icon_32x32@2x.png", "ic12"),
    ("icon_128x128.png", "ic07"), ("icon_128x128@2x.png", "ic13"),
    ("icon_256x256.png", "ic08"), ("icon_256x256@2x.png", "ic14"),
    ("icon_512x512.png", "ic09"), ("icon_512x512@2x.png", "ic10"),
]

func bigEndian(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: pack-icns.swift <name.iconset> <out.icns>\n".utf8))
    exit(2)
}
let iconset = URL(fileURLWithPath: arguments[1])

var body = Data()
for (file, type) in types {
    let png: Data
    do {
        png = try Data(contentsOf: iconset.appendingPathComponent(file))
    } catch {
        FileHandle.standardError.write(Data("missing \(file) in \(iconset.path): \(error)\n".utf8))
        exit(1)
    }
    guard png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
        FileHandle.standardError.write(Data("\(file) is not a PNG\n".utf8))
        exit(1)
    }
    body += Data(type.utf8) + bigEndian(png.count + 8) + png
}

let icns = Data("icns".utf8) + bigEndian(body.count + 8) + body
do {
    try icns.write(to: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write(Data("cannot write \(arguments[2]): \(error)\n".utf8))
    exit(1)
}
