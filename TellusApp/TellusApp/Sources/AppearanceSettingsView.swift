import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = PreferenceStore(domain: .insula)
    @State private var sliderDrafts: [String: Double] = [:]

    var body: some View {
        Form {
            AppleModeBanner()
            RecoveryStatusBanner()

            Section {
                slider("Width", key: "MetricsSensorWidthScale", default: 1, range: 0.4...1.5)
                slider("Height", key: "MetricsSensorHeightScale", default: 1, range: 0.7...1.5)
                Button("Reset Island Size") {
                    _ = preferences.write(["MetricsSensorWidthScale": 1.0, "MetricsSensorHeightScale": 1.0])
                }
            } header: {
                Text("Island Size")
            } footer: {
                Text("Changes the Island shape while keeping its content size. 1.0 is the stock size. Very small heights can clip content.")
            }

            Section {
                Toggle("Use Custom Scale", isOn: boolBinding("scaleEnabled", default: false))
                slider("Width (X)", key: "RelativeScaleX", default: 1, range: 0.5...2)
                slider("Height (Y)", key: "RelativeScaleY", default: 1, range: 0.5...2)
                Button("Reset Custom Scale") {
                    _ = preferences.write(["RelativeScaleX": 1.0, "RelativeScaleY": 1.0])
                }
            } header: {
                Text("Custom Scale")
            } footer: {
                Text("Scales the Island and its content together. 1.0 is the stock size. Extreme values can distort content.")
            }

            Section {
                Toggle("Use Custom Opacity", isOn: boolBinding("transEnabled", default: false))
                slider("Opacity", key: "alpha", default: 1, range: 0...1, style: .percent)
                Button("Reset Opacity") { _ = preferences.write(["alpha": 1.0]) }
            } header: {
                Text("Opacity")
            } footer: {
                Text("Applies immediately when custom opacity is enabled. 100% is the stock appearance.")
            }

            Section {
                Toggle("Use Custom Color", isOn: boolBinding("colorEnabled", default: false))
                slider("Red", key: "red", default: 0, range: 0...1, style: .percent)
                slider("Green", key: "green", default: 0, range: 0...1, style: .percent)
                slider("Blue", key: "blue", default: 0, range: 0...1, style: .percent)
                Button("Reset Color to Black") {
                    _ = preferences.write(["red": 0.0, "green": 0.0, "blue": 0.0])
                }
            } header: {
                Text("Color")
            } footer: {
                Text("Sets the Island background color. Changes apply immediately when custom color is enabled.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { preferences.reload() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { preferences.reload() }
        }
    }

    private enum SliderStyle: Equatable { case decimal, percent }

    private func slider(
        _ title: String,
        key: String,
        default defaultValue: Double,
        range: ClosedRange<Double>,
        style: SliderStyle = .decimal
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                let value = sliderDrafts[key] ?? preferences.double(forKey: key, default: defaultValue)
                Text(style == .percent ? "\(Int((value * 100).rounded()))%" : String(format: "%.2f", value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { sliderDrafts[key] ?? preferences.double(forKey: key, default: defaultValue) },
                    set: {
                        sliderDrafts[key] = $0
                        preferences.updateSlider($0, forKey: key)
                    }
                ),
                in: range,
                onEditingChanged: { editing in
                    guard !editing, let value = sliderDrafts.removeValue(forKey: key) else { return }
                    preferences.updateSlider(value, forKey: key, finished: true)
                }
            )
        }
        .padding(.vertical, 4)
    }

    private func boolBinding(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { preferences.bool(forKey: key, default: defaultValue) },
            set: { _ = preferences.write([key: NSNumber(value: $0)]) }
        )
    }
}
