import SwiftUI

struct SleepTimerMenu: View {
    let session: AppSession

    var body: some View {
        Menu {
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) Minutes") { session.sleepTimer.start(minutes: minutes) }
            }
            Button("End of Current Song") {
                if let occurrence = session.queue.currentOccurrence {
                    session.sleepTimer.stopAtEnd(of: occurrence)
                }
            }
            .disabled(session.queue.currentOccurrence == nil)
            Divider()
            Button("Turn Off") { session.sleepTimer.cancel() }
                .disabled(!session.sleepTimer.isArmed && !session.sleepTimer.blocksAutoplay)
        } label: {
            Label(session.sleepTimer.label, systemImage: "moon.zzz")
        }
        .accessibilityLabel("Sleep Timer")
        .accessibilityValue(session.sleepTimer.label)
        .help("Pause playback after a timer or at the end of the current song.")
    }
}
