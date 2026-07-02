import SwiftUI

struct VEXSheetScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            VEXBackground()
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VEX VPN")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(Color.vexMuted)
                        Text(title)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.vexText)
                        Text(subtitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.vexSecondaryText)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .black))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.vexGlass)
                    .controlSize(.regular)
                }

                content

                Spacer(minLength: 0)
            }
            .padding(22)
        }
        .frame(width: 460, height: 620)
    }
}
