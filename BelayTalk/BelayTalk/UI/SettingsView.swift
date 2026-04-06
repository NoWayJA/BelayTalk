import SwiftUI

/// Settings form for TX mode, VAD, and session preferences.
struct SettingsView: View {
    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var settings = coordinator.settings

        Form {
            Section("Transmit Mode") {
                Picker("Mode", selection: $settings.txMode) {
                    ForEach(TXMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Voice Activity Detection") {
                Picker("Sensitivity", selection: $settings.vadSensitivity) {
                    ForEach(VADSensitivity.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }

                Picker("Hang Time", selection: $settings.hangTime) {
                    ForEach(HangTime.allCases, id: \.self) { h in
                        Text(h.label).tag(h)
                    }
                }

                Picker("Wind Rejection", selection: $settings.windRejection) {
                    ForEach(WindRejection.allCases, id: \.self) { w in
                        Text(w.label).tag(w)
                    }
                }
            }
            .onChange(of: settings.vadSensitivity) { _, _ in coordinator.updateVADSettings() }
            .onChange(of: settings.hangTime) { _, _ in coordinator.updateVADSettings() }
            .onChange(of: settings.windRejection) { _, _ in coordinator.updateVADSettings() }

            Section("Session") {
                Toggle("Auto Resume", isOn: $settings.autoResume)
                Toggle("Speaker Fallback", isOn: $settings.speakerFallback)
            }
        }
        .navigationTitle("Settings")
    }
}
