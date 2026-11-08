import Foundation
import SwiftUI
// The legacy session lacks Sendable annotations. One admitted job uses its
// methods sequentially, inline in SwiftUI's supplied task, and checks its exact
// host lifetime before each use. It never reuses or directly cancels the session.
@preconcurrency import Translation

/// Native language/model APIs are reachable only through explicit sheet actions.
@available(macOS 15.0, *)
@MainActor private final class NativeLyricsLanguageCatalog {
    private var values: [String: Locale.Language] = [:]
    func load() async throws -> [LyricsTranslationLanguage] {
        let languages = await NativeLyricsLanguageQueries.supported()
        guard !languages.isEmpty, languages.count <= 256 else { return [] }
        var known: [String: Locale.Language] = [:], rows: [LyricsTranslationLanguage] = []
        for language in languages {
            let id = language.maximalIdentifier
            guard known[id] == nil else { return [] }
            known[id] = language
            rows.append(.init(id: id, name: Locale.current.localizedString(forIdentifier: id) ?? id))
        }
        values = known
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func request(_ job: LyricsTranslationJob) -> NativeLyricsTranslationRequest? {
        guard let source = values[job.pair.source], let target = values[job.pair.target] else { return nil }
        let configuration = TranslationSession.Configuration(source: source, target: target)
        return .init(job: job, source: source, target: target, configuration: configuration, lifetime: LyricsTranslationHostLifetime())
    }
}
// The legacy availability object is non-Sendable. Create and consume it wholly
// within the nonisolated async operation; only language values cross the boundary.
@available(macOS 15.0, *)
private enum NativeLyricsLanguageQueries {
    nonisolated static func supported() async -> [Locale.Language] { await LanguageAvailability().supportedLanguages }
    nonisolated static func supports(source: Locale.Language, target: Locale.Language) async -> Bool {
        let value = await LanguageAvailability().status(from: source, to: target)
        return value == .installed || value == .supported
    }
}
@available(macOS 15.0, *)
private struct NativeLyricsTranslationRequest {
    let job: LyricsTranslationJob
    let source: Locale.Language
    let target: Locale.Language
    let configuration: TranslationSession.Configuration
    let lifetime: LyricsTranslationHostLifetime
}
@available(macOS 15.0, *)
@MainActor private final class NativeLyricsTranslator: LyricsTranslating {
    private let session: TranslationSession
    private let request: NativeLyricsTranslationRequest
    init(session: TranslationSession, request: NativeLyricsTranslationRequest) { self.session = session; self.request = request }
    func supportsPair() async throws -> Bool {
        try request.lifetime.check()
        guard session.sourceLanguage?.maximalIdentifier == request.job.pair.source,
              session.targetLanguage?.maximalIdentifier == request.job.pair.target else { return false }
        let supported = await NativeLyricsLanguageQueries.supports(source: request.source, target: request.target)
        try request.lifetime.check()
        return supported
    }
    func prepare() async throws {
        try request.lifetime.check()
        try await session.prepareTranslation()
        try request.lifetime.check()
    }
    func translate(_ text: String) async throws -> LyricsTranslationResponse {
        try request.lifetime.check()
        let result = try await session.translate(text)
        try request.lifetime.check()
        return .init(text: result.targetText, sourceLanguage: result.sourceLanguage.maximalIdentifier,
                     targetLanguage: result.targetLanguage.maximalIdentifier)
    }
}

@available(macOS 15.0, *)
@MainActor struct NativeLyricsTranslationView: View {
    let controller: LyricsTranslationController
    let target: LyricsTranslationTarget
    @Environment(\.dismiss) private var dismiss
    @State private var catalog = NativeLyricsLanguageCatalog()
    @State private var source = ""
    @State private var destination = ""
    // No configuration or TranslationSession exists before explicit Translate.
    @State private var request: NativeLyricsTranslationRequest?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(LyricsTranslationText.text("Translate Lyrics")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(LyricsTranslationText.text("Done")) { close(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            if controller.target == target {
                Text(LyricsTranslationText.text("Apple translates on your Mac using shared translation models. macOS may ask permission to download languages; downloads can continue after you close this sheet. Apple may collect the app identifier, languages and performance metrics, but not the original or translated text."))
                    .font(.callout).foregroundStyle(.secondary)
                if controller.languages.isEmpty {
                    Button(LyricsTranslationText.text("Load Supported Languages")) { controller.loadLanguages(for: target) { try await catalog.load() } }
                        .disabled(controller.isBusy)
                } else {
                    Picker(LyricsTranslationText.text("Original Language"), selection: $source) {
                        Text(LyricsTranslationText.text("Choose a Language")).tag("")
                        ForEach(controller.languages) { Text(verbatim: $0.name).tag($0.id) }
                    }
                    Picker(LyricsTranslationText.text("Translate To"), selection: $destination) {
                        Text(LyricsTranslationText.text("Choose a Language")).tag("")
                        ForEach(controller.languages) { Text(verbatim: $0.name).tag($0.id) }
                    }
                    HStack {
                        Button(LyricsTranslationText.text("Translate")) {
                            guard let job = controller.begin(for: target, pair: .init(source: source, target: destination)) else { return }
                            guard let native = catalog.request(job) else { controller.cancel(target.id); return }
                            request = native
                        }.disabled(controller.isBusy || source.isEmpty || destination.isEmpty || source == destination)
                        if controller.isBusy { Button(LyricsTranslationText.text("Cancel")) { cancel() } }
                    }
                }
                result
                if controller.isBusy { Text(LyricsTranslationText.text("Wait for this request to finish before starting another. Canceling does not remove shared language downloads.")).font(.caption).foregroundStyle(.secondary) }
                if let request {
                    NativeLyricsTranslationTask(controller: controller, request: request).id(request.job.id).frame(width: 0, height: 0)
                }
            } else {
                Text(LyricsTranslationText.text("The lyrics selection changed. Close this sheet and open translation again."))
            }
        }
        .padding(24).frame(minWidth: 460, idealWidth: 600, maxWidth: 800, minHeight: 340, idealHeight: 580)
        .onChange(of: source) { _, _ in cancel() }
        .onChange(of: destination) { _, _ in cancel() }
        .onChange(of: controller.target) { _, value in if value != target { cancel() } }
        .onDisappear { close() }
    }
    @ViewBuilder private var result: some View {
        switch controller.state {
        case .loadingLanguages: ProgressView(LyricsTranslationText.text("Loading supported languages…"))
        case .preparing: ProgressView(LyricsTranslationText.text("Preparing Apple translation…"))
        case .translating: ProgressView(LyricsTranslationText.text("Translating…"))
        case let .available(text):
            Text(LyricsTranslationText.text("Untimed Translation by Apple")).font(.headline).accessibilityAddTraits(.isHeader)
            Text(LyricsTranslationText.text("Machine translation is separate from the original lyrics. Line timing and pronunciation are not supplied.")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let provider = target.source.originalProvider {
                        Text(LyricsTranslationText.text("Original Lyrics Credit")).font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: provider).font(.caption).textSelection(.enabled)
                    }
                    Text(verbatim: text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        case .unavailable: Text(LyricsTranslationText.text("This language pair or translation result is unavailable."))
        case .failed: Text(LyricsTranslationText.text("Apple translation could not finish. You can try again explicitly after the request settles."))
        case .canceled: Text(LyricsTranslationText.text("Translation canceled. The previous request may still be finishing."))
        case .idle: EmptyView()
        }
    }
    private func cancel() { request?.lifetime.revoke(); controller.cancel(target.id); request = nil }
    private func close() { request?.lifetime.revoke(); controller.close(target.id); request = nil }
}

/// A distinct immutable child per job prevents an old configuration callback
/// from being relabeled with a newer job or language pair.
@available(macOS 15.0, *)
@MainActor private struct NativeLyricsTranslationTask: View {
    let controller: LyricsTranslationController
    let request: NativeLyricsTranslationRequest
    var body: some View {
        Color.clear.translationTask(request.configuration) { session in
            await withLyricsTranslationHostLifetime(request.lifetime) {
                await controller.run(request.job, using: NativeLyricsTranslator(session: session, request: request))
            }
        }.onDisappear { request.lifetime.revoke() }
    }
}
