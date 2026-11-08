import MusicCore
import SwiftUI

struct ContentOriginBadge: View {
    let isUploaded: Bool
    var body: some View {
        if isUploaded {
            Text("Uploaded").font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
