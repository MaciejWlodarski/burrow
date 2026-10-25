import SwiftUI
import AppKit

/// Property wrapper wrapping SwiftUI.State<Value> directly without invoking macOS 27 SwiftUIMacros plugin
@propertyWrapper
public struct ViewState<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    public init(wrappedValue: Value) {
        self.storage = SwiftUI.State(wrappedValue: wrappedValue)
    }

    public var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    public var projectedValue: Binding<Value> {
        storage.projectedValue
    }
}

public enum FormatHelpers {
    public static func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        // Rounding to the displayed precision can reach 1024 (e.g. 1023.7 KB -> "1024 KB").
        if unitIndex > 0 && unitIndex < units.count - 1 && value.rounded() >= 1024 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) B"
        } else if value >= 100 {
            return String(format: "%.0f %@", value, units[unitIndex])
        } else if value >= 10 {
            return String(format: "%.1f %@", value, units[unitIndex])
        } else {
            return String(format: "%.2f %@", value, units[unitIndex])
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    public static func formatDate(_ date: Date) -> String {
        if date == .distantPast { return "—" }
        return dateFormatter.string(from: date)
    }

    public static func formatLatency(_ ms: Double) -> String {
        if ms < 1.0 {
            return String(format: "%.2f ms", ms)
        } else if ms < 10.0 {
            return String(format: "%.1f ms", ms)
        } else {
            return String(format: "%.0f ms", ms)
        }
    }
}

public struct VisualEffectBackground: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
