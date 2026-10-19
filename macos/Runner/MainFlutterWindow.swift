import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// True while the region selector covers the screen.
  private var overlay = false
  private var savedLevel: NSWindow.Level = .normal
  private var savedBehavior: NSWindow.CollectionBehavior = []
  private let effects = RecordingEffects()
  private var effectsChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Cursor halo and face-camera bubble.
    effectsChannel = effects.register(messenger: flutterViewController.engine.binaryMessenger)

    let channel = FlutterMethodChannel(
      name: "screen_recorder_app/macos",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "enterOverlay":
        self.enterOverlay()
        result(true)
      case "exitOverlay":
        self.exitOverlay()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  /// Cover the whole main display, above the menu bar and Dock, on every
  /// Space, without switching to a fullscreen Space.
  private func enterOverlay() {
    guard let screen = NSScreen.screens.first ?? self.screen else { return }
    if !overlay {
      savedLevel = self.level
      savedBehavior = self.collectionBehavior
    }
    overlay = true
    self.level = .screenSaver
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    self.setFrame(screen.frame, display: true, animate: false)
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func exitOverlay() {
    guard overlay else { return }
    overlay = false
    self.level = savedLevel
    self.collectionBehavior = savedBehavior
  }

  // Titled windows are normally kept below the menu bar; allow the overlay
  // to sit on top of it.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    if overlay { return frameRect }
    return super.constrainFrameRect(frameRect, to: screen)
  }
}

// Live recording effects on macOS: the yellow cursor halo with click
// ripples, and the draggable face-camera bubble. Both are real on-screen
// windows, so the screen capture records them exactly as the user sees them.
//
// Same channel and methods as the Windows runner ("screen_recorder_app/windows").
final class RecordingEffects {
  private let overlay = CursorOverlay()
  private let camera = CameraBubble()

  func register(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "screen_recorder_app/windows", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "showCursorOverlay":
        result(self.overlay.show(halo: args["halo"] as? Bool ?? true,
                                 ripples: args["ripples"] as? Bool ?? true))
      case "hideCursorOverlay":
        self.overlay.hide()
        result(true)
      case "listCameras":
        result(CameraBubble.devices().map { $0.localizedName })
      case "showCamera":
        let error = self.camera.show(
          diameter: (args["diameter"] as? NSNumber)?.intValue ?? 220,
          circle: args["circle"] as? Bool ?? true,
          flip: args["flip"] as? Bool ?? false,
          device: args["device"] as? String ?? "",
          corner: (args["corner"] as? NSNumber)?.intValue ?? 2)
        result(error)
      case "moveCamera":
        self.camera.moveToCorner((call.arguments as? NSNumber)?.intValue ?? 2)
        result(true)
      case "hideCamera":
        self.camera.hide()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }
}

// MARK: - Cursor halo

private let haloRadius: CGFloat = 22
private let ringWidth: CGFloat = 2.5
private let rippleMaxRadius: CGFloat = 54
private let rippleWidth: CGFloat = 3
private let rippleDuration: TimeInterval = 0.45
private let overlaySize: CGFloat = (rippleMaxRadius + rippleWidth + 4) * 2
private let yellow = NSColor(srgbRed: 1, green: 214 / 255, blue: 0, alpha: 1)
private let blue = NSColor(srgbRed: 66 / 255, green: 165 / 255, blue: 245 / 255, alpha: 1)

private struct Ripple {
  let start: TimeInterval
  let right: Bool
}

private final class HaloView: NSView {
  var halo = true
  var pressed = false
  var ripples: [Ripple] = []

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.set()
    dirtyRect.fill()
    let c = NSPoint(x: bounds.midX, y: bounds.midY)
    func circle(_ r: CGFloat) -> NSBezierPath {
      NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    if halo {
      let path = circle(haloRadius * (pressed ? 0.85 : 1))
      yellow.withAlphaComponent(pressed ? 0.45 : 0.28).setFill()
      path.fill()
      yellow.withAlphaComponent(pressed ? 0.95 : 0.8).setStroke()
      path.lineWidth = ringWidth
      path.stroke()
    }
    let now = ProcessInfo.processInfo.systemUptime
    for ripple in ripples {
      let p = min(1, max(0, (now - ripple.start) / rippleDuration))
      let eased = 1 - (1 - p) * (1 - p)
      let path = circle(haloRadius + (rippleMaxRadius - haloRadius) * CGFloat(eased))
      path.lineWidth = rippleWidth * CGFloat(1 - 0.5 * p)
      (ripple.right ? blue : yellow).withAlphaComponent(CGFloat(0.9 * (1 - p))).setStroke()
      path.stroke()
    }
  }
}

final class CursorOverlay {
  private var window: NSWindow?
  private var view: HaloView?
  private var timer: Timer?
  private var drawRipples = true
  private var leftWasDown = false
  private var rightWasDown = false

  func show(halo: Bool, ripples: Bool) -> Bool {
    guard halo || ripples else { return false }
    drawRipples = ripples
    if window == nil {
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: overlaySize, height: overlaySize),
                       styleMask: .borderless, backing: .buffered, defer: false)
      w.isOpaque = false
      w.backgroundColor = .clear
      w.hasShadow = false
      w.ignoresMouseEvents = true  // clicks go straight through
      w.level = .screenSaver
      w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
      w.isReleasedWhenClosed = false
      let v = HaloView(frame: NSRect(x: 0, y: 0, width: overlaySize, height: overlaySize))
      w.contentView = v
      window = w
      view = v
    }
    view?.halo = halo
    view?.ripples = []
    leftWasDown = false
    rightWasDown = false
    tick()
    window?.orderFrontRegardless()
    if timer == nil {
      let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
      RunLoop.main.add(t, forMode: .common)
      timer = t
    }
    return true
  }

  func hide() {
    timer?.invalidate()
    timer = nil
    window?.orderOut(nil)
    view?.ripples = []
  }

  private func tick() {
    guard let window = window, let view = view else { return }
    let location = NSEvent.mouseLocation  // global, bottom-left origin
    let buttons = NSEvent.pressedMouseButtons
    let left = buttons & 1 != 0
    let right = buttons & 2 != 0
    let now = ProcessInfo.processInfo.systemUptime
    if drawRipples {
      if left && !leftWasDown { view.ripples.append(Ripple(start: now, right: false)) }
      if right && !rightWasDown { view.ripples.append(Ripple(start: now, right: true)) }
    }
    leftWasDown = left
    rightWasDown = right
    view.pressed = left || right
    view.ripples.removeAll { now - $0.start > rippleDuration }
    window.setFrameOrigin(NSPoint(x: location.x - overlaySize / 2, y: location.y - overlaySize / 2))
    view.needsDisplay = true
  }
}

// MARK: - Camera bubble

private final class BubbleView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class BubbleWindow: NSWindow {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

final class CameraBubble {
  private let margin: CGFloat = 4
  private var window: BubbleWindow?
  private var clip: CALayer?
  private var preview: AVCaptureVideoPreviewLayer?
  private var session: AVCaptureSession?
  private var deviceID: String?
  private var placed = false
  private let queue = DispatchQueue(label: "camera.bubble")

  static func devices() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) {
      types += [.external, .continuityCamera]
    } else {
      types += [.externalUnknown]
    }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
  }

  /// Returns an error message, or nil when the bubble is showing.
  func show(diameter: Int, circle: Bool, flip: Bool, device: String, corner: Int) -> String? {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .denied, .restricted:
      return "Camera access is off. Allow Screen Recorder in System Settings → Privacy & Security → Camera."
    case .notDetermined:
      // Ask, then show once the user answers.
      AVCaptureDevice.requestAccess(for: .video) { granted in
        guard granted else { return }
        DispatchQueue.main.async {
          _ = self.show(diameter: diameter, circle: circle, flip: flip, device: device, corner: corner)
        }
      }
      return nil
    default:
      break
    }

    let all = CameraBubble.devices()
    guard let camera = all.first(where: { $0.localizedName == device }) ?? all.first else {
      return "No camera was found. Connect one and try again."
    }

    let d = CGFloat(max(60, diameter))
    let size = d + margin * 2
    if window == nil {
      let w = BubbleWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
      w.isOpaque = false
      w.backgroundColor = .clear
      w.hasShadow = true
      w.isMovableByWindowBackground = true
      // Above the app's recording bar, below the cursor halo.
      w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
      w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
      w.isReleasedWhenClosed = false
      let content = BubbleView(frame: NSRect(x: 0, y: 0, width: size, height: size))
      content.wantsLayer = true
      w.contentView = content
      let clip = CALayer()
      clip.masksToBounds = true
      clip.backgroundColor = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1).cgColor
      clip.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
      content.layer?.addSublayer(clip)
      self.clip = clip
      window = w
      placed = false
    }
    guard let window = window, let clip = clip else { return "Could not create the camera window." }

    window.setContentSize(NSSize(width: size, height: size))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    clip.frame = CGRect(x: margin, y: margin, width: d, height: d)
    clip.cornerRadius = circle ? d / 2 : d * 0.18
    clip.borderWidth = max(2, d / 80) * 1.5
    CATransaction.commit()

    if session == nil || deviceID != camera.uniqueID {
      stopSession()
      let s = AVCaptureSession()
      s.sessionPreset = .high
      do {
        let input = try AVCaptureDeviceInput(device: camera)
        guard s.canAddInput(input) else { return "This camera can't be used right now." }
        s.addInput(input)
      } catch {
        return "Could not open the camera: \(error.localizedDescription)"
      }
      let layer = AVCaptureVideoPreviewLayer(session: s)
      layer.videoGravity = .resizeAspectFill
      clip.addSublayer(layer)
      preview = layer
      session = s
      deviceID = camera.uniqueID
      queue.async { s.startRunning() }
    }

    if let layer = preview {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.frame = clip.bounds
      // Mirror like a selfie; optionally flip upside down.
      layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: flip ? -1 : 1))
      CATransaction.commit()
    }

    if !placed {
      moveToCorner(corner)
      placed = true
    }
    window.orderFrontRegardless()
    return nil
  }

  func moveToCorner(_ corner: Int) {
    guard let window = window, let screen = NSScreen.screens.first ?? NSScreen.main else { return }
    let work = screen.visibleFrame
    let pad: CGFloat = 32
    let size = window.frame.size
    let right = corner == 1 || corner == 3
    let bottom = corner == 2 || corner == 3
    let x = right ? work.maxX - size.width - pad : work.minX + pad
    // Cocoa y grows upwards.
    let y = bottom ? work.minY + pad : work.maxY - size.height - pad
    window.setFrameOrigin(NSPoint(x: x, y: y))
  }

  func hide() {
    stopSession()
    window?.orderOut(nil)
    placed = false
  }

  private func stopSession() {
    if let s = session {
      queue.async { s.stopRunning() }
    }
    preview?.removeFromSuperlayer()
    preview = nil
    session = nil
    deviceID = nil
  }
}
