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

            LabeledContent("Accent Color") {
                HStack(spacing: Theme.Spacing.m) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button { theme.accent = choice } label: {
                            Circle()
                                .fill(choice.accent)
                                .frame(width: 26, height: 26)
                                .overlay {
                                    if theme.accent == choice {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(choice.onAccent)
                                    }
                                }
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(theme.accent == choice ? .isSelected : [])
                    }
                }
            }

            // Labeled explicitly: a segmented picker hides its own label.
            LabeledContent("Sidebar") {
                Picker("Sidebar", selection: $theme.sidebarStyle) {
                    ForEach(SidebarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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
