import Foundation

/// 合并同一次切 Space 里的重复重扫请求。
///
/// `activeSpaceDidChangeNotification` 在一次切换里可能连着来几条，而强制重扫不便宜；
/// 同一个 App 在 `interval` 内的后续请求被丢弃，换了 App 则立即放行。
nonisolated struct SpaceRescanGate: Sendable {
    let interval: TimeInterval
    private var last: (pid: pid_t, at: Date)?

    init(interval: TimeInterval = 0.75) {
        self.interval = interval
    }

    mutating func shouldScan(pid: pid_t, at date: Date) -> Bool {
        if let last, last.pid == pid, date.timeIntervalSince(last.at) < interval {
            return false
        }
        last = (pid, date)
        return true
    }
}

/// 一次强制重扫拿到空列表时，是否保留上一次的列表。
///
/// 切 Space 后的重扫可能碰上 App 还没把菜单栏挂回来：`hasMenuBar == false` 且没有内置
/// 目录时，结果就是空列表。把这份空结果发出去等于把用户眼前的列表清掉，所以保留旧的；
/// 而同一个 App 真的没有菜单栏、或权限被撤销时，空列表才是事实，照常发布。
nonisolated enum CatalogPublishPolicy {
    static func keepsPrevious(previousCount: Int, newCount: Int, hasMenuBar: Bool) -> Bool {
        newCount == 0 && previousCount > 0 && !hasMenuBar
    }
}
