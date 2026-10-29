//
//  AboutWindow.swift
//  DriveGuard
//

import SwiftUI

/// Everything the About window says. Edit the text here; the layout below picks it up.
enum AboutInfo {
    /// Shown under the app name.
    static let tagline = "Step away. Your drives stay safe."

    /// A short paragraph about the app.
    static let summary = "DriveGuard is a free, open-source menu bar app that safely unmounts your external drives when you step away, so your Mac can sleep and your backups stay clean."

    /// Lines near the bottom, such as who made it. Remove a line to hide it.
    static let credits: [String] = [
        "Vault Studio, an open-source developer",
        "Made by Donald Stibich",
        "Free and open source, under the GNU General Public License v3",
    ]

    /// The studio's website, shown as a link under the credits.
    static let website = URL(string: "https://vaultstudio.dev")!
    static let websiteTitle = "vaultstudio.dev"

    /// The license the app is released under, read on the GNU website.
    static let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    static let licenseTitle = "GNU General Public License v3"
}

/// DriveGuard > About DriveGuard. The text lives in `AboutInfo` above.
struct AboutWindow: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)

            VStack(spacing: 4) {
                Text("DriveGuard")
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(AboutInfo.tagline).foregroundStyle(.secondary)
                Text(version).font(.caption).foregroundStyle(.tertiary)
            }

            Text(AboutInfo.summary)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if !AboutInfo.credits.isEmpty {
                VStack(spacing: 2) {
                    ForEach(AboutInfo.credits, id: \.self) { Text($0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
                .multilineTextAlignment(.center)
            }

            Link(destination: AboutInfo.website) {
                Label(AboutInfo.websiteTitle, systemImage: "globe")
                    .font(.callout)
            }
            .help("Open the Vault Studio website")

            Link(destination: AboutInfo.licenseURL) {
                Label(AboutInfo.licenseTitle, systemImage: "doc.text")
                    .font(.callout)
            }
            .help("Read the license DriveGuard is released under, on the GNU website")
        }
        .padding(28)
        .frame(width: 360)
    }
}
