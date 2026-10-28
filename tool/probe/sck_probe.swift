// Prints whether ScreenCaptureKit can see and capture the display.
import CoreGraphics
import Foundation
import ScreenCaptureKit

print("preflight=\(CGPreflightScreenCaptureAccess())")
do {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  print("displays=\(content.displays.count) windows=\(content.windows.count)")
  if let display = content.displays.first {
    print("display=\(display.width)x\(display.height) id=\(display.displayID)")
    if #available(macOS 14.0, *) {
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let config = SCStreamConfiguration()
      config.width = display.width
      config.height = display.height
      let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
      print("screenshot=\(image.width)x\(image.height)")
    }
  }
} catch {
  print("sck_error=\(error)")
}
