// Marky: a small, native Markdown reader that typesets LaTeX math.
//
//   Marky                          the app
//   Marky --check FILE…            typeset every formula in the files and list the ones that fail
//   Marky --bench FILE              time parsing, rendering and showing FILE
//   Marky --pdf FILE OUT.pdf       export FILE as PDF
//   Marky --cycle FILE N [outline]   open and close FILE N times, then count what is left
//   Marky --soak FILE MINUTES       edit, scroll, zoom and reopen FILE for MINUTES, logging memory
//   Marky --selftest DIR            open, reload, zoom and close a file in DIR, off screen
//   Marky --snapshot DIR FILE [ANCHOR [W H]]
//                                  render FILE in light and dark mode to DIR/reader-{light,dark}.png

import AppKit

let arguments = CommandLine.arguments

MainActor.assumeIsolated {
    if arguments.count >= 3 && arguments[1] == "--check" {
        exit(Tools.check(Array(arguments.dropFirst(2))))
    }
    if arguments.count >= 3 && arguments[1] == "--bench" {
        exit(Tools.bench(arguments[2]))
    }
    if arguments.count >= 4 && arguments[1] == "--pdf" {
        exit(Tools.pdf(file: arguments[2], out: arguments[3]))
    }
    if arguments.count >= 4 && arguments[1] == "--cycle" {
        NSApplication.shared.setActivationPolicy(.accessory)
        Settings.showsOutline = false
        Soak.cycle(file: arguments[2], count: Int(arguments[3]) ?? 20, outline: arguments.count >= 5)
        NSApplication.shared.run()
    }
    if arguments.count >= 4 && arguments[1] == "--soak" {
        NSApplication.shared.setActivationPolicy(.accessory)
        Soak.start(file: arguments[2], minutes: Double(arguments[3]) ?? 30)
        NSApplication.shared.run()
    }
    if arguments.count >= 3 && arguments[1] == "--selftest" {
        exit(SelfTest.run(directory: arguments[2]))
    }
    if arguments.count >= 4 && arguments[1] == "--snapshot" {
        let size = arguments.count >= 7 ? (Double(arguments[5]) ?? 820, Double(arguments[6]) ?? 1000) : (820, 1000)
        exit(Tools.snapshot(directory: arguments[2], file: arguments[3], anchor: arguments.count >= 5 && !arguments[4].isEmpty ? arguments[4] : nil,
                            width: CGFloat(size.0), height: CGFloat(size.1)))
    }
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
}
