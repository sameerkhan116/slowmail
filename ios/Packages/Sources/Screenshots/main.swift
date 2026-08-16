#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import SlowmailCore
import SlowmailUI

/// Renders every screen to PNG without a simulator.
///
/// Xcode is not required to run this: `ImageRenderer` rasterises a SwiftUI view
/// tree directly, so the layout can be inspected by eye on any machine with the
/// command line tools.
///
/// Two constraints shape everything below.
///
/// Views must be constructible from plain values, because `ImageRenderer` runs
/// no app lifecycle — `.task` and `.onAppear` never fire, so anything that loads
/// asynchronously renders empty.
///
/// And the variants are light, dark, and narrow rather than the obvious
/// light/dark/large-text: macOS ignores `dynamicTypeSize` outright (a `.body`
/// label measures 18x16pt at `.large` and at `.accessibility5` alike), so an
/// accessibility-text variant here would render byte-identical to light and
/// report success no matter what the layout did. The narrow variant is the
/// honest substitute — it squeezes the same text into less width and so
/// surfaces the truncation and overflow that large type would. Dynamic Type
/// itself is unverified until this runs on a simulator; see ios/README.md.

let phone = CGSize(width: 390, height: 844)
let narrowPhone = CGSize(width: 320, height: 844)

struct Variant {
    let suffix: String
    let colorScheme: ColorScheme
    let width: CGFloat?
}

let variants = [
    Variant(suffix: "light", colorScheme: .light, width: nil),
    Variant(suffix: "dark", colorScheme: .dark, width: nil),
    Variant(suffix: "narrow", colorScheme: .light, width: narrowPhone.width),
]

@MainActor
func render(_ name: String, size: CGSize = phone, @ViewBuilder view: () -> some View) {
    let root = view()
    for variant in variants {
        let renderer = ImageRenderer(
            content: root
                .frame(width: variant.width ?? size.width, height: size.height)
                .environment(\.isRasterising, true)
                .environment(\.colorScheme, variant.colorScheme)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not render \(name)/\(variant.suffix)\n".utf8))
            exit(1)
        }
        let url = outputDirectory.appendingPathComponent("\(name)-\(variant.suffix).png")
        try? png.write(to: url)
        print("wrote \(url.lastPathComponent)")
    }
}

let outputDirectory: URL = {
    let arguments = CommandLine.arguments
    let path = arguments.count > 1 ? arguments[1] : "./screenshots"
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

MainActor.assumeIsolated {
    let fixtures = Fixtures.demo
    let now = Fixtures.referenceDate
    let people = Dictionary(uniqueKeysWithValues: fixtures.correspondents.map { ($0.id, $0) })

    let inbound = fixtures.letters.filter { !$0.isOutbound && $0.deliveredAt != nil }
    let todaysPost = inbound.filter {
        Calendar.postal.isDate($0.deliveredAt ?? .distantPast, inSameDayAs: now) || $0.isUnread
    }
    let outbound = fixtures.letters.filter { $0.isOutbound && $0.state != .revoked }

    render("onboarding") { OnboardingView() }

    render("mailbox") {
        MailboxView(letters: todaysPost, people: people, now: now, carrierExpected: nil)
    }

    render("mailbox-empty") {
        MailboxView(
            letters: [], people: people, now: now,
            carrierExpected: PostalCalendar.carrierArrival(forRecipient: "me", on: now)
        )
    }

    render("reader") {
        LetterReaderView(
            letter: inbound[0],
            from: people[inbound[0].correspondentID],
            now: now
        )
    }

    render("write") {
        WriteView(
            body: .constant(
                "The move happened in the least graceful way available. I'll spare you the inventory of what broke and tell you instead that the new kitchen gets light until about four."
            ),
            recipient: people["c-ben"],
            nextCollection: PostalCalendar.nextCollection(after: now),
            estimatedArrival: PostalCalendar.arrival(
                after: PostalCalendar.nextCollection(after: now), transit: .domestic(4))
        )
    }

    render("write-empty") {
        WriteView(
            body: .constant(""),
            recipient: people["c-kenji"],
            nextCollection: PostalCalendar.nextCollection(after: now),
            estimatedArrival: PostalCalendar.arrival(
                after: PostalCalendar.nextCollection(after: now), transit: .international(14))
        )
    }

    render("outbox") { OutboxView(letters: outbound, people: people, now: now) }

    render("correspondents") { CorrespondentsView(people: fixtures.correspondents) }

    render("correspondence") {
        CorrespondenceView(
            person: fixtures.correspondents[1],
            letters: fixtures.letters
                .filter { $0.correspondentID == "c-ben" }
                .sorted { ($0.deliveredAt ?? $0.writtenAt) < ($1.deliveredAt ?? $1.writtenAt) },
            now: now
        )
    }
}
#else
print("Screenshots only runs on macOS.")
#endif
