// Select the U.S. (ABC) keyboard input source for the current login session.
//
// WHY: XCUITest synthesizes Latin-letter key events by KEYCODE. If the active
// macOS input source is non-Latin (Russian, say),
// those keycodes map through that layout — letters arrive as Cyrillic or are
// dropped entirely, while digits/symbols pass through. The visible symptom is
// typed names like "ib-uitest-vol" arriving as garbage ("--/", or stray
// Cyrillic), so every UI "create" flow that types a name silently fails.
//
// Switching to com.apple.keylayout.US (or ABC) before the UI suite makes
// XCUITest typing deterministic. Run from scripts/run-mutation-uitests.sh:
//   swift scripts/select-us-keyboard.swift
import Carbon
import Foundation

let filter = [kTISPropertyInputSourceCategory as String:
                kTISCategoryKeyboardInputSource as String] as CFDictionary
guard let list = TISCreateInputSourceList(filter, false)?
        .takeRetainedValue() as? [TISInputSource] else {
    FileHandle.standardError.write(Data("no input sources\n".utf8)); exit(1)
}
for src in list {
    guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
    let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    if id == "com.apple.keylayout.US" || id == "com.apple.keylayout.ABC" {
        let status = TISSelectInputSource(src)
        print("selected \(id) (status=\(status))")
        exit(status == noErr ? 0 : 2)
    }
}
FileHandle.standardError.write(Data("US/ABC keyboard layout not available\n".utf8))
exit(1)
