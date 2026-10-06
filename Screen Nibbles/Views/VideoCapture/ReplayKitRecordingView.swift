#if os(iOS)
import SwiftUI
import ReplayKit
import UIKit

/// Uses ReplayKit's system-owned broadcast picker. Screen Nibbles never tries
/// to start screen capture programmatically; the person always confirms the
/// broadcast in Apple's UI.
struct ReplayKitBroadcastPicker: UIViewRepresentable {
    static let extensionBundleIdentifier = "com.tomaslin.Screen-Nibbles.Broadcast"

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = Self.extensionBundleIdentifier
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = Self.extensionBundleIdentifier
        uiView.showsMicrophoneButton = false
    }
}

/// A compact, system-pattern recording guide. The primary path stays entirely
/// inside ReplayKit while the Control Center long-press flow remains available.
struct ReplayKitRecordingView: View {
    @Environment(\.dismiss) private var dismiss

    private var sharedStorageAvailable: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BroadcastRecordingInbox.groupID
        ) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Capture a scrolling screen")
                            .font(.title2.bold())
                        Text("Screen Nibbles records the screen with ReplayKit, saves the video locally, and turns settled scroll positions into stitchable frames when you return.")
                            .foregroundStyle(.secondary)
                    }

                    GroupBox {
                        VStack(spacing: 14) {
                            ReplayKitBroadcastPicker()
                                .frame(width: 56, height: 56)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("replaykitBroadcastPicker")
                                .allowsHitTesting(sharedStorageAvailable)
                                .opacity(sharedStorageAvailable ? 1 : 0.45)

                            Text("Tap Apple’s broadcast button, confirm **Screen Nibbles**, then switch to the content you want to capture.")
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)

                            Label(
                                sharedStorageAvailable ? "ReplayKit storage is ready" : "Shared recording storage is unavailable",
                                systemImage: sharedStorageAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(sharedStorageAvailable ? .green : .orange)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    } label: {
                        Label("Quick Start", systemImage: "record.circle")
                    }
                    .accessibilityIdentifier("replaykitQuickStart")

                    VStack(alignment: .leading, spacing: 14) {
                        Text("From Control Center")
                            .font(.headline)
                        instruction(1, "Open Control Center and touch and hold Screen Recording.")
                        instruction(2, "Choose Screen Nibbles, then tap Start Broadcast.")
                        instruction(3, "Close Control Center and scroll through the content. Briefly pause at positions you want preserved.")
                        instruction(4, "Stop with Apple’s red recording indicator or the Screen Recording control, then return to Screen Nibbles.")
                    }

                    Label("Microphone audio is not needed. The broadcast extension stores video frames only, and recordings stay on the device.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !sharedStorageAvailable {
                        Text("This build is missing the shared App Group entitlement needed by the ReplayKit extension. Re-sign the app with the Screen Nibbles App Group enabled for both the app and broadcast extension before recording.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Record Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 28, height: 28)
                .background(.secondary.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }
}
#endif
