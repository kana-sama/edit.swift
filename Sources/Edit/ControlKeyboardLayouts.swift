import Carbon
import Foundation

@MainActor
struct ControlKeyboardLayouts {
    private var sources: [TISInputSource] = []
    private var keyboardType: UInt32 = 0
    private var firstCharacters: [Character: Character] = [:]
    private var secondCharacters: [Character: Character] = [:]

    mutating func alternatives(for query: String) -> [Character: Character] {
        let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout] as CFDictionary
        guard var enabled = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              enabled.count == 2 else { return [:] }
        if let selected = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), enabled[1] === selected {
            enabled.swapAt(0, 1)
        }
        let type = UInt32(LMGetKbdType())
        if sources != enabled || keyboardType != type {
            sources = enabled
            keyboardType = type
            let first = Self.keyCharacters(in: enabled[0], keyboardType: type)
            let second = Self.keyCharacters(in: enabled[1], keyboardType: type)
            firstCharacters = Self.replacements(from: first, to: second)
            secondCharacters = Self.replacements(from: second, to: first)
        }

        // Letters unique to one layout disambiguate shared punctuation in pasted queries.
        // When both are equally likely, interpret the query using the selected layout.
        var balance = 0
        for character in query where character.isLetter {
            if firstCharacters[character] != nil { balance += 1 }
            if secondCharacters[character] != nil { balance -= 1 }
        }
        return balance < 0 ? secondCharacters : firstCharacters
    }

    private static func replacements(from source: [Character?], to target: [Character?]) -> [Character: Character] {
        var characters: [Character: Character] = [:]
        for (from, to) in zip(source, target) {
            guard let from, let to, characters[from] == nil else { continue }
            characters[from] = to
        }
        return characters
    }

    private static func keyCharacters(in source: TISInputSource, keyboardType: UInt32) -> [Character?] {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [] }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        return withExtendedLifetime(data) {
            var buffer = [UniChar](repeating: 0, count: 16)
            return [0, UInt32(shiftKey >> 8)].flatMap { modifiers in
                (0..<128).map { code -> Character? in
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                                                keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                                &deadKeyState, buffer.count, &length, &buffer)
                    guard status == noErr else { return nil }
                    let output = String(decoding: buffer.prefix(length), as: UTF16.self)
                    guard let character = output.first, output.count == 1,
                          character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol
                    else { return nil }
                    return character
                }
            }
        }
    }
}
