import AppKit

// BallScroll lives in the menu bar: no Dock icon, no main window.
//
// Command line flags, mainly for development:
//   --debug      print a one-line summary of every gesture to stderr
//   --settings   open the settings window at launch
//   --no-prompt  do not ask for Accessibility access at launch
//   --snapshot=FILE  save a picture of the settings window to FILE and quit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
