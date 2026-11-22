import Foundation
import UserNotifications

/// 本地通知。mac 上主窗口关掉后 app 仍在菜单栏轮询，所以完成通知不需要推送服务。
enum Notifier {
    private static let authorized = Task { () -> Bool in
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(title: String, body: String, subtitle: String? = nil) {
        Task {
            guard await authorized.value else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let subtitle { content.subtitle = subtitle }
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(req)
        }
    }
}
