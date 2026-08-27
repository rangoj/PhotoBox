import SwiftUI

extension Color {
    static let photoBoxAccent = Color(red: 0.08, green: 0.48, blue: 0.42)
    static let photoBoxWarm = Color(red: 0.86, green: 0.48, blue: 0.18)
}

struct SectionHeader: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
