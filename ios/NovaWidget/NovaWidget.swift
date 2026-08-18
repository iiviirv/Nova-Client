import SwiftUI
import WidgetKit

// Home-screen widget that mirrors the Nova tunnel state. It is a separate
// process from the app, so it reads the state the app publishes into the shared
// App Group (see NovaProxyHost.publishWidgetState) and reloads when the app calls
// WidgetCenter.reloadAllTimelines(). Tapping it opens the app. It never touches
// the tunnel itself, so it needs no VPN entitlement of its own.

private let appGroup = "group.online.novaproxy.novaClient"

struct NovaEntry: TimelineEntry {
  let date: Date
  let state: String
  let label: String?
}

struct NovaProvider: TimelineProvider {
  private func read() -> NovaEntry {
    let d = UserDefaults(suiteName: appGroup)
    let state = d?.string(forKey: "nova.widget.state") ?? "disconnected"
    let label = d?.string(forKey: "nova.widget.label")
    return NovaEntry(date: Date(), state: state, label: label)
  }

  func placeholder(in _: Context) -> NovaEntry {
    NovaEntry(date: Date(), state: "disconnected", label: nil)
  }

  func getSnapshot(in _: Context, completion: @escaping (NovaEntry) -> Void) {
    completion(read())
  }

  func getTimeline(in _: Context, completion: @escaping (Timeline<NovaEntry>) -> Void) {
    // The app pushes a reload on every state change, so a single entry that
    // never expires on its own is enough; no polling.
    completion(Timeline(entries: [read()], policy: .never))
  }
}

/// The brand ribbon "N" with the cyan-to-violet gradient stroke. Drawn as a path
/// so the widget stays self-contained (no shared asset catalog).
private struct NovaMark: View {
  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width, h = geo.size.height
      Path { p in
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
          CGPoint(x: x / 100 * w, y: y / 100 * h)
        }
        p.move(to: pt(28, 22))
        p.addLine(to: pt(28, 64))
        p.addArc(center: pt(41, 64), radius: 13 / 100 * w,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: pt(54, 36))
        p.addArc(center: pt(67, 36), radius: 13 / 100 * w,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: pt(80, 78))
      }
      .stroke(
        LinearGradient(
          colors: [Color(red: 0.55, green: 0.36, blue: 0.96),
                   Color(red: 0.13, green: 0.83, blue: 0.93)],
          startPoint: .bottomLeading, endPoint: .topTrailing),
        style: StrokeStyle(lineWidth: 15 / 100 * w, lineCap: .round, lineJoin: .round))
    }
  }
}

struct NovaWidgetView: View {
  let entry: NovaEntry

  private var connected: Bool { entry.state == "connected" }

  private var statusText: String {
    switch entry.state {
    case "connected":
      if let l = entry.label, !l.isEmpty { return "Connected to \(l)" }
      return "Connected"
    case "connecting": return "Connecting…"
    case "disconnecting": return "Disconnecting…"
    default: return "Not connected"
    }
  }

  private var dotColor: Color {
    switch entry.state {
    case "connected": return Color(red: 0.20, green: 0.83, blue: 0.60)
    case "connecting", "disconnecting": return Color(red: 0.96, green: 0.77, blue: 0.32)
    default: return Color(red: 0.36, green: 0.39, blue: 0.44)
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      NovaMark().frame(width: 34, height: 34)
      VStack(alignment: .leading, spacing: 1) {
        Text("Nova")
          .font(.system(size: 15, weight: .bold))
          .foregroundColor(Color(red: 0.96, green: 0.97, blue: 0.98))
        Text(statusText)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(Color(red: 0.54, green: 0.58, blue: 0.64))
          .lineLimit(1)
      }
      Spacer()
      Circle().fill(dotColor).frame(width: 10, height: 10)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(red: 0.07, green: 0.08, blue: 0.11))
  }
}

@main
struct NovaWidget: Widget {
  let kind = "NovaWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: NovaProvider()) { entry in
      NovaWidgetView(entry: entry)
    }
    .configurationDisplayName("Nova status")
    .description("See whether Nova is connected at a glance.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
