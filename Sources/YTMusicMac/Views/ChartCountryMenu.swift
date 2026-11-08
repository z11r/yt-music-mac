import SwiftUI
import YouTubeMusic

struct ChartCountryMenu: View {
    let session: AppSession

    var body: some View {
        if !session.chartCountries.isEmpty {
            Menu {
                ForEach(session.chartCountries, id: \.self) { country in
                    Button(title(country)) { session.navigate(to: .chartCountry(country)) }
                }
            } label: {
                Label(session.chartCountryLabel ?? AppLocalization.text("Chart country"), systemImage: "globe")
            }
            .disabled(session.isLoading)
            .accessibilityLabel("Chart country")
            .help("Countries offered by YouTube Music for this chart page")
        }
    }

    private func title(_ country: MusicChartCountry) -> String {
        country.code == "ZZ" ? AppLocalization.text("Global") : Locale.autoupdatingCurrent.localizedString(forRegionCode: country.code) ?? country.code
    }
}
