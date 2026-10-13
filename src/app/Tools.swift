// Command-line helpers used for testing and for the README screenshots.

import AppKit

@MainActor
enum Tools {
    /// Typesets every formula in the files, prints the ones that fail and returns the failure count.
    static func check(_ paths: [String]) -> Int32 {
        var failures = 0
        var total = 0
        let engine = MathEngine.shared
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else {
                print("\(path): cannot read")
                failures += 1
                continue
            }
            let start = DispatchTime.now()
            let document = parseDocument(MarkdownFile.decode(data))
            var normalizer = TeXNormalizer(symbolCommands: engine.symbolCommands, commandSymbols: engine.commandSymbols)
            var failed = 0
            for span in document.math {
                let tex = normalizer.normalize(span.tex, display: span.display)
                let box = engine.typeset(tex, display: span.display, size: 18)
                if let error = box.error {
                    failed += 1
                    print("\(path): \(error)\n    \(span.source)\n    → \(tex)")
                }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
            print("\(path): \(document.math.count) formulas, \(failed) failed, \(String(format: "%.1f", ms)) ms")
            failures += failed
            total += document.math.count
        }
        if paths.count > 1 { print("Total: \(total) formulas, \(failures) failed") }
        return Int32(min(failures, 125))
    }

    /// Times each stage of showing a file and the memory it leaves behind: `Marky --bench FILE`.
    static func bench(_ file: String) -> Int32 {
        guard let data = FileManager.default.contents(atPath: file) else { return 1 }
        func stage(_ name: String, _ start: DispatchTime) {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
            print(name.padding(toLength: 8, withPad: " ", startingAt: 0) + String(format: "%9.1f ms %8.1f MB", ms, Double(Soak.footprint()) / 1_048_576))
        }
        stage("start", .now())
        var t = DispatchTime.now()
        let document = parseDocument(MarkdownFile.decode(data))
        stage("parse", t)
        t = .now()
        let renderer = Renderer(document: document, theme: Theme(zoom: 1), baseURL: nil, boxes: MathBoxCache())
        let text = renderer.render()
        stage("render", t)
        t = .now()
        let reader = ReaderView(frame: NSRect(x: 0, y: 0, width: 820, height: 1000))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 820, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = reader
        reader.show(MarkdownFile.decode(data), baseURL: nil, keepingPosition: false)
        reader.layoutSubtreeIfNeeded()
        reader.display()
        stage("show", t)
        t = .now()
        if let manager = reader.textView.layoutManager, let container = reader.textView.textContainer {
            manager.ensureLayout(for: container)
        }
        stage("layout all", t)
        t = .now()
        malloc_zone_pressure_relief(nil, 0)
        stage("relief", t)
        print("\(document.math.count) formulas, \(text.length) characters")
        return 0
    }

    /// Exports a file to PDF, as File > Export as PDF does.
    static func pdf(file: String, out: String) -> Int32 {
        guard let data = FileManager.default.contents(atPath: file) else { return 1 }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: out).absoluteURL
        let operation = PrintableText.operation(text: MarkdownFile.decode(data), baseURL: URL(fileURLWithPath: file).deletingLastPathComponent(),
                                                info: info, title: "export")
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run() ? 0 : 1
    }

    /// Renders a file in light and dark mode to PNGs, for the README. With an anchor, the view is
    /// scrolled to that heading first and the files are named after it.
    static func snapshot(directory: String, file: String, anchor: String? = nil, width: CGFloat = 820,
                         height: CGFloat = 1000) -> Int32 {
        guard let data = FileManager.default.contents(atPath: file) else { return 1 }
        let base = URL(fileURLWithPath: file).deletingLastPathComponent()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let size = NSSize(width: width, height: height)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            let reader = ReaderView(frame: NSRect(origin: .zero, size: size))
            window.contentView = reader
            reader.layoutSubtreeIfNeeded()
            reader.show(MarkdownFile.decode(data), baseURL: base, keepingPosition: false)
            reader.layoutSubtreeIfNeeded()
            if let anchor { reader.scroll(toAnchor: anchor) } else { reader.scrollView.contentView.scroll(to: .zero) }
            reader.layoutSubtreeIfNeeded()
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                guard let rep = reader.bitmapImageRepForCachingDisplay(in: reader.bounds) else { return }
                reader.cacheDisplay(in: reader.bounds, to: rep)
                let url = URL(fileURLWithPath: directory).appendingPathComponent("\(anchor ?? "reader")-\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            window.close()
        }
        return 0
    }
}

/// End-to-end checks of the app's own machinery, run off screen: `Marky --selftest DIR`.
@MainActor
enum SelfTest {
    static var failures = 0

    static func check(_ condition: Bool, _ what: String) {
        print((condition ? "ok    " : "FAIL  ") + what)
        if !condition { failures += 1 }
    }

    static func wait(_ seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func write(_ text: String, to url: URL, atomically: Bool) {
        if atomically {
            let temp = url.deletingLastPathComponent().appendingPathComponent(".marky-\(UUID().uuidString)")
            try? text.write(to: temp, atomically: false, encoding: .utf8)
            _ = rename(temp.path, url.path)
        } else if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
        } else if let handle = try? FileHandle(forWritingTo: url) {
            handle.truncateFile(atOffset: 0)
            handle.write(Data(text.utf8))
            try? handle.close()
        }
    }

    static func run(directory: String) -> Int32 {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("selftest.md")
        write("# One\n\nFirst $x^2$ version.\n\n## Two\n\nText.\n", to: url, atomically: true)
        guard let controller = ReaderWindowController.open(url) else { check(false, "opens a file"); return 1 }
        controller.window?.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        wait(0.3)
        check(controller.reader.outline.map(\.title) == ["One", "Two"], "outline lists the headings")
        check(ReaderWindowController.open(url) === controller, "opening the same file again reuses its window")

        // Copying puts formulas on the clipboard as they were written.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("marky-selftest-\(getpid())"))
        controller.reader.textView.selectAll(nil)
        _ = controller.reader.textView.writeSelection(to: pasteboard, types: [.string])
        check(pasteboard.string(forType: .string)?.contains("First $x^2$ version.") == true, "copy keeps a formula's LaTeX")
        pasteboard.releaseGlobally()
        controller.reader.textView.setSelectedRange(NSRange(location: 0, length: 0))

        write("# One\n\nSecond version $y$.\n\n## Two\n\nText.\n", to: url, atomically: true)
        wait(2) { controller.text.contains("Second") }
        check(controller.text.contains("Second"), "reloads after an atomic save (write and rename)")
        check(controller.reader.textView.string.contains("Second version"), "shows the reloaded text")

        write("# One\n\nThird version.\n", to: url, atomically: false)
        wait(2) { controller.text.contains("Third") }
        check(controller.text.contains("Third"), "reloads after an in-place write")

        try? FileManager.default.removeItem(at: url)
        wait(0.4)
        write("# One\n\nFourth version.\n", to: url, atomically: false)
        wait(3) { controller.text.contains("Fourth") }
        check(controller.text.contains("Fourth"), "reloads when a deleted file comes back")

        // A long file keeps its reading position when an edit lands above it.
        let long = (1...200).map { "Paragraph \($0) with $a_\($0)$ in it." }.joined(separator: "\n\n")
        write(long, to: url, atomically: true)
        wait(2) { controller.text.contains("Paragraph 200") }
        controller.reader.scroll(toLocation: (controller.reader.textView.string as NSString).range(of: "Paragraph 150").location)
        wait(0.2)
        let before = controller.reader.scrollView.contentView.bounds.minY
        write("Inserted line.\n\n" + long, to: url, atomically: true)
        wait(2) { controller.text.hasPrefix("Inserted") }
        let after = controller.reader.scrollView.contentView.bounds.minY
        check(controller.text.hasPrefix("Inserted") && after > before, "keeps the reading position across a reload")

        // Zooming keeps the paragraph at the top of the view.
        func topParagraph() -> Int {
            let view = controller.reader.textView
            let point = NSPoint(x: 1, y: controller.reader.scrollView.contentView.bounds.minY - view.textContainerOrigin.y + 2)
            let glyph = view.layoutManager!.glyphIndex(for: point, in: view.textContainer!, fractionOfDistanceThroughGlyph: nil)
            let index = view.layoutManager!.characterIndexForGlyph(at: glyph)
            let text = view.string as NSString
            let paragraph = text.substring(with: text.paragraphRange(for: NSRange(location: index, length: 0)))
            return Int(paragraph.split(separator: " ").dropFirst().first ?? "") ?? -1
        }
        let zoom = Settings.zoom
        let reading = topParagraph()
        var drift = 0
        for step: CGFloat in [1.3, 0.85, 1] {
            Settings.zoom = step
            controller.reader.refresh()
            wait(0.1)
            drift = max(drift, abs(topParagraph() - reading))
        }
        Settings.zoom = zoom
        controller.reader.refresh()
        check(reading > 100 && drift <= 1, "zooming keeps the reading position (paragraph \(reading), drift \(drift))")

        controller.toggleOutline(nil)
        wait(0.3)
        controller.toggleOutline(nil)
        wait(0.3)
        check(true, "shows and hides the outline")

        let pdf = URL(fileURLWithPath: directory).appendingPathComponent("selftest.pdf").absoluteURL
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf
        let operation = PrintableText.operation(text: controller.text, baseURL: nil, info: info, title: "selftest")
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
        let pdfSize = (try? FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int) ?? 0
        check(pdfSize > 1000, "exports a PDF (\(pdfSize / 1024) KB)")
        try? FileManager.default.removeItem(at: pdf)

        controller.window?.close()
        wait(0.3)
        check(ReaderWindowController.all.isEmpty, "closing the window releases it")

        // A relative link to another Markdown file opens it, at the linked heading.
        let other = URL(fileURLWithPath: directory).appendingPathComponent("other.md")
        write((1...80).map { "Line \($0)." }.joined(separator: "\n\n") + "\n\n## Überblick\n\nHere.\n", to: other, atomically: true)
        write("See [the target](other.md#überblick).\n", to: url, atomically: true)
        if let first = ReaderWindowController.open(url) {
            first.window?.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            wait(0.2)
            let storage = first.reader.textView.textStorage!
            let location = (storage.string as NSString).range(of: "the target").location
            if location != NSNotFound, let link = storage.attribute(.link, at: location, effectiveRange: nil) {
                _ = first.reader.textView(first.reader.textView, clickedOnLink: link, at: location)
            }
            wait(0.3)
            let second = ReaderWindowController.all.first { $0.url.lastPathComponent == "other.md" }
            second?.window?.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            check(second != nil && (second?.reader.scrollView.contentView.bounds.minY ?? 0) > 100,
                  "a relative link opens the other file at the heading")
            // [[#Heading]] scrolls within the same note.
            if let second {
                write((1...80).map { "Line \($0)." }.joined(separator: "\n\n") + "\n\n## Far Away\n\nEnd. [[#Far Away]]\n", to: other, atomically: true)
                wait(2) { second.text.contains("[[#Far Away]]") }
                second.reader.scroll(toLocation: 0)
                let storage = second.reader.textView.textStorage!
                let location = (storage.string as NSString).range(of: "Far Away", options: .backwards).location
                if location != NSNotFound, let link = storage.attribute(.link, at: location, effectiveRange: nil) {
                    _ = second.reader.textView(second.reader.textView, clickedOnLink: link, at: location)
                }
                check(second.reader.scrollView.contentView.bounds.minY > 100, "a [[#heading]] wiki link scrolls within the note")
            }
            for c in ReaderWindowController.all { c.window?.close() }
            wait(0.3)
        } else {
            check(false, "a relative link opens the other file at the heading")
        }
        try? FileManager.default.removeItem(at: other)
        try? FileManager.default.removeItem(at: url)
        print(failures == 0 ? "All self-tests passed." : "\(failures) self-tests failed.")
        return Int32(failures)
    }
}

/// A long run that keeps the reader busy and logs its memory once a minute:
/// `Marky --soak FILE MINUTES`. The file is copied to a temporary folder and edited there.
@MainActor
enum Soak {
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Opens and closes a file `count` times inside the event loop, optionally showing the outline
    /// each time, then reports how many readers are still in memory and the footprint.
    static func cycle(file: String, count: Int, outline: Bool) {
        let url = URL(fileURLWithPath: file)
        var done = 0
        print("before: \(String(format: "%.1f", Double(footprint()) / 1_048_576)) MB")
        func step() {
            guard done < count else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    print("after \(count) cycles: \(ReaderWindowController.alive) readers alive, " +
                          String(format: "%.1f MB", Double(footprint()) / 1_048_576))
                    exit(0)
                }
                return
            }
            done += 1
            guard let controller = ReaderWindowController.open(url) else { exit(1) }
            controller.window?.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            if outline { controller.toggleOutline(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // As in a click on the close button: the event's pool frees the window at once.
                autoreleasepool { controller.window?.close() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { step() }
            }
        }
        step()
    }

    /// Starts the soak inside the app's own event loop, so memory behaves as it does for a user;
    /// the app quits when the time is up.
    static func start(file: String, minutes: Double) {
        guard let original = MarkdownFile.read(URL(fileURLWithPath: file)) else { exit(1) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marky-soak-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("soak.md")
        SelfTest.write(original, to: url, atomically: true)
        guard var controller = ReaderWindowController.open(url) else { exit(1) }
        controller.window?.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        let start = Date()
        var tick = 0
        var nextLog = start
        print("minute  footprint")
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            MainActor.assumeIsolated {
                tick += 1
                if Date().timeIntervalSince(start) >= minutes * 60 {
                    timer.invalidate()
                    Settings.zoom = 1
                    controller.window?.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        print(String(format: "closed  %6.1f MB", Double(footprint()) / 1_048_576))
                        try? FileManager.default.removeItem(at: folder)
                        exit(0)
                    }
                    return
                }
                // An edit every two seconds, alternating between two versions of the file.
                SelfTest.write(tick % 2 == 0 ? original : original + "\n\nEdit \(tick): $x_{\(tick)}^2$\n", to: url, atomically: true)
                let length = (controller.reader.textView.string as NSString).length
                controller.reader.scroll(toLocation: (tick * 997) % max(1, length))
                if tick % 15 == 0 { controller.toggleOutline(nil) }
                if tick % 30 == 0 {
                    Settings.zoom = Settings.zoom == 1 ? 1.15 : 1
                    controller.reader.refresh()
                }
                if tick % 90 == 0, let reopened = { controller.window?.close(); return ReaderWindowController.open(url) }() {
                    controller = reopened
                    controller.window?.setFrameOrigin(NSPoint(x: -6000, y: -6000))
                }
                if Date() >= nextLog {
                    print(String(format: "%6.0f  %6.1f MB", Date().timeIntervalSince(start) / 60, Double(footprint()) / 1_048_576))
                    fflush(stdout)
                    nextLog = nextLog.addingTimeInterval(60)
                }
            }
        }
    }
}
