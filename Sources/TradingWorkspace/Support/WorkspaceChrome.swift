import AppKit
import SwiftUI

struct WorkspaceChrome: View {
  enum Region: Equatable {
    case toolbar, sidebar

    var material: NSVisualEffectView.Material {
      switch self {
      case .toolbar: .headerView
      case .sidebar: .sidebar
      }
    }

    var fallback: Color {
      switch self {
      case .toolbar: TerminalStyle.panel
      case .sidebar: TerminalStyle.canvas
      }
    }
  }

  let region: Region
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    if #available(macOS 26, *), !reduceTransparency {
      WindowMaterialView(material: region.material)
        .overlay(region.fallback.opacity(region == .sidebar ? 0.81 : 0.68))
        .overlay {
          switch region {
          case .sidebar:
            RadialGradient(
              colors: [TerminalStyle.accent.opacity(0.24), .clear],
              center: .init(x: 0.22, y: 0.55), startRadius: 0, endRadius: 430)
          case .toolbar:
            LinearGradient(
              stops: [
                .init(color: TerminalStyle.accent.opacity(0.22), location: 0),
                .init(color: .clear, location: 0.24),
                .init(color: TerminalStyle.accent.mix(with: .purple, by: 0.45).opacity(0.26),
                  location: 0.42),
                .init(color: .clear, location: 0.59),
                .init(color: TerminalStyle.accent.opacity(0.18), location: 1),
              ],
              startPoint: .topLeading, endPoint: .trailing)
          }
        }
        .overlay(alignment: .top) {
          if region == .toolbar { Color.white.opacity(0.18).frame(height: 1) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    } else {
      region.fallback
    }
  }
}

private struct WindowMaterialView: NSViewRepresentable {
  let material: NSVisualEffectView.Material

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
  }
}

struct TerminalGlass {
  var tint: Color? = nil
  var cornerRadius: CGFloat = 10
  var inactiveForeground: Color? = nil
}

extension View {
  @ViewBuilder
  func terminalGlass(_ style: TerminalGlass = .init(), interactive: Bool = true) -> some View {
    if #available(macOS 26, *) {
      let shape = RoundedRectangle(cornerRadius: style.cornerRadius)
      let material: Glass = style.tint == nil ? .clear : .regular
      let tint = style.tint ?? TerminalStyle.field.opacity(0.32)
      glassEffect(material.tint(tint).interactive(interactive), in: shape)
        .overlay { GlassReflection(shape: shape, emphasized: style.tint != nil) }
    } else {
      self
    }
  }

  @ViewBuilder
  func terminalGlassGroup() -> some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: 2) { self }
    } else {
      self
    }
  }

  @ViewBuilder
  func terminalControlTrack(cornerRadius: CGFloat) -> some View {
    if #available(macOS 26, *) {
      let shape = RoundedRectangle(cornerRadius: cornerRadius)
      background(.thinMaterial, in: shape)
        .overlay { GlassReflection(shape: shape, emphasized: false) }
    } else {
      self
    }
  }
}

private struct GlassReflection: View {
  let shape: RoundedRectangle
  let emphasized: Bool
  @Environment(\.appearsActive) private var appearsActive
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    Group {
      if appearsActive && !reduceTransparency {
        let highlight = emphasized ? 0.40 : 0.25
        shape
          .fill(LinearGradient(
            stops: [
              .init(color: .white.opacity(emphasized ? 0.19 : 0.09), location: 0),
              .init(color: .clear, location: 0.37),
              .init(color: .black.opacity(0.09), location: 1),
            ],
            startPoint: .top, endPoint: .bottom))
          .overlay {
            shape.strokeBorder(
              LinearGradient(
                stops: [
                  .init(color: .white.opacity(highlight), location: 0),
                  .init(color: .white.opacity(0.06), location: 0.51),
                  .init(color: .white.opacity(highlight * 0.46), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing),
              lineWidth: 1)
          }
      } else {
        shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
