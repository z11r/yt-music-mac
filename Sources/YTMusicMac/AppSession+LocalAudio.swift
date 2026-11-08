import Foundation
import MusicCore

extension AppSession {
    var localAudioLibraryOwner: LocalAudioLibraryOwner? {
        guard acceptsProfileActions, !isSceneCheck, let resources = localAudioResources else { return nil }
        return .init(profileStorageID: resources.context.websiteDataIdentifier,
                     activationID: playbackProfileGeneration, accountGeneration: accountGeneration)
    }

    func configureLocalAudioLibrary() {
        guard let resources = localAudioResources, let owner = localAudioLibraryOwner else { return }
        let actions = LocalAudioLibraryQueueActions<LocalAudioQueueTarget>(capture: { [weak self] owner in
            guard let self, self.localAudioLibraryOwner == owner else { return nil }
            return self.localAudioQueueTarget
        }, isCurrent: { [weak self] target, owner in
            guard let self else { return false }
            return self.localAudioLibraryOwner == owner && self.localAudioQueueTarget == target
        }, add: { [weak self] tracks, target in
            self?.acceptLocalAudio(tracks, target: target, play: false) == true
        }, play: { [weak self] tracks, target in
            self?.acceptLocalAudio(tracks, target: target, play: true) == true
        })
        installLocalAudioLibrary(LocalAudioLibraryController(owner: owner, store: resources.store,
            profiles: resources.profiles, references: resources.references,
            picker: NativeLocalAudioLibraryPicker(),
            probe: NativeLocalAudioImportProbe(mode: .ordinary, bookmarks: resources.bookmarks), actions: actions,
            isCurrent: { [weak self] in self?.localAudioLibraryOwner == $0 }))
    }

    func renewLocalAudioLibraryOwnership() {
        let generation = accountGeneration
        guard let library = localAudioLibrary else { return }
        Task { [weak self] in
            await library.waitForIdle()
            guard let self, self.acceptsProfileActions, self.accountGeneration == generation,
                  let owner = self.localAudioLibraryOwner else { return }
            library.resume(owner: owner)
        }
    }

    private var localAudioQueueTarget: LocalAudioQueueTarget? {
        guard acceptsProfileActions else { return nil }
        return .init(profile: playbackProfileGeneration, account: accountGeneration,
                     queueRevision: queue.revision, occurrence: queue.currentOccurrence)
    }

    private func acceptLocalAudio(_ tracks: [Track], target: LocalAudioQueueTarget, play: Bool) -> Bool {
        guard acceptsProfileActions, localAudioLibraryOwner != nil,
              localAudioQueueTarget == target, !tracks.isEmpty, tracks.count <= 2_000,
              tracks.allSatisfy({ $0.hasLocalAudioSource && (try? $0.validateLocalAudioSource()) != nil }) else { return false }
        if play { playTracks(tracks) }
        else { addToQueue(tracks) }
        return true
    }
}
