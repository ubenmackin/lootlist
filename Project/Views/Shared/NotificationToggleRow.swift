import SwiftUI

struct NotificationToggleRow: View {
    private let eventType: NotificationEventType

    private let enabled: Bool

    private let pushEnabled: Bool

    private let onEnabledChange: (Bool) -> Void

    private let onPushEnabledChange: ((Bool) -> Void)?

    init(eventType: NotificationEventType,
         enabled: Bool,
         pushEnabled: Bool,
         onEnabledChange: @escaping (Bool) -> Void,
         onPushEnabledChange: ((Bool) -> Void)? = nil)
    {
        self.eventType = eventType
        self.enabled = enabled
        self.pushEnabled = pushEnabled
        self.onEnabledChange = onEnabledChange
        self.onPushEnabledChange = onPushEnabledChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            toggles
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String("\(eventType.displayName), enabled \(enabled), push \(pushEnabled)"))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: eventType.iconSystemName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32, alignment: .center)
            Text(eventType.displayName)
                .font(.headline)
            Spacer(minLength: 0)
        }
    }

    private var toggles: some View {
        VStack(spacing: 8) {
            Toggle("Enabled", isOn: Binding(
                get: { enabled },
                set: { onEnabledChange($0) }
            ))
            .tint(.accentColor)

            if let onPushEnabledChange {
                Toggle("Push", isOn: Binding(
                    get: { pushEnabled },
                    set: { onPushEnabledChange($0) }
                ))
                .tint(.accentColor)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
            }
        }
        .padding(.leading, 44)
    }
}
