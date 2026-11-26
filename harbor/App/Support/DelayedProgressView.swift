import SwiftUI

/// A spinner that appears only if the wait lasts. Most folders load in a
/// fraction of a second, and a spinner that flashes for that long looks
/// like a stutter.
struct DelayedProgressView: View {
    var delay: Duration = .milliseconds(400)
    @State private var visible = false

    var body: some View {
        ProgressView()
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: delay)
                withAnimation(.easeIn(duration: 0.15)) { visible = true }
            }
            .accessibilityHidden(!visible)
    }
}
