import RxCodeCore
import SwiftUI

struct HookContextMenuItems: View {
    let items: [HookMenuItem]

    var body: some View {
        ForEach(items) { item in
            Button(role: item.role) {
                item.action()
            } label: {
                Label {
                    Text(item.title)
                } icon: {
                    Image(systemName: item.systemImage)
                }
            }
        }
    }
}
