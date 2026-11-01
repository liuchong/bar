import AppKit
import Carbon

/// Text Input Sources must be read on the main thread, before AX scanning moves to its worker.
@MainActor
enum InputSourceMenu {
    static func names() -> Set<String> {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
        return Set(sources.compactMap { source -> String? in
            guard let enabled = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled),
                  CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabled).takeUnretainedValue()),
                  let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
            return Unmanaged<CFString>.fromOpaque(name).takeUnretainedValue() as String
        })
    }
}
