import SwiftUI

/// Settings › Appearance: light or dark, accent color, sidebar and app icon.
struct AppearanceSection: View {
    @AppStorage("appearance") private var appearance: AppearanceChoice = .system
    @Bindable private var theme = ThemeSettings.shared

    var body: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack {
                    Text("Accent Color")
                    Spacer()
                    Text(theme.accent.title).foregroundStyle(.secondary)
                }
                // One row, spread evenly.
                HStack(spacing: 0) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button { theme.accent = choice } label: {
                            AccentSwatch(choice: choice, selected: theme.accent == choice)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .help(choice.title)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(theme.accent == choice ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)

            // System always uses the plain sidebar, like other Mac apps.
            if theme.accent != .system {
                // Labeled explicitly: a segmented picker hides its own label.
                LabeledContent("Sidebar") {
                    Picker("Sidebar", selection: $theme.sidebarStyle) {
                        ForEach(SidebarStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("App Icon")
                HStack(spacing: Theme.Spacing.l) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Button {
                            theme.appIcon = choice
                            choice.apply()
                        } label: {
                            VStack(spacing: Theme.Spacing.xs) {
                                MonogramIcon(choice: choice)
                                    .frame(width: 56, height: 56)
                                    .padding(3)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                                            .strokeBorder(theme.appIcon == choice ? Theme.accent : .clear, lineWidth: 2.5)
                                    }
                                Text(choice.title)
                                    .font(.caption)
                                    .foregroundStyle(theme.appIcon == choice ? .primary : .secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(choice.title) icon")
                        .accessibilityAddTraits(theme.appIcon == choice ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }
}

/// One accent in the picker. System shows the spectrum of Mac accents, since
/// its color is whatever the system is set to.
private struct AccentSwatch: View {
    let choice: AccentChoice
    let selected: Bool

    var body: some View {
        Group {
            if choice == .system {
                Circle().fill(AngularGradient(
                    colors: [.blue, .purple, .pink, .red, .orange, .yellow, .green, .blue],
                    center: .center
                ))
            } else {
                Circle().fill(choice.accent)
            }
        }
        .frame(width: 28, height: 28)
        .overlay {
            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(choice.onAccent)
                    .shadow(color: .black.opacity(choice == .system ? 0.4 : 0), radius: 1)
            }
        }
        // Always show each accent's own color. In dark mode the app uses a
        // lighter version so it stays readable, but the swatch shouldn't
        // change: Midnight should look like midnight in both modes.
        .environment(\.colorScheme, .light)
        // Outside the light override, so dark swatches keep an edge in dark mode.
        .overlay {
            Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5)
        }
        .contentShape(.circle)
    }
}
