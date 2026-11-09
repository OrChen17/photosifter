import Photos
import XCTest
@testable import PhotoSifter

/// Returns the first N images from the device/simulator photo library.
/// Skips the calling test if fewer than `minimum` are available or library access is denied.
func requirePhotoAssets(minimum: Int = 2, file: StaticString = #file, line: UInt = #line) throws -> [PHAsset] {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    try XCTSkipIf(
        status == .denied || status == .restricted,
        "Photo library access denied — run on a simulator with sample photos.",
        file: file, line: line
    )

    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    options.fetchLimit = minimum + 5
    let result = PHAsset.fetchAssets(with: .image, options: options)

    try XCTSkipIf(
        result.count < minimum,
        "Need at least \(minimum) photos in the library; found \(result.count).",
        file: file, line: line
    )

    var assets: [PHAsset] = []
    result.enumerateObjects { asset, _, _ in assets.append(asset) }
    return Array(assets.prefix(minimum))
}

/// Builds a PhotoGroup from existing library assets, skipping the test if unavailable.
func requirePhotoGroup(assetCount: Int = 3, file: StaticString = #file, line: UInt = #line) throws -> PhotoGroup {
    let assets = try requirePhotoAssets(minimum: assetCount, file: file, line: line)
    return PhotoGroup(id: UUID(), assets: assets)
}

func requireRealVision(file: StaticString = #file, line: UInt = #line) throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Vision feature prints need a device. The simulator cannot load the model.", file: file, line: line)
    #endif
}
