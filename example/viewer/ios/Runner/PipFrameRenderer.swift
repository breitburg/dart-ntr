import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import UIKit

/// How the two 3DS screens are arranged inside the Picture in Picture window.
/// Raw values match `ScreenLayout` on the Dart side.
enum PipLayout: String {
  case stacked
  case sideBySide
  case topOnly
  case bottomOnly
}

/// Composites the JPEG frames coming off the NTR stream into `CMSampleBuffer`s
/// that an `AVSampleBufferDisplayLayer` can display.
///
/// The device sends both screens rotated 90°, so the viewer applies a rotation
/// before drawing them. PiP has to apply the same rotation — otherwise the
/// floating window shows a sideways 3DS — which is why the composite is built
/// here with Core Graphics rather than handing a single JPEG straight through.
final class PipFrameRenderer {
  /// Pre-rotation size of a top-screen frame as NTR sends it.
  private static let nominalTop = CGSize(width: 240, height: 400)
  /// Pre-rotation size of a bottom-screen frame.
  private static let nominalBottom = CGSize(width: 240, height: 320)

  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0
  private var formatDescription: CMVideoFormatDescription?

  /// Builds one frame. `top`/`bottom` are JPEG payloads; either may be nil
  /// before the first frame of that screen has arrived.
  func makeSampleBuffer(
    top: Data?,
    bottom: Data?,
    layout: PipLayout,
    quarterTurns: Int
  ) -> CMSampleBuffer? {
    let turns = ((quarterTurns % 4) + 4) % 4
    let topImage = layout == .bottomOnly ? nil : decode(top)
    let bottomImage = layout == .topOnly ? nil : decode(bottom)
    if topImage == nil && bottomImage == nil { return nil }

    // Reserve space using the nominal size when a screen has not produced a
    // frame yet, so the video dimensions stay stable and PiP does not resize
    // its window the moment the second screen shows up.
    let topBox = rotate(size(of: topImage) ?? Self.nominalTop, turns: turns)
    let bottomBox = rotate(size(of: bottomImage) ?? Self.nominalBottom, turns: turns)

    let canvas: CGSize
    var topOrigin = CGPoint.zero
    var bottomOrigin = CGPoint.zero
    switch layout {
    case .topOnly:
      canvas = topBox
    case .bottomOnly:
      canvas = bottomBox
    case .stacked:
      canvas = CGSize(
        width: max(topBox.width, bottomBox.width),
        height: topBox.height + bottomBox.height)
      topOrigin = CGPoint(x: (canvas.width - topBox.width) / 2, y: 0)
      bottomOrigin = CGPoint(x: (canvas.width - bottomBox.width) / 2, y: topBox.height)
    case .sideBySide:
      canvas = CGSize(
        width: topBox.width + bottomBox.width,
        height: max(topBox.height, bottomBox.height))
      topOrigin = CGPoint(x: 0, y: (canvas.height - topBox.height) / 2)
      bottomOrigin = CGPoint(x: topBox.width, y: (canvas.height - bottomBox.height) / 2)
    }

    // Even dimensions keep every downstream consumer happy.
    let width = Int((canvas.width / 2).rounded(.up)) * 2
    let height = Int((canvas.height / 2).rounded(.up)) * 2
    guard width > 0, height > 0 else { return nil }

    guard let pixelBuffer = makePixelBuffer(width: width, height: height) else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
      let context = CGContext(
        data: base,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }

    context.setFillColor(UIColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .medium

    let canvasHeight = CGFloat(height)
    switch layout {
    case .topOnly:
      draw(topImage, in: CGRect(origin: .zero, size: topBox), turns: turns,
        canvasHeight: canvasHeight, into: context)
    case .bottomOnly:
      draw(bottomImage, in: CGRect(origin: .zero, size: bottomBox), turns: turns,
        canvasHeight: canvasHeight, into: context)
    case .stacked, .sideBySide:
      draw(topImage, in: CGRect(origin: topOrigin, size: topBox), turns: turns,
        canvasHeight: canvasHeight, into: context)
      draw(bottomImage, in: CGRect(origin: bottomOrigin, size: bottomBox), turns: turns,
        canvasHeight: canvasHeight, into: context)
    }

    return wrap(pixelBuffer)
  }

  /// Drops the cached pool/format so the next frame starts from scratch.
  func reset() {
    pool = nil
    poolWidth = 0
    poolHeight = 0
    formatDescription = nil
  }

  // MARK: - Drawing

  private func decode(_ data: Data?) -> CGImage? {
    guard let data, !data.isEmpty,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(
      source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  }

  private func size(of image: CGImage?) -> CGSize? {
    guard let image else { return nil }
    return CGSize(width: image.width, height: image.height)
  }

  /// Size of `size` after `turns` quarter turns.
  private func rotate(_ size: CGSize, turns: Int) -> CGSize {
    turns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
  }

  /// Draws `image` rotated clockwise by `turns` quarter turns so it fills
  /// `box`, which is expressed in top-left origin coordinates.
  private func draw(
    _ image: CGImage?,
    in box: CGRect,
    turns: Int,
    canvasHeight: CGFloat,
    into context: CGContext
  ) {
    guard let image else { return }
    // Core Graphics bitmap contexts are bottom-left origin; flip the box.
    let midX = box.midX
    let midY = canvasHeight - box.midY
    // Pre-rotation extent of the same box.
    let preWidth = turns % 2 == 1 ? box.height : box.width
    let preHeight = turns % 2 == 1 ? box.width : box.height

    context.saveGState()
    context.translateBy(x: midX, y: midY)
    // Positive angles turn counter-clockwise in this space; the viewer's
    // quarter turns are clockwise.
    context.rotate(by: -CGFloat(turns) * .pi / 2)
    context.draw(
      image,
      in: CGRect(x: -preWidth / 2, y: -preHeight / 2, width: preWidth, height: preHeight))
    context.restoreGState()
  }

  // MARK: - Buffers

  private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    if pool == nil || poolWidth != width || poolHeight != height {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        // AVSampleBufferDisplayLayer only accepts IOSurface-backed buffers.
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
      ]
      var created: CVPixelBufferPool?
      guard
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
          == kCVReturnSuccess
      else { return nil }
      pool = created
      poolWidth = width
      poolHeight = height
      formatDescription = nil
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess
    else { return nil }
    return buffer
  }

  private func wrap(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    if formatDescription == nil {
      var description: CMVideoFormatDescription?
      guard
        CMVideoFormatDescriptionCreateForImageBuffer(
          allocator: kCFAllocatorDefault,
          imageBuffer: pixelBuffer,
          formatDescriptionOut: &description) == noErr
      else { return nil }
      formatDescription = description
    }
    guard let formatDescription else { return nil }

    // The stream is live, so there is nothing to schedule against: stamp with
    // the host clock and let the layer show each frame as it lands.
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer) == noErr,
      let sampleBuffer
    else { return nil }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
      let entry = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        entry,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue!).toOpaque())
    }
    return sampleBuffer
  }
}
