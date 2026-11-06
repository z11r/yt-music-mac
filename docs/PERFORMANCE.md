# Measuring resource use

A short local comparison is recorded below. It does not establish a performance
budget or a general resource-use advantage. The public sampler described later
uses `ps`; the comparison used cumulative CPU and memory counters instead.

## November 6, 2026 comparison

This prototype used more CPU during playback and had higher RSS in these short
runs. Its physical footprint was lower, and it used less CPU while paused. The
results identify work to do before setting performance targets.

Both apps were optimized arm64 builds on an M5 Pro Mac (24 GiB RAM, macOS 26.6,
build 25G72), built with Xcode 27.2 and Swift 6.4.2. YT Music for Mac was
[`990e79c`](https://github.com/z11r/yt-music-mac/commit/990e79c3ee5217e29b5f4f9ff2bc5d3cd17a7b3b).
Kaset was built from
[`6a20e60`](https://github.com/sozercan/kaset/commit/6a20e60c5dfd552a22e84f36daeef53f94f1ee41)
with separate app, preference, Keychain, and storage identifiers. Automatic
update checks were disabled to retain that revision. Its playback code was
unchanged. This is an isolated source-build comparison, not a stock-release test.

Both sessions used Premium accounts, one-song queues with public video ID
`dQw4w9WgXcQ`, and 50% app volume. Only one app played at a time. Each playback
trial required an advancing position, then 15 seconds of warm-up and 30 seconds
of sampling. Both apps were paused for idle measurements. They remained in the
background and were not hidden at the recorded checkpoints. Low Power Mode was
off and thermal state was nominal.

The battery group contains two valid playback trials per app and three paused
trials per app. Values below are medians of the per-trial averages. CPU uses
whole-window counter deltas; memory uses 31 snapshots per trial. The sums include
the app and all attributed WebKit processes. 100% CPU means one busy core;
1 MiB is 1,048,576 bytes.

| Battery workload | App | Trials | CPU (%) | Physical footprint (MiB) | RSS (MiB) |
| --- | --- | ---: | ---: | ---: | ---: |
| Playback | YT Music for Mac | 2 | 8.90 | 639.6 | 987.3 |
| Playback | Kaset baseline | 2 | 7.30 | 716.7 | 624.1 |
| Paused | YT Music for Mac | 3 | 1.04 | 523.9 | 743.9 |
| Paused | Kaset baseline | 3 | 3.03 | 639.4 | 626.0 |

The battery playback CPU ranges were 8.69–9.11% for YT Music for Mac and
7.07–7.53% for Kaset. Paused CPU ranges were 0.75–1.34% and 2.39–3.67%, respectively.
Physical footprint and RSS use different accounting; neither selected-process
sum is unique system RAM. A lower footprint alongside higher RSS is possible.
Battery playback footprint averages ranged from 600.5–678.6 MiB for this app and
716.7–716.8 MiB for Kaset; RSS averages ranged from 985.5–989.0 MiB and
620.2–628.0 MiB. The app process alone used 1.37% CPU and 93.7 MiB of footprint,
versus Kaset's 0.88% and 150.6 MiB. Most measured CPU and footprint came from the
attributed WebKit processes.

### Power change and excluded attempts

The planned playback order was YT Music for Mac, Kaset, Kaset, YT Music for Mac,
YT Music for Mac, Kaset. The fifth attempt became foreground during sampling;
the sixth paused during warm-up. Both attempts were retained and excluded from
the valid comparison. The cause of the Kaset pause was not established.

A supplemental pair after the paused trials passed its checks, but the Mac had
switched to AC power. These single trials are kept separate; pooling them with
the battery group would mix power conditions and cache histories.

| AC playback, one trial each | CPU (%) | Physical footprint (MiB) | RSS (MiB) |
| --- | ---: | ---: | ---: |
| YT Music for Mac | 10.16 | 657.7 | 872.7 |
| Kaset baseline | 5.67 | 723.9 | 610.0 |

An earlier preflight on `c41fa27` stopped before resource sampling: the service
reset volume and the playback bridge kept a false buffering flag while time
advanced. Both defects were reproduced and fixed before the measured revision.
A successful pilot on `990e79c` is also excluded from the table above.

### Measurement limits

The local harness read `proc_pid_rusage` counters, converted CPU Mach ticks using
the host timebase, and checked PID identity, ownership, and process sets before
and after sampling. WebKit responsibility attribution used a private OS query;
shared services may be omitted. YT Music for Mac had two attributed WebContent
processes, a networking process, and a GPU process. Kaset had one WebContent
process plus networking and GPU. Both content processes were included without
assuming their roles.

Native status was checked at the start, 10 seconds, 20 seconds, and end. Position
advance confirms reported playback, not audible output or the absence of short
stalls. Kaset's status API does not report buffering or playback errors; those
fields were treated as unavailable. Raw local records contain counters and
filtered state, not credentials, account identities, or listening histories.

Window geometry, occlusion, codec, bitrate, other desktop activity, and feature
parity were not controlled. Sessions and caches were already warm. The sample is
small and covers one Mac and one song. It does not measure battery life, cold
launch, scrolling, long-term memory growth, or older-Mac compatibility. Later
resume-recovery fixes have not been rebenchmarked. Playback CPU, RSS, and the
additional WebContent process need investigation before making wider claims.

## Collect a short sample

Build and launch a release app, then find its PID in Activity Monitor. Identify
the WebKit processes that belong to that app before adding them to a run.

```sh
Scripts/measure-resources.sh \
  --app-pid 12345 \
  --webkit-pid 12346 \
  --webkit-pid 12347 \
  --samples 15 \
  --interval 2 \
  --output /tmp/yt-music-playback.csv
```

Replace every example PID with a current value. The output path must be new. The
default is 15 samples spaced two seconds apart, starting immediately: 28 seconds
of scheduled waits, plus sampling overhead. Counts are limited to 1–300, intervals
to 1–30 whole seconds, and scheduled waits to 900 seconds. Up to 16 distinct WebKit
PIDs can be supplied. Only processes owned by the current user are accepted.

Each CSV sample contains one row per selected process and a `total` row. The
columns are UTC timestamp, sample number, role, PID, executable name, RSS in KiB,
`ps` CPU percentage, and status. The script records no command-line arguments,
track titles, account information, browser URLs, or application logs. It creates
the output with private file permissions and does not overwrite existing files.

If a selected process exits or changes identity, the script records an incomplete
sample and stops. Repeat the ownership check and start a new run with the new
PIDs. Do not splice replacement processes into an old series without labeling
the change. The script does not search for processes or attach to replacements.

## Choose the process group

In Activity Monitor, enable the PID column and inspect the app's process group.
View → All Processes, Hierarchically helps show parent/child relationships; the
process information window provides further details. WebKit helpers can be
managed by system services, so a parent PID alone may not establish which app is
responsible. Use the app grouping or responsible-application information available
on that macOS version to confirm ownership.
[Activity Monitor process views](https://support.apple.com/guide/activity-monitor/actmntr1001/mac)

Include the app and its confirmed WebContent, networking, and GPU helpers when
present. A WebKit name only identifies the executable; it does not prove ownership.
Never add every WebKit process on the Mac. If ownership remains uncertain, omit
that PID and label the result incomplete. Record the selected roles and PIDs with
the run. Helpers may start, stop, or be replaced during navigation.

## Read the numbers correctly

- `rss_kib` is the resident set size reported by macOS `ps`, in 1024-byte units.
  Summing RSS can count shared resident pages more than once. The `total` row is
  the sum of selected processes, not unique physical memory consumed by the app.
- `ps_cpu_percent_decaying_average` is the `ps` decaying CPU average over up to
  roughly one minute, not CPU used only during the sampling interval. It lags
  changes and can exceed 100%. Allow time between workloads and keep the same
  sampling schedule in every comparison. See `man ps` on the measured Mac.
- Physical footprint uses different accounting, including memory charged to the
  process such as dirty and compressed memory. It is not interchangeable with
  RSS. Record the tool, metric name, units, and selected processes when measuring
  footprint in Xcode or Instruments; do not relabel this CSV as footprint data.
  Apple's [memory overview](https://developer.apple.com/videos/play/wwdc2018/416/)
  explains these distinctions and the VM Tracker instrument.

For memory growth, use Instruments Allocations and VM Tracker with the relevant
process selected. Mark the workload boundaries and distinguish temporary peaks
from memory retained after the workload ends. A heap allocation total is another
metric, not an RSS replacement.
[Gathering memory information](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use)

For energy, first use Activity Monitor's Energy pane. Energy Impact is a relative
indicator, not a watt or battery-life measurement. Record power source, display
brightness, thermal state, and App Nap state with the workload.
[Activity Monitor energy measurements](https://support.apple.com/guide/activity-monitor/actmntr43697/mac)

Use Instruments manually to investigate CPU work, wakeups, and available power
metrics on the target Mac. Select the intended app; keep system-wide power readings
separate from app-attributed readings. Power Profiler availability and reported
metrics depend on the selected device and tool version. Record those details and
label unavailable measurements instead of substituting CPU percentage for energy.
[Apple's Power Profiler workflow](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)

## Compare with Kaset

Use the pinned Kaset revision
[`6a20e60c5dfd552a22e84f36daeef53f94f1ee41`](https://github.com/sozercan/kaset/commit/6a20e60c5dfd552a22e84f36daeef53f94f1ee41)
and record the YT Music for Mac commit alongside it. Build both in release mode
for the same native architecture. Run them separately on the same Mac and macOS
build, with the same account entitlements, queue, audio output, app volume, network,
window size, and power conditions. Sign in normally in each app; never transfer
cookies or reuse another app's storage.

1. Record the machine model, memory, architecture, OS build, toolchain, commit,
   build configuration, and relevant feature settings. Keep Intel and Apple
   silicon results separate. Turn optional effects or integrations on only when
   both runs use the same setting, or record the difference.
2. Choose a fixed queue and browsing route. Visit the shelves once to load artwork,
   then wait for network activity and CPU use to settle. Record this warm-up
   procedure. Measure cold launch and first artwork loading as separate workloads.
3. Capture paused idle with the same screen visible. Then capture continuous
   playback without interaction, followed by the same scrolling route and queue
   operations. Keep video visibility and playback mode matched. Use a separate
   CSV for each workload and wait between transitions because `ps` CPU averages
   retain recent activity.
4. Repeat each workload at least three times and alternate app order. Record
   buffering, ads, track transitions, network failures, and helper restarts as
   conditions that may explain variation; do not silently discard inconvenient
   runs. Keep private listening details out of public results.
5. Report per-process results and the selected-process aggregate, sample count,
   median, range, and observed maximum. Keep raw CSVs with the local run notes.
   Use Instruments for short CPU spikes or frame hitches that this sampler cannot
   resolve. Establish budgets only after repeatable baselines exist.

The comparison above is a narrower background-playback check. The complete
matched-window, browsing, long-session, and energy protocol remains pending.
