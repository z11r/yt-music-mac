# Measuring resource use

Performance comparisons are pending. The measurement script records resource use
for explicitly selected processes; it does not establish a performance budget or
a claim that this app uses fewer resources than another player.

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

No playback, memory, CPU, or energy comparison has been completed by this protocol.
