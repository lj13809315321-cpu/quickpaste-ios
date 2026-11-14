import UIKit

// MARK: - 复制成功震动反馈（独立 App 版）

/// 复制**成功**后调用（不是按下时）。
/// 开关走 LocalStore.copyHapticOn()（默认开），与「复制后移到最前」同一套本地开关。
enum NianshuFeedback {
    private static let generator = UIImpactFeedbackGenerator(style: .medium)
    private static var prepared = false
    private static var cachedOn = true
    private static var lastCheck: Double = 0

    /// 复制成功后轻震一下，确认内容真的进了剪贴板。
    static func copied() {
        let now = Date().timeIntervalSince1970
        if now - lastCheck > 2 {
            cachedOn = LocalStore.copyHapticOn()
            lastCheck = now
        }
        guard cachedOn else { return }
        if !prepared {
            prepared = true
            generator.prepare()
        }
        generator.impactOccurred()
    }
}
