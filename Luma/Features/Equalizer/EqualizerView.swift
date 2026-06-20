import SwiftUI

/// Equalizer sheet: on/off, presets, and 10 band sliders. Reads/writes the live EQManager,
/// which pushes gains into the engine's AVAudioUnitEQ.
struct EqualizerView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var eq: EQManager { app.equalizer }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Toggle(isOn: Binding(get: { eq.isEnabled }, set: { eq.setEnabled($0) })) {
                        Text("Equalizer")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .tint(Color.lumaToggle)

                    presetRow
                    bandsBlock
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
            .background(Color.lumaBackground.ignoresSafeArea())
            .navigationTitle("Equalizer")
            .lumaInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zurücksetzen") { eq.reset() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voreinstellungen")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EQManager.presets) { preset in
                        let isActive = eq.presetID == preset.id
                        Button { eq.applyPreset(preset) } label: {
                            Text(LocalizedStringKey(preset.nameKey))
                                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                                .foregroundStyle(isActive ? .black : .white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    isActive ? Color.lumaAccent : Color.white.opacity(0.1),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var bandsBlock: some View {
        VStack(spacing: 12) {
            ForEach(0..<EQManager.bandCount, id: \.self) { band in
                HStack(spacing: 12) {
                    Text(freqLabel(band))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 54, alignment: .leading)
                    Slider(
                        value: Binding(get: { eq.gains[band] }, set: { eq.setGain($0, band: band) }),
                        in: EQManager.gainRange,
                        step: 1
                    )
                    .tint(Color.lumaAccent)
                    Text("\(Int(eq.gains[band].rounded())) dB")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
        .padding(.top, 4)
        .opacity(eq.isEnabled ? 1 : 0.45)
        .disabled(!eq.isEnabled)
    }

    private func freqLabel(_ band: Int) -> String {
        let f = LumaAudioGraph.bandFrequencies[band]
        return f >= 1000 ? "\(Int(f / 1000)) kHz" : "\(Int(f)) Hz"
    }
}
