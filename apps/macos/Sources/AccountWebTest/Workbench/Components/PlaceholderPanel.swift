import SwiftUI

struct PlaceholderPanel: View {
  let title: String
  let systemImage: String
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 30, weight: .light))
      Text(title).font(.headline)
      Text(message)
        .font(.callout)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 300)
    }
    .foregroundStyle(.secondary)
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
