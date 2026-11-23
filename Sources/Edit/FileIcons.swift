import AppKit
import CoreText

@MainActor
enum FileIcons {
    private struct Glyph: Decodable {
        let fontCharacter: String
        let fontColor: String?
    }

    private struct Map: Decodable {
        let file: String?
        let fileNames: [String: String]
        let fileExtensions: [String: String]
        let languageIds: [String: String]
    }

    private struct Theme: Decodable {
        let iconDefinitions: [String: Glyph]
        let light: Map
    }

    private struct Associations: Decodable {
        let filenames: [String: String]
        let filenamePatterns: [String: String]
        let extensions: [String: String]
    }

    private struct Assets {
        let theme: Theme
        let base: Map
        let names: [String: String]
        let patterns: [(NSRegularExpression, Bool, String)]
        let extensions: [(String, String)]
        let font: NSFont
    }

    private static let assets: Assets? = load()
    private static var images: [String: NSImage] = [:]

    static func image(for url: URL?, appearance: NSAppearance, language: String? = nil) -> NSImage? {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let assets, let key = iconKey(for: url, dark: dark, language: language),
              let icon = assets.theme.iconDefinitions[key],
              let number = UInt32(icon.fontCharacter.dropFirst(), radix: 16), let glyph = UnicodeScalar(number)
        else { return NSImage(systemSymbolName: "doc", accessibilityDescription: nil) }
        let cacheKey = key + (dark ? ".dark" : ".light")
        if let cached = images[cacheKey] { return cached }

        let fallback = dark ? NSColor.white : NSColor.black
        let tint = icon.fontColor.flatMap { UInt32($0.dropFirst(), radix: 16) }.map {
            NSColor(srgbRed: CGFloat(($0 >> 16) & 255) / 255, green: CGFloat(($0 >> 8) & 255) / 255,
                    blue: CGFloat($0 & 255) / 255, alpha: 1)
        } ?? fallback
        let text = NSAttributedString(string: String(glyph), attributes: [.font: assets.font, .foregroundColor: tint])
        let size = NSSize(width: 17, height: 17)
        let image = NSImage(size: size, flipped: false) { rect in
            let glyphSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2))
            return true
        }
        images[cacheKey] = image
        return image
    }

    static func iconKey(for url: URL?, dark: Bool, language: String? = nil) -> String? {
        guard let assets else { return nil }
        let light = dark ? nil : assets.theme.light
        let base = assets.base
        let fallback = light?.file ?? base.file
        if let language {
            let key = language.lowercased()
            if ["solidity", "zig", "toml"].contains(key) {
                let suffix = key == "solidity" ? "sol" : key
                return light?.fileExtensions[suffix] ?? base.fileExtensions[suffix] ?? fallback
            }
            return light?.languageIds[key] ?? base.languageIds[key] ?? fallback
        }
        guard let url else { return fallback }
        let name = url.lastPathComponent.lowercased()
        if let key = light?.fileNames[name] ?? base.fileNames[name] { return key }
        for index in name.indices where name[index] == "." {
            let suffix = String(name[name.index(after: index)...])
            if let key = light?.fileExtensions[suffix] ?? base.fileExtensions[suffix] { return key }
        }
        let path = url.path.lowercased()
        let associated = assets.names[name] ?? assets.patterns.first { pattern in
            let target = pattern.1 ? path : name
            return pattern.0.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)) != nil
        }?.2 ?? assets.extensions.first { name.hasSuffix($0.0) }?.1
        if let associated {
            return light?.languageIds[associated] ?? base.languageIds[associated] ?? fallback
        }
        return fallback
    }

    private static func load() -> Assets? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Seti")
        #if SWIFT_PACKAGE
        let folder: URL?
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            folder = bundled
        } else {
            folder = Bundle.module.resourceURL?.appendingPathComponent("Seti")
        }
        #else
        let folder = bundled
        #endif
        guard let folder,
              let themeData = try? Data(contentsOf: folder.appendingPathComponent("vs-seti-icon-theme.json")),
              let associationsData = try? Data(contentsOf: folder.appendingPathComponent("language-associations.json"))
        else { return nil }
        let decoder = JSONDecoder()
        guard let theme = try? decoder.decode(Theme.self, from: themeData),
              let base = try? decoder.decode(Map.self, from: themeData),
              let associations = try? decoder.decode(Associations.self, from: associationsData)
        else { return nil }

        let url = folder.appendingPathComponent("seti.ttf") as CFURL
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
        CTFontManagerRegisterFontsForURL(url, .process, nil)
        guard let font = NSFont(name: name, size: 17) else { return nil }

        let patterns = associations.filenamePatterns.sorted { $0.key.count > $1.key.count }.compactMap { pair in
            globRegex(pair.key).map { ($0, pair.key.contains("/"), pair.value) }
        }
        let extensions = associations.extensions.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
        return Assets(theme: theme, base: base, names: associations.filenames, patterns: patterns, extensions: extensions, font: font)
    }

    private static func globRegex(_ glob: String) -> NSRegularExpression? {
        var regex = "^"
        var remainder = glob[...]
        while let character = remainder.first {
            if remainder.hasPrefix("**/") {
                regex += "(?:.*/)?"
                remainder = remainder.dropFirst(3)
            } else if remainder.hasPrefix("**") {
                regex += ".*"
                remainder = remainder.dropFirst(2)
            } else {
                switch character {
                case "*": regex += "[^/]*"
                case "?": regex += "[^/]"
                default: regex += NSRegularExpression.escapedPattern(for: String(character))
                }
                remainder = remainder.dropFirst()
            }
        }
        return try? NSRegularExpression(pattern: regex + "$")
    }
}
