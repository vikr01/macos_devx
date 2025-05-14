#!/bin/zsh

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
json_file="$SCRIPT_DIR/config.json"
pidfile="$SCRIPT_DIR/.redshift_scheduler.pid"
logfile="$SCRIPT_DIR/redshift.log"

is_running() {
  [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

safe_apply_redshift() {
  local temp=$1
  redshift -O "$temp" > /dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    echo "ERROR: redshift -O $temp failed" >&2
    exit 1
  fi
}

safe_clear_redshift() {
  pkill -x redshift > /dev/null 2>&1
}

stop_scheduler() {
  if is_running; then
    echo "Stopping redshift scheduler..."
    kill -TERM "$(cat "$pidfile")" 2>/dev/null
    rm -f "$pidfile"
  else
    echo "No scheduler running."
  fi
  safe_clear_redshift
  echo
  exit 0
}

start_scheduler() {
  if is_running; then
    echo "Scheduler already running."
    echo
    exit 0
  fi

  (
    trap 'kill 0; exit' TERM

    bright=$(jq -r '.bright' "$json_file")
    to_night=$(jq -r '.transition_to_night' "$json_file")
    night=$(jq -r '.night' "$json_file")
    to_bright=$(jq -r '.transition_to_bright' "$json_file")
    redshift_interval=$(jq -r '.redshift_apply_interval_minutes' "$json_file")
    override_interval=$(jq -r '.override_check_interval_minutes' "$json_file")

    expected_temp=6500
    last_applied_temp=0

    time_to_minutes() {
      echo "$1" | awk -F: '{ print ($1 * 60) + $2 }'
    }

    apply_redshift() {
      now_min=$(date +%H | awk '{print $1 * 60}')
      now_min=$(( now_min + $(date +%M) ))

      bright_min=$(time_to_minutes "$bright")
      to_night_min=$(time_to_minutes "$to_night")
      night_min=$(time_to_minutes "$night")
      to_bright_min=$(time_to_minutes "$to_bright")

      interpolate_temp() {
        local start_min=$1 end_min=$2 start_k=$3 end_k=$4
        local adj_now=$now_min

        if (( end_min < start_min )); then
          end_min=$(( end_min + 1440 ))
          if (( adj_now < start_min )); then
            adj_now=$(( adj_now + 1440 ))
          fi
        fi

        local span=$(( end_min - start_min ))
        local pos=$(( adj_now - start_min ))
        echo $(( start_k + (end_k - start_k) * pos / span ))
      }

      if (( night_min <= now_min || now_min < bright_min )); then
        expected_temp=1000
      elif (( bright_min <= now_min && now_min < to_bright_min )); then
        expected_temp=$(interpolate_temp "$bright_min" "$to_bright_min" 1000 6500)
      elif (( to_night_min <= now_min && now_min < night_min )); then
        expected_temp=$(interpolate_temp "$to_night_min" "$night_min" 6500 1000)
      else
        expected_temp=6500
      fi

      if [[ "$expected_temp" -ne "$last_applied_temp" ]]; then
        safe_apply_redshift "$expected_temp"
        echo "[$(date)] Applied temperature: $expected_temp"
        last_applied_temp=$expected_temp
      fi
    }

    check_override() {
      current=$(redshift -p 2>/dev/null | awk '/Color temperature/ {print $3}' | cut -dK -f1)
      if [[ -z "$current" || "$current" -eq 0 ]]; then return; fi

      local delta=$(( expected_temp - current ))
      if (( delta < -300 || delta > 300 )); then
        echo "[$(date)] Override detected: expected $expected_temp, found $current. Reapplying..." >> "$logfile"
        safe_apply_redshift "$expected_temp"
        command -v notify-send &>/dev/null && notify-send "Redshift: Reset override ($current → $expected_temp)"
        last_applied_temp=$expected_temp
      fi
    }

    if [[ "$redshift_interval" != "null" ]]; then
      while true; do
        apply_redshift
        sleep $(( redshift_interval * 60 ))
      done &
    else
      echo "[scheduler] Redshift apply loop disabled"
    fi

    if [[ "$override_interval" != "null" ]]; then
      while true; do
        check_override
        sleep $(( override_interval * 60 ))
      done &
    else
      echo "[scheduler] Override check loop disabled"
    fi

    wait
  ) &

  echo $! > "$pidfile"
  echo "Started redshift scheduler."
  echo
}

# === Entry Point ===
case "$1" in
  start)
    start_scheduler
    ;;
  stop)
    stop_scheduler
    ;;
  "")
    if is_running; then
      stop_scheduler
    else
      start_scheduler
    fi
    ;;
  *)
    echo "Usage: $0 [start|stop]"
    exit 1
    ;;
esac
