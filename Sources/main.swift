import AppKit
import Foundation

// RDM-ARM entry point.
//
// With arguments   -> command-line mode, exits with a status code.
// Without arguments -> menu bar app (the normal way to run it).

let arguments = Array(CommandLine.arguments.dropFirst())

// GUI diagnostics: creates the real status item, reports where the window
// server put it, and prints the menu it built.
if arguments.first == "--selftest" {
    exit(GUISelfTest.run())
}

if !arguments.isEmpty {
    exit(CommandLineRunner.run(arguments: arguments))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
