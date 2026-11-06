#!/bin/bash
set -euo pipefail
export LC_ALL=C
umask 077

usage() {
  cat <<'USAGE'
Usage: Scripts/measure-resources.sh --app-pid PID --output FILE.csv
       [--webkit-pid PID ...] [--samples COUNT] [--interval SECONDS]

Records only the explicitly selected processes. No process discovery is performed.
Defaults: 15 samples, 2 seconds between samples; first sample is immediate.
Limits: 1-300 samples, 1-30 seconds, at most 900 seconds of scheduled waits,
and up to 16 distinct WebKit PIDs. The output file must not already exist.

RSS is recorded in KiB. ps %CPU is a decaying average, not an instantaneous
measurement. The aggregate covers only the app and the selected WebKit PIDs.
USAGE
}

fail() {
  printf 'Resource measurement: %s\n' "$1" >&2
  exit 1
}

integer() {
  [[ "$1" =~ ^[1-9][0-9]{0,8}$ ]]
}

app_pid=""
output=""
samples=15
interval=2
webkit_pids=()
while (($#)); do
  case "$1" in
    --app-pid|--webkit-pid|--output|--samples|--interval)
      (($# >= 2)) || fail "An option is missing its value."
      case "$1" in
        --app-pid)
          [[ -z "$app_pid" ]] || fail "Provide --app-pid only once."
          integer "$2" || fail "The app PID must be a positive decimal integer."
          app_pid="$2"
          ;;
        --webkit-pid)
          integer "$2" || fail "Each WebKit PID must be a positive decimal integer."
          webkit_pids+=("$2")
          ;;
        --output)
          [[ -z "$output" && -n "$2" ]] || fail "Provide one nonempty output path."
          output="$2"
          ;;
        --samples)
          integer "$2" || fail "The sample count must be a positive decimal integer."
          samples="$2"
          ;;
        --interval)
          integer "$2" || fail "The interval must be a positive whole number of seconds."
          interval="$2"
          ;;
      esac
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option. Use --help for usage." ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || fail "This script requires macOS ps."
[[ -n "$app_pid" && -n "$output" ]] || fail "Both --app-pid and --output are required."
((samples <= 300 && interval <= 30)) || fail "Sample count or interval exceeds its limit."
(((samples - 1) * interval <= 900)) || fail "Scheduled sampling waits must not exceed 900 seconds."
((${#webkit_pids[@]} <= 16)) || fail "Select at most 16 WebKit processes."
[[ ! -e "$output" && ! -L "$output" ]] || fail "The output path already exists; choose a new file."
[[ -d "$(dirname "$output")" ]] || fail "The output directory does not exist."

pids=("$app_pid")
roles=(app)
for pid in "${webkit_pids[@]+"${webkit_pids[@]}"}"; do
  for existing in "${pids[@]}"; do
    [[ "$pid" != "$existing" ]] || fail "Each selected PID must be unique."
  done
  pids+=("$pid")
  roles+=(webkit)
done

owner_uid="$(id -u)"
identities=()
names=()

# Query only one selected PID. comm excludes command-line arguments; only its
# basename is retained. Start time and name help detect PID reuse during a run.
read_process() {
  local pid="$1" metadata command_path process_uid weekday month day clock year
  metadata="$(/bin/ps -p "$pid" -o uid= -o rss= -o %cpu= -o lstart= -o comm= 2>/dev/null)" || return 1
  read -r process_uid process_rss process_cpu weekday month day clock year command_path <<< "$metadata"
  [[ "$process_uid" == "$owner_uid" ]] || return 1
  [[ "$process_rss" =~ ^[0-9]+$ && "$process_cpu" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  [[ -n "$year" && -n "$command_path" ]] || return 1
  process_name="${command_path##*/}"
  # Executable names are metadata, never page titles or process arguments.
  [[ "$process_name" =~ ^[[:alnum:]_][[:alnum:]_.\ -]*$ ]] || return 1
  process_identity="$process_uid|$weekday $month $day $clock $year|$process_name"
}

for index in "${!pids[@]}"; do
  read_process "${pids[$index]}" || fail "A selected PID is unavailable, has unexpected metadata, or belongs to another user."
  if [[ "${roles[$index]}" == webkit ]]; then
    [[ "$process_name" == com.apple.WebKit.* || "$process_name" == WebKit.* ]] ||
      fail "A --webkit-pid does not identify a WebKit executable."
  fi
  identities+=("$process_identity")
  names+=("$process_name")
done

# noclobber also protects against an output file appearing after validation.
set -C
exec 3> "$output" || fail "Could not create the output file."
set +C
trap 'printf "Resource measurement interrupted; the CSV may be incomplete.\n" >&2; exit 130' INT
trap 'printf "Resource measurement stopped; the CSV may be incomplete.\n" >&2; exit 143' TERM
printf 'timestamp_utc,sample,role,pid,process_name,rss_kib,ps_cpu_percent_decaying_average,status\n' >&3

for ((sample = 1; sample <= samples; sample++)); do
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  total_rss=0
  total_cpu=0
  for index in "${!pids[@]}"; do
    if ! read_process "${pids[$index]}" || [[ "$process_identity" != "${identities[$index]}" ]]; then
      printf '%s,%s,%s,%s,"%s",,,unavailable_or_changed\n' \
        "$timestamp" "$sample" "${roles[$index]}" "${pids[$index]}" "${names[$index]}" >&3
      printf '%s,%s,total,,selected_processes,,,incomplete\n' "$timestamp" "$sample" >&3
      printf 'Resource measurement stopped: a selected process exited or changed. Choose current PIDs for a new run.\n' >&2
      exit 2
    fi
    printf '%s,%s,%s,%s,"%s",%s,%s,ok\n' \
      "$timestamp" "$sample" "${roles[$index]}" "${pids[$index]}" \
      "$process_name" "$process_rss" "$process_cpu" >&3
    total_rss=$((total_rss + process_rss))
    total_cpu="$(awk -v total="$total_cpu" -v value="$process_cpu" 'BEGIN { printf "%.1f", total + value }')"
  done
  printf '%s,%s,total,,selected_processes,%s,%s,ok\n' "$timestamp" "$sample" "$total_rss" "$total_cpu" >&3
  if ((sample < samples)); then sleep "$interval"; fi
done

exec 3>&-
printf 'Recorded %s samples for %s selected processes. RSS is KiB; CPU is the ps decaying average.\n' \
  "$samples" "${#pids[@]}"
