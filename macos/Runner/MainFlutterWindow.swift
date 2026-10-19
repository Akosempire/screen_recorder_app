import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// True while the region selector covers the screen.
  private var overlay = false
  private var savedLevel: NSWindow.Level = .normal
  private var savedBehavior: NSWindow.CollectionBehavior = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

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
