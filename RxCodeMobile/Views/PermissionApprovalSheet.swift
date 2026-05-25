import SwiftUI
import RxCodeSync

/// Makes the wire payload usable with SwiftUI's `.sheet(item:)`. The relay
/// guarantees `requestID` is unique per outstanding permission prompt.
extension PermissionRequestPayload: Identifiable {
    public var id: String { requestID }
}

struct PermissionApprovalSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let request: PermissionRequestPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "lock.shield")
                    .font(.title)
                Text("Permission needed")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Tool")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(request.toolName)
                    .font(.body.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Input")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(request.toolInputJSON)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                Button("Deny", role: .destructive) {
                    Task {
                        await state.respondToPermission(allow: false)
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button("Allow") {
                    Task {
                        await state.respondToPermission(allow: true)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .mobileSheetPresentation([.medium, .large])
    }
}
