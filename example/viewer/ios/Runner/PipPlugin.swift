import AVFoundation
import AVKit
import Flutter
import UIKit

/// A view whose backing layer is an `AVSampleBufferDisplayLayer`.
///
/// `AVPictureInPictureController` takes the *layer* as its content source and,
/// while PiP is running, the system reparents that layer into the floating
/// window. The view itself only has to exist somewhere on screen.
final class PipSampleBufferView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

  var displayLayer: AVSampleBufferDisplayLayer {
    // Safe: `layerClass` above guarantees the type.
    layer as! AVSampleBufferDisplayLayer
  }
}

/// Bridges the Dart side to AVKit's sample-buffer Picture in Picture.
///
/// The viewer has no `AVPlayer` — frames arrive as JPEGs over UDP — so PiP is
/// driven through `AVPictureInPictureController.ContentSource(sampleBuffer
/// DisplayLayer:playbackDelegate:)`, available since iOS 15. Dart pushes the
/// latest frames over the method channel; this class composites and enqueues
/// them.
///
/// Backgrounding the app hands off to PiP automatically via
/// `canStartPictureInPictureAutomaticallyFromInline`.
final class PipPlugin: NSObject, FlutterPlugin {
  private static let channelName = "ntr_viewer/pip"

  private let channel: FlutterMethodChannel
  private let renderer = PipFrameRenderer()
  private let renderQueue = DispatchQueue(label: "dev.ntr.viewer.pip.render", qos: .userInitiated)

  private var pipView: PipSampleBufferView?
  private var controller: AVPictureInPictureController?

  private var layout: PipLayout = .stacked
  private var quarterTurns = 3
  private var isPlaying = true
  private var rendering = false
  private var audioSessionActivated = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = PipPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  // MARK: - Channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(AVPictureInPictureController.isPictureInPictureSupported())

    case "enable":
      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        result(false)
        return
      }
      result(enable())

    case "disable":
      disable()
      result(nil)

    case "setLayout":
      let arguments = call.arguments as? [String: Any] ?? [:]
      if let raw = arguments["layout"] as? String, let parsed = PipLayout(rawValue: raw) {
        layout = parsed
      }
      if let turns = arguments["quarterTurns"] as? Int {
        quarterTurns = turns
      }
      result(nil)

    case "pushFrames":
      let arguments = call.arguments as? [String: Any] ?? [:]
      let top = (arguments["top"] as? FlutterStandardTypedData)?.data
      let bottom = (arguments["bottom"] as? FlutterStandardTypedData)?.data
      push(top: top, bottom: bottom)
      result(nil)

    case "start":
      guard let controller, controller.isPictureInPicturePossible else {
        result(false)
        return
      }
      controller.startPictureInPicture()
      result(true)

    case "stop":
      controller?.stopPictureInPicture()
      result(nil)

    case "isActive":
      result(controller?.isPictureInPictureActive ?? false)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Lifecycle

  private func enable() -> Bool {
    if controller != nil { return true }
    guard let window = keyWindow() else { return false }

    let view = PipSampleBufferView(frame: window.bounds)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.isUserInteractionEnabled = false
    view.backgroundColor = .black
    view.displayLayer.videoGravity = .resizeAspect
    // The layer has to be in the hierarchy and visible for AVKit to accept it,
    // but the Flutter view draws over any subview of its own, so it goes into
    // the window *behind* the (opaque, full-screen) Flutter view instead.
    window.insertSubview(view, at: 0)
    pipView = view

    // Without an active playback-category session PiP refuses to start and
    // reports no error. `.mixWithOthers` keeps whatever the user is listening
    // to alive, since the viewer itself is silent.
    activateAudioSession()

    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.requiresLinearPlayback = true
    self.controller = controller
    return true
  }

  private func disable() {
    controller?.stopPictureInPicture()
    controller?.delegate = nil
    controller = nil
    pipView?.removeFromSuperview()
    pipView = nil
    resetRenderer()
    deactivateAudioSession()
  }

  private func activateAudioSession() {
    guard !audioSessionActivated else { return }
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
      try session.setActive(true)
      audioSessionActivated = true
    } catch {
      NSLog("[pip] audio session setup failed: \(error)")
    }
  }

  private func deactivateAudioSession() {
    guard audioSessionActivated else { return }
    audioSessionActivated = false
    do {
      try AVAudioSession.sharedInstance().setActive(
        false, options: [.notifyOthersOnDeactivation])
    } catch {
      NSLog("[pip] audio session teardown failed: \(error)")
    }
  }

  private func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    return windows.first { $0.isKeyWindow } ?? windows.first
  }

  // MARK: - Frames

  private func push(top: Data?, bottom: Data?) {
    guard let layer = pipView?.displayLayer, isPlaying else { return }
    // Drop rather than queue: the newest frame is the only interesting one and
    // a backlog would only add latency.
    guard !rendering else { return }
    rendering = true

    let layout = self.layout
    let quarterTurns = self.quarterTurns
    renderQueue.async { [weak self] in
      guard let self else { return }
      defer { DispatchQueue.main.async { self.rendering = false } }

      guard
        let sampleBuffer = self.renderer.makeSampleBuffer(
          top: top, bottom: bottom, layout: layout, quarterTurns: quarterTurns)
      else { return }

      DispatchQueue.main.async { self.enqueue(sampleBuffer, into: layer) }
    }
  }

  /// `AVSampleBufferDisplayLayer`'s own enqueue/flush surface is deprecated in
  /// favour of `sampleBufferRenderer` from iOS 17 on.
  private func enqueue(_ sampleBuffer: CMSampleBuffer, into layer: AVSampleBufferDisplayLayer) {
    if #available(iOS 17.0, *) {
      let videoRenderer = layer.sampleBufferRenderer
      if videoRenderer.status == .failed {
        videoRenderer.flush()
        resetRenderer()
      }
      guard videoRenderer.isReadyForMoreMediaData else { return }
      videoRenderer.enqueue(sampleBuffer)
    } else {
      if layer.status == .failed {
        layer.flush()
        resetRenderer()
      }
      guard layer.isReadyForMoreMediaData else { return }
      layer.enqueue(sampleBuffer)
    }
  }

  /// The renderer is only ever touched from `renderQueue`.
  private func resetRenderer() {
    renderQueue.async { [renderer] in renderer.reset() }
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PipPlugin: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    channel.invokeMethod("onActiveChanged", arguments: true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    channel.invokeMethod("onActiveChanged", arguments: false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("[pip] failed to start: \(error)")
    channel.invokeMethod("onFailed", arguments: error.localizedDescription)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    // The Flutter view is still mounted underneath; nothing to rebuild.
    channel.invokeMethod("onRestoreUi", arguments: nil)
    completionHandler(true)
  }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PipPlugin: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    isPlaying = playing
    pictureInPictureController.invalidatePlaybackState()
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    // An infinite range marks the content as live, which hides the scrubber.
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    !isPlaying
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    // The viewer plays no audio, so never silence whatever else is running.
    false
  }
}
