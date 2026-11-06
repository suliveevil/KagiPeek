import CoreGraphics

/// The anchor snapshot the panel is placed against, and the pid it belongs to.
///
/// The frames are read on a background thread and arrive after the panel has already been
/// drawn, so the cache has to answer two questions without guessing: is this a new app, and
/// is the result still about the app the panel is currently for. Keeping the pid next to
/// the frames is what makes the second question answerable.
nonisolated struct PanelAnchorCache: Equatable, Sendable {
    private(set) var pid: pid_t = 0
    private(set) var windowFrame: CGRect?
    private(set) var focusedElementFrame: CGRect?

    mutating func invalidate() {
        pid = 0
        windowFrame = nil
        focusedElementFrame = nil
    }

    /// 换 pid 或还没有窗口帧时返回 true，并记录 pid
    mutating func beginRead(pid: pid_t) -> Bool {
        guard pid == self.pid, windowFrame != nil else {
            if pid != self.pid {
                windowFrame = nil
                focusedElementFrame = nil
            }
            self.pid = pid
            return true
        }
        return false
    }

    /// pid 不匹配返回 false 且不写入（陈旧结果）
    mutating func apply(pid: pid_t, windowFrame: CGRect?, focusedElementFrame: CGRect?) -> Bool {
        guard pid == self.pid else { return false }
        self.windowFrame = windowFrame
        self.focusedElementFrame = focusedElementFrame
        return true
    }
}
