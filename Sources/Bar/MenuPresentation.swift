import AppKit

/// Observe menus and popovers as well as applications that use a regular window
/// for their status item. Menu-bar hit rectangles alone are not a presentation.
struct MenuPresentation {
    let windows: [CGWindowID: CGRect]
    let transientWindows: [CGWindowID: CGRect]

    init(pids: Set<pid_t>) {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        self.init(windowInfo: list, pids: pids)
    }

    init(windowInfo list: [[String: Any]], pids: Set<pid_t>) {
        var visible: [CGWindowID: CGRect] = [:], transient: [CGWindowID: CGRect] = [:]
        for window in list.prefix(2048) {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.height > 44, frame.width > 1 else { continue }
            visible[id] = frame
            if (window[kCGWindowLayer as String] as? Int ?? 0) > 0 { transient[id] = frame }
        }
        windows = visible; transientWindows = transient
    }

    func hasNewPresentation(comparedTo baseline: MenuPresentation) -> Bool {
        windows.contains { id, frame in baseline.windows[id] != frame }
    }
    func hasNewTransientPresentation(comparedTo baseline: MenuPresentation) -> Bool {
        transientWindows.contains { id, frame in baseline.transientWindows[id] != frame }
    }
}
