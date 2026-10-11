import SwiftUI

struct BotAvatar: View {
    let bot: Bot; var size: CGFloat = 38
    private var color: Color {
        let colors: [Color] = [.indigo, .purple, .teal, .orange, .pink, .blue]
        return colors[abs(bot.name.hashValue) % colors.count]
    }
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [color.opacity(0.72), color], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(bot.initial).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }.frame(width: size, height: size).shadow(color: color.opacity(0.18), radius: 5, y: 2)
    }
}

extension Color {
    static func appAccent(_ name: String) -> Color {
        switch name { case "Purple": .purple; case "Orange": .orange; case "Pink": .pink; case "Green": .green; default: .blue }
    }
}

extension Notification.Name {
    static let toggleInfo = Notification.Name("AgentApp.toggleInfo")
    static let showPalette = Notification.Name("AgentApp.showPalette")
    static let newBot = Notification.Name("AgentApp.newBot")
}
