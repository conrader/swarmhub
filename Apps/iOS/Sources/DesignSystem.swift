import SwiftUI

struct AgentMark: View {
    var color: String = "blue"
    var size: CGFloat = 40
    private var fill: Color {
        switch color {
        case "orange": Color(red: 0.87, green: 0.67, blue: 0.50)
        case "green": Color(red: 0.66, green: 0.75, blue: 0.57)
        case "purple": Color(red: 0.71, green: 0.64, blue: 0.80)
        default: Color(red: 0.68, green: 0.73, blue: 0.87)
        }
    }
    var body: some View {
        RoundedRectangle(cornerRadius: color == "purple" ? size / 2 : size * 0.28)
            .fill(fill).overlay {
                HStack(spacing: size * 0.20) {
                    Capsule().frame(width: size * 0.065, height: size * 0.11)
                    Capsule().frame(width: size * 0.065, height: size * 0.11)
                }.foregroundStyle(Color(red: 0.15, green: 0.18, blue: 0.21))
            }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct AvailabilityNote: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EmptyDestination: View {
    let title: String
    let symbol: String
    let description: String
    var body: some View { ContentUnavailableView(title, systemImage: symbol, description: Text(description)) }
}
