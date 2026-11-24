import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct TelegramSettingsRow: View {
  let session: TelegramSession
  let connect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "paperplane").foregroundStyle(.secondary)
        Text("Telegram").font(AppTypography.bodySemibold)
        Spacer()
        switch session.phase {
        case .ready:
          Label("Connected", systemImage: "checkmark.circle.fill")
            .font(AppTypography.caption).foregroundStyle(.green)
        case .closing:
          ProgressView().controlSize(.small)
        default:
          Button("Connect Telegram", action: connect).buttonStyle(.bordered)
        }
      }
      if session.isConnected {
        HStack {
          Text(session.accountName ?? "Connected account").lineLimit(1)
          Spacer()
          Button("Disconnect") { session.disconnect() }.disabled(session.busy)
            .controlSize(.small)
        }
        .font(AppTypography.callout)
      } else {
        Text("See what your groups and direct messages say about the asset open in Markets.")
          .font(AppTypography.caption).foregroundStyle(.secondary)
      }
      if let issue = session.issue, session.phase == .disconnected || session.isConnected {
        Text(issue).font(AppTypography.caption).foregroundStyle(.orange)
      }
    }
    .padding(16)
    .background(TerminalStyle.panel, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TerminalStyle.border))
  }
}

struct TelegramConnectionView: View {
  let session: TelegramSession
  @Environment(\.dismiss) private var dismiss
  @State private var input = ""
  @FocusState private var inputFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(session.isConnected ? "Telegram connected" : "Connect Telegram")
        .font(AppTypography.title2Semibold)
      Text("This connects your Telegram account to this Mac so tRig can find discussion for the asset you open.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      stage
      if let issue = session.issue {
        Text(issue).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if session.phase == .phone {
          Button("Use QR code") { session.requestQR() }.disabled(session.busy)
        } else if case .qr = session.phase {
          Button("Use phone instead") { Task { await session.usePhoneInstead() } }
            .disabled(session.busy)
        }
        Spacer()
        Button(session.isConnected ? "Done" : "Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .font(AppTypography.callout)
    .padding(24)
    .frame(width: 450)
    .onChange(of: session.phase) { _, _ in
      input = ""
      inputFocused = field != nil
    }
  }

  @ViewBuilder private var stage: some View {
    if let field {
      VStack(alignment: .leading, spacing: 6) {
        Text(field).font(AppTypography.calloutMedium)
        HStack {
          Group {
            if session.phase == .password {
              SecureField("Two-step verification password", text: $input)
            } else {
              TextField(field, text: $input)
            }
          }
          .textFieldStyle(.roundedBorder)
          .focused($inputFocused)
          .disabled(session.busy)
          .onSubmit(submit)
          Button("Continue", action: submit)
            .buttonStyle(.borderedProminent)
            .disabled(input.isEmpty || session.busy)
        }
      }
    } else {
      switch session.phase {
      case .disconnected:
        if session.configurationAvailable {
          Button("Try again") { session.connect() }.buttonStyle(.borderedProminent)
        } else {
          #if DEBUG
          Text("This build needs a local Telegram app configuration.")
            .foregroundStyle(.secondary)
          Button("Open configuration folder") { openConfigurationFolder() }
          #else
          Text("Telegram is unavailable in this build.")
            .foregroundStyle(.secondary)
          #endif
        }
      case .starting, .closing:
        HStack {
          ProgressView().controlSize(.small)
          Text(session.phase == .starting ? "Starting Telegram…" : "Closing Telegram…")
        }
      case .qr(let value):
        VStack(alignment: .center, spacing: 12) {
          if let image = qrImage(value) {
            Image(nsImage: image).resizable().interpolation(.none)
              .frame(width: 192, height: 192).padding(8).background(Color.white)
              .accessibilityLabel("Telegram sign-in QR code")
          }
          Text("In Telegram on your phone, open Settings → Devices → Link Desktop Device.")
            .multilineTextAlignment(.center)
          Text("Scan the code to sign in.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
      case .ready:
        Label(session.accountName ?? "Connected account", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text("Find discussions in Markets → Context. Access is read-only.")
          .foregroundStyle(.secondary)
      case .unsupported:
        Text("Finish setting up your Telegram account in the official app, then try connecting again.")
      default: EmptyView()
      }
    }
  }

  private var field: String? {
    switch session.phase {
    case .phone: "Phone number with country code"
    case .code: "Telegram sign-in code"
    case .email: "Email address"
    case .emailCode: "Email verification code"
    case .password: "Two-step verification password"
    default: nil
    }
  }

  private func submit() {
    guard !session.busy, !input.isEmpty else { return }
    session.submit(input)
    if session.phase == .password { input = "" }
  }

  private func qrImage(_ link: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(link.utf8)
    guard let value = filter.outputImage else { return nil }
    let scaled = value.transformed(by: .init(scaleX: 8, y: 8))
    guard let bitmap = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: bitmap, size: .zero)
  }

  #if DEBUG
  private func openConfigurationFolder() {
    let folder = TelegramSessionFiles.appSupport
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    NSWorkspace.shared.open(folder)
  }
  #endif
}
