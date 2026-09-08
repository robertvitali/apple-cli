# Per-file app lifecycle wrapper for the local Bats tier. Bash owns bounded,
# targeted LaunchServices calls; Python only validates private state and output.

APPLE_CLI_BATS_APP_SNAPSHOT_READY=false
APPLE_CLI_BATS_APP_CHILD_PID=""
APPLE_CLI_BATS_APP_TIMER_PID=""
APPLE_CLI_BATS_APP_INTERRUPT_STATUS=0
APPLE_CLI_BATS_APP_PRESERVE=false
APPLE_CLI_BATS_APP_RESULT=""
APPLE_CLI_BATS_APP_TIMEOUT_TICKS=600
APPLE_CLI_BATS_APP_TERM_TICKS=10
APPLE_CLI_BATS_APP_GRACE_TICKS=50
APPLE_CLI_BATS_APP_QUIET_TICKS=10
APPLE_CLI_BATS_APP_SETTLE_TICKS=50
APPLE_CLI_BATS_APP_POLL_SECONDS=0.1
APPLE_CLI_BATS_APP_SETUP_TIMEOUT_SECONDS=120
APPLE_CLI_BATS_APP_TEARDOWN_TIMEOUT_SECONDS=120
APPLE_CLI_BATS_APP_OBSERVED_MAIL=""
APPLE_CLI_BATS_APP_OBSERVED_NOTES=""
APPLE_CLI_BATS_APP_OBSERVED_MESSAGES=""
APPLE_CLI_BATS_APP_OBSERVED_CONTACTS=""
APPLE_CLI_BATS_APP_OBSERVED_CALENDAR=""
APPLE_CLI_BATS_APP_OBSERVED_REMINDERS=""

app_lifecycle_error() { printf '%s\n' "app lifecycle operation failed" >&2; }
app_lifecycle_lsappinfo_exec() { exec /usr/bin/lsappinfo "$@"; }
app_lifecycle_signal_job() { local signal_name="$1" pid="$2"; kill "-$signal_name" -- "$pid"; }

app_lifecycle_latch_status() { [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -ne 0 ] || APPLE_CLI_BATS_APP_INTERRUPT_STATUS="$1"; }
app_lifecycle_latch_int() { app_lifecycle_latch_status 130; }
app_lifecycle_latch_term() { app_lifecycle_latch_status 143; }
app_lifecycle_latch_hup() { app_lifecycle_latch_status 129; }
app_lifecycle_latch_quit() { app_lifecycle_latch_status 131; }
app_lifecycle_after_spawn() { :; }

app_lifecycle_restore_trap() {
  local saved="$1" signal_name="$2"
  if [ -n "$saved" ]; then eval "$saved"; else trap - "$signal_name"; fi
}

app_lifecycle_install_latch_traps() {
  APPLE_CLI_BATS_APP_SAVED_INT="$(trap -p INT)"
  APPLE_CLI_BATS_APP_SAVED_TERM="$(trap -p TERM)"
  APPLE_CLI_BATS_APP_SAVED_HUP="$(trap -p HUP)"
  APPLE_CLI_BATS_APP_SAVED_QUIT="$(trap -p QUIT)"
  trap app_lifecycle_latch_int INT
  trap app_lifecycle_latch_term TERM
  trap app_lifecycle_latch_hup HUP
  trap app_lifecycle_latch_quit QUIT
}

app_lifecycle_restore_latch_traps() {
  app_lifecycle_restore_trap "$APPLE_CLI_BATS_APP_SAVED_INT" INT
  app_lifecycle_restore_trap "$APPLE_CLI_BATS_APP_SAVED_TERM" TERM
  app_lifecycle_restore_trap "$APPLE_CLI_BATS_APP_SAVED_HUP" HUP
  app_lifecycle_restore_trap "$APPLE_CLI_BATS_APP_SAVED_QUIT" QUIT
}

app_lifecycle_child_is_running_job() {
  local pid="$1" job_file="$2" job_pid
  jobs -pr > "$job_file" 2>/dev/null || return 1
  while IFS= read -r job_pid; do [ "$job_pid" = "$pid" ] && return 0; done < "$job_file"
  return 1
}

app_lifecycle_child_is_stopped_job() {
  local pid="$1" job_file="$2" job_pid
  jobs -ps > "$job_file" 2>/dev/null || return 1
  while IFS= read -r job_pid; do [ "$job_pid" = "$pid" ] && return 0; done < "$job_file"
  return 1
}

app_lifecycle_child_is_active_job() {
  app_lifecycle_child_is_running_job "$1" "$2" || app_lifecycle_child_is_stopped_job "$1" "$2"
}

app_lifecycle_start_phase_timer() {
  local duration="$1" ticks=0
  APPLE_CLI_BATS_APP_TIMER_JOB_FILE="$BATS_FILE_TMPDIR/apple-cli-app-timer.jobs"
  umask 077
  : > "$APPLE_CLI_BATS_APP_TIMER_JOB_FILE" || return 1
  /bin/sleep "$duration" &
  APPLE_CLI_BATS_APP_TIMER_PID=$!
  while ! app_lifecycle_child_is_running_job "$APPLE_CLI_BATS_APP_TIMER_PID" "$APPLE_CLI_BATS_APP_TIMER_JOB_FILE"; do
    if app_lifecycle_child_is_stopped_job "$APPLE_CLI_BATS_APP_TIMER_PID" "$APPLE_CLI_BATS_APP_TIMER_JOB_FILE"; then
      app_lifecycle_latch_status 124
      app_lifecycle_cleanup_phase_timer
      return 124
    fi
    if [ "$ticks" -ge 100 ]; then
      app_lifecycle_latch_status 124
      app_lifecycle_cleanup_phase_timer
      return 124
    fi
    /bin/sleep 0.001
    ticks=$((ticks + 1))
  done
}

app_lifecycle_check_phase_timer() {
  local pid="$APPLE_CLI_BATS_APP_TIMER_PID"
  [ -n "$pid" ] || return 0
  if app_lifecycle_child_is_running_job "$pid" "$APPLE_CLI_BATS_APP_TIMER_JOB_FILE"; then return 0; fi
  if app_lifecycle_child_is_stopped_job "$pid" "$APPLE_CLI_BATS_APP_TIMER_JOB_FILE"; then
    app_lifecycle_latch_status 124
    app_lifecycle_cleanup_phase_timer
    return 124
  fi
  wait "$pid" 2>/dev/null || true
  APPLE_CLI_BATS_APP_TIMER_PID=""
  app_lifecycle_latch_status 124
  return 124
}

app_lifecycle_cleanup_phase_timer() {
  local pid="$APPLE_CLI_BATS_APP_TIMER_PID" cancelled=false forced=false status ticks=0
  [ -n "$pid" ] || return 0
  if app_lifecycle_child_is_active_job "$pid" "$APPLE_CLI_BATS_APP_TIMER_JOB_FILE"; then
    if app_lifecycle_signal_job TERM "$pid" 2>/dev/null; then cancelled=true; fi
  fi
  while app_lifecycle_child_is_active_job "$pid" "$APPLE_CLI_BATS_APP_TIMER_JOB_FILE" && [ "$ticks" -lt "$APPLE_CLI_BATS_APP_TERM_TICKS" ]; do
    /bin/sleep "$APPLE_CLI_BATS_APP_POLL_SECONDS"
    ticks=$((ticks + 1))
  done
  if app_lifecycle_child_is_active_job "$pid" "$APPLE_CLI_BATS_APP_TIMER_JOB_FILE"; then
    if app_lifecycle_signal_job KILL "$pid" 2>/dev/null; then forced=true; fi
  fi
  if wait "$pid" 2>/dev/null; then status=0; else status=$?; fi
  APPLE_CLI_BATS_APP_TIMER_PID=""
  if [ "$cancelled" = true ] && [ "$forced" = false ] && [ "$status" -eq 143 ]; then return 0; fi
  app_lifecycle_latch_status 124
  return 124
}

app_lifecycle_wait_child() {
  local pid="$1" status
  if wait "$pid" 2>/dev/null; then status=0; else status=$?; fi
  APPLE_CLI_BATS_APP_CHILD_PID=""
  return "$status"
}

app_lifecycle_cleanup_child() {
  local pid="$APPLE_CLI_BATS_APP_CHILD_PID" ticks=0
  [ -n "$pid" ] || return 0
  # Job-table membership minimizes the unavoidable exit/reuse race and keeps
  # cleanup scoped to this shell's child rather than an unrelated numeric PID.
  if app_lifecycle_child_is_active_job "$pid" "$APPLE_CLI_BATS_APP_CHILD_JOB_FILE"; then app_lifecycle_signal_job TERM "$pid" 2>/dev/null || true; fi
  while app_lifecycle_child_is_active_job "$pid" "$APPLE_CLI_BATS_APP_CHILD_JOB_FILE" && [ "$ticks" -lt "$APPLE_CLI_BATS_APP_TERM_TICKS" ]; do
    /bin/sleep "$APPLE_CLI_BATS_APP_POLL_SECONDS"
    ticks=$((ticks + 1))
  done
  if app_lifecycle_child_is_active_job "$pid" "$APPLE_CLI_BATS_APP_CHILD_JOB_FILE"; then app_lifecycle_signal_job KILL "$pid" 2>/dev/null || true; fi
  app_lifecycle_wait_child "$pid" || true
}

app_lifecycle_run_lsappinfo() {
  local output_file="$1"
  shift
  local old_int old_term old_hup old_quit ticks=0 status=""
  [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -eq 0 ] || return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
  app_lifecycle_check_phase_timer || return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
  old_int="$(trap -p INT)"; old_term="$(trap -p TERM)"
  old_hup="$(trap -p HUP)"; old_quit="$(trap -p QUIT)"
  APPLE_CLI_BATS_APP_CHILD_JOB_FILE="${output_file}.jobs"
  umask 077
  : > "$output_file" || return 1
  : > "$APPLE_CLI_BATS_APP_CHILD_JOB_FILE" || return 1
  trap app_lifecycle_latch_int INT
  trap app_lifecycle_latch_term TERM
  trap app_lifecycle_latch_hup HUP
  trap app_lifecycle_latch_quit QUIT
  app_lifecycle_lsappinfo_exec "$@" > "$output_file" 2>/dev/null &
  APPLE_CLI_BATS_APP_CHILD_PID=$!
  app_lifecycle_after_spawn
  while app_lifecycle_child_is_active_job "$APPLE_CLI_BATS_APP_CHILD_PID" "$APPLE_CLI_BATS_APP_CHILD_JOB_FILE"; do
    if ! app_lifecycle_check_phase_timer; then status="$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; break; fi
    if [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -ne 0 ]; then status="$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; break; fi
    if [ "$ticks" -ge "$APPLE_CLI_BATS_APP_TIMEOUT_TICKS" ]; then status=124; break; fi
    /bin/sleep "$APPLE_CLI_BATS_APP_POLL_SECONDS"
    ticks=$((ticks + 1))
  done
  if [ -z "$status" ] && ! app_lifecycle_check_phase_timer; then status="$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; fi
  if [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -ne 0 ]; then
    status="$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; app_lifecycle_cleanup_child
  elif [ -n "$status" ]; then
    app_lifecycle_cleanup_child
  else
    if app_lifecycle_wait_child "$APPLE_CLI_BATS_APP_CHILD_PID"; then status=0; else status=$?; fi
  fi
  app_lifecycle_restore_trap "$old_int" INT; app_lifecycle_restore_trap "$old_term" TERM
  app_lifecycle_restore_trap "$old_hup" HUP; app_lifecycle_restore_trap "$old_quit" QUIT
  return "$status"
}

app_lifecycle_read_output() {
  local file="$1" value count=0
  APPLE_CLI_BATS_APP_RESULT=""
  while IFS= read -r value || [ -n "$value" ]; do
    count=$((count + 1)); [ "$count" -eq 1 ] || return 1
    APPLE_CLI_BATS_APP_RESULT="$value"
  done < "$file"
  [ "$count" -eq 1 ]
}

app_lifecycle_app_fields() {
  case "$1" in
    mail) APP_LIFECYCLE_NAME=Mail; APP_LIFECYCLE_BUNDLE=com.apple.mail ;;
    notes) APP_LIFECYCLE_NAME=Notes; APP_LIFECYCLE_BUNDLE=com.apple.Notes ;;
    messages) APP_LIFECYCLE_NAME=Messages; APP_LIFECYCLE_BUNDLE=com.apple.MobileSMS ;;
    contacts) APP_LIFECYCLE_NAME=Contacts; APP_LIFECYCLE_BUNDLE=com.apple.AddressBook ;;
    calendar) APP_LIFECYCLE_NAME=Calendar; APP_LIFECYCLE_BUNDLE=com.apple.iCal ;;
    reminders) APP_LIFECYCLE_NAME=Reminders; APP_LIFECYCLE_BUNDLE=com.apple.reminders ;;
    *) return 1 ;;
  esac
}

app_lifecycle_clear_observed_identities() {
  APPLE_CLI_BATS_APP_OBSERVED_MAIL=""
  APPLE_CLI_BATS_APP_OBSERVED_NOTES=""
  APPLE_CLI_BATS_APP_OBSERVED_MESSAGES=""
  APPLE_CLI_BATS_APP_OBSERVED_CONTACTS=""
  APPLE_CLI_BATS_APP_OBSERVED_CALENDAR=""
  APPLE_CLI_BATS_APP_OBSERVED_REMINDERS=""
}

app_lifecycle_store_observed_identity() {
  local key="$1" identity="$2"
  case "$key" in
    mail) APPLE_CLI_BATS_APP_OBSERVED_MAIL="$identity" ;;
    notes) APPLE_CLI_BATS_APP_OBSERVED_NOTES="$identity" ;;
    messages) APPLE_CLI_BATS_APP_OBSERVED_MESSAGES="$identity" ;;
    contacts) APPLE_CLI_BATS_APP_OBSERVED_CONTACTS="$identity" ;;
    calendar) APPLE_CLI_BATS_APP_OBSERVED_CALENDAR="$identity" ;;
    reminders) APPLE_CLI_BATS_APP_OBSERVED_REMINDERS="$identity" ;;
    *) return 1 ;;
  esac
}

app_lifecycle_observed_identity() {
  case "$1" in
    mail) APPLE_CLI_BATS_APP_RESULT="$APPLE_CLI_BATS_APP_OBSERVED_MAIL" ;;
    notes) APPLE_CLI_BATS_APP_RESULT="$APPLE_CLI_BATS_APP_OBSERVED_NOTES" ;;
    messages) APPLE_CLI_BATS_APP_RESULT="$APPLE_CLI_BATS_APP_OBSERVED_MESSAGES" ;;
    contacts) APPLE_CLI_BATS_APP_RESULT="$APPLE_CLI_BATS_APP_OBSERVED_CONTACTS" ;;
    calendar) APPLE_CLI_BATS_APP_RESULT="$APPLE_CLI_BATS_APP_OBSERVED_CALENDAR" ;;
    reminders) APPLE_CLI_BATS_APP_RESULT="$APPLE_CLI_BATS_APP_OBSERVED_REMINDERS" ;;
    *) return 1 ;;
  esac
  [ -n "$APPLE_CLI_BATS_APP_RESULT" ]
}

app_lifecycle_target_find() {
  local key="$1" prefix="$2" status
  app_lifecycle_app_fields "$key" || return 1
  app_lifecycle_run_lsappinfo "${prefix}.bundle" find "bundleid=$APP_LIFECYCLE_BUNDLE"
  status=$?; [ "$status" -eq 0 ] || return "$status"
  app_lifecycle_run_lsappinfo "${prefix}.exact" find "name=$APP_LIFECYCLE_NAME" "bundleid=$APP_LIFECYCLE_BUNDLE"
  status=$?; [ "$status" -eq 0 ] || return "$status"
  umask 077
  if ! /usr/bin/python3 "$HELPERS/app_lifecycle.py" parse-find --app "$key" \
      --bundle-output "${prefix}.bundle" \
      --exact-output "${prefix}.exact" > "${prefix}.parsed" 2>/dev/null; then return 1; fi
  app_lifecycle_read_output "${prefix}.parsed"
}

app_lifecycle_observe() {
  local prefix="$1" capture_identities="${2:-false}" key status running="" asn identity
  app_lifecycle_clear_observed_identities
  for key in mail notes messages contacts calendar reminders; do
    app_lifecycle_target_find "$key" "${prefix}.${key}"
    status=$?; [ "$status" -eq 0 ] || return "$status"
    case "$APPLE_CLI_BATS_APP_RESULT" in
      NONE) running="${running}0" ;;
      ASN:*)
        asn="$APPLE_CLI_BATS_APP_RESULT"
        if [ "$capture_identities" = true ]; then
          app_lifecycle_info "$key" "$asn" "${prefix}.${key}.observed"
          status=$?; [ "$status" -eq 0 ] || return "$status"
          identity="$APPLE_CLI_BATS_APP_RESULT"
          if [ "$identity" = STOPPED ]; then running="${running}0"; continue; fi
          app_lifecycle_split_identity "$identity" || return 1
          [ "$APP_LIFECYCLE_ASN" = "$asn" ] || return 1
          app_lifecycle_store_observed_identity "$key" "$identity" || return 1
        elif [ "$capture_identities" != false ]; then return 1
        fi
        running="${running}1"
        ;;
      *) return 1 ;;
    esac
  done
  APPLE_CLI_BATS_APP_RESULT="$running"
}

app_lifecycle_info() {
  local key="$1" asn="$2" prefix="$3" status
  app_lifecycle_run_lsappinfo "${prefix}.info" info -only name -only pid \
    -only bundleID -only kLSCheckInTimeKey -app "$asn"
  status=$?; [ "$status" -eq 0 ] || return "$status"
  umask 077
  if ! /usr/bin/python3 "$HELPERS/app_lifecycle.py" parse-info --app "$key" \
      --asn "$asn" --output "${prefix}.info" > "${prefix}.parsed" 2>/dev/null; then return 1; fi
  app_lifecycle_read_output "${prefix}.parsed"
}

app_lifecycle_split_identity() {
  local value="$1" tab
  tab=$'\t'
  case "$value" in *"$tab"*"$tab"*) ;; *) return 1 ;; esac
  APP_LIFECYCLE_ASN="${value%%"$tab"*}"; value="${value#*"$tab"}"
  APP_LIFECYCLE_PID="${value%%"$tab"*}"; APP_LIFECYCLE_TOKEN="${value#*"$tab"}"
  case "$APP_LIFECYCLE_TOKEN" in *"$tab"*) return 1 ;; esac
  [ -n "$APP_LIFECYCLE_ASN" ] && [ -n "$APP_LIFECYCLE_PID" ] && [ -n "$APP_LIFECYCLE_TOKEN" ]
}

app_lifecycle_validate_instance() {
  local key="$1" asn="$2" pid="$3" token="$4" prefix="$5" result status
  app_lifecycle_info "$key" "$asn" "$prefix"
  status=$?; [ "$status" -eq 0 ] || return "$status"
  result="$APPLE_CLI_BATS_APP_RESULT"
  if [ "$result" = STOPPED ]; then APPLE_CLI_BATS_APP_RESULT=STOPPED; return 0; fi
  app_lifecycle_split_identity "$result" || return 1
  if [ "$APP_LIFECYCLE_ASN" = "$asn" ] && [ "$APP_LIFECYCLE_PID" = "$pid" ] && [ "$APP_LIFECYCLE_TOKEN" = "$token" ]; then
    APPLE_CLI_BATS_APP_RESULT=MATCH; return 0
  fi
  APPLE_CLI_BATS_APP_RESULT=MISMATCH
  return 1
}

app_lifecycle_terminate_instance() {
  local asn="$1" prefix="$2"
  app_lifecycle_run_lsappinfo "${prefix}.kill" kill "$asn"
}

app_lifecycle_hard_terminate_instance() {
  local asn="$1" prefix="$2"
  app_lifecycle_run_lsappinfo "${prefix}.hard-kill" kill -hard "$asn"
}

app_lifecycle_restore_one() {
  local key="$1" identity="$2" prefix="$3" status asn pid token state ticks=0
  [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -eq 0 ] || return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
  app_lifecycle_split_identity "$identity" || return 1
  asn="$APP_LIFECYCLE_ASN"
  pid="$APP_LIFECYCLE_PID"; token="$APP_LIFECYCLE_TOKEN"
  app_lifecycle_validate_instance "$key" "$asn" "$pid" "$token" "${prefix}.validate"
  status=$?; [ "$status" -eq 0 ] || return "$status"
  [ "$APPLE_CLI_BATS_APP_RESULT" = MATCH ] || return 0
  app_lifecycle_terminate_instance "$asn" "$prefix"
  status=$?; [ "$status" -eq 0 ] || return "$status"
  while [ "$ticks" -lt "$APPLE_CLI_BATS_APP_GRACE_TICKS" ]; do
    app_lifecycle_check_phase_timer || return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
    [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -eq 0 ] || return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
    app_lifecycle_validate_instance "$key" "$asn" "$pid" "$token" "${prefix}.validate"
    status=$?; [ "$status" -eq 0 ] || return "$status"
    state="$APPLE_CLI_BATS_APP_RESULT"; [ "$state" = STOPPED ] && return 0; [ "$state" = MATCH ] || return 1
    /bin/sleep "$APPLE_CLI_BATS_APP_POLL_SECONDS"; ticks=$((ticks + 1))
  done
  [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -eq 0 ] || return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
  app_lifecycle_validate_instance "$key" "$asn" "$pid" "$token" "${prefix}.validate"
  status=$?; [ "$status" -eq 0 ] || return "$status"
  state="$APPLE_CLI_BATS_APP_RESULT"; [ "$state" = STOPPED ] && return 0; [ "$state" = MATCH ] || return 1
  app_lifecycle_check_phase_timer || return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
  [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -eq 0 ] || return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
  app_lifecycle_hard_terminate_instance "$asn" "$prefix" || return $?
  ticks=0
  while [ "$ticks" -lt "$APPLE_CLI_BATS_APP_TERM_TICKS" ]; do
    app_lifecycle_check_phase_timer || return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
    [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -eq 0 ] || return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
    app_lifecycle_validate_instance "$key" "$asn" "$pid" "$token" "${prefix}.validate"
    status=$?; [ "$status" -eq 0 ] || return "$status"
    state="$APPLE_CLI_BATS_APP_RESULT"; [ "$state" = STOPPED ] && return 0; [ "$state" = MATCH ] || return 1
    /bin/sleep "$APPLE_CLI_BATS_APP_POLL_SECONDS"; ticks=$((ticks + 1))
  done
  app_lifecycle_validate_instance "$key" "$asn" "$pid" "$token" "${prefix}.validate"
  status=$?; [ "$status" -eq 0 ] || return "$status"
  [ "$APPLE_CLI_BATS_APP_RESULT" = STOPPED ]
}

app_lifecycle_setup_file_impl() {
  local state="$BATS_FILE_TMPDIR/apple-cli-app-state.json" running preserve=false status
  APPLE_CLI_BATS_APP_SNAPSHOT_READY=false; APPLE_CLI_BATS_APP_PRESERVE=false
  case "${APPLE_CLI_BATS_PRESERVE_APPS+x}:${APPLE_CLI_BATS_PRESERVE_APPS:-}" in
    :) ;; x:1|x:true|x:yes) preserve=true ;; *) app_lifecycle_error; return 1 ;;
  esac
  if [ "$preserve" = true ]; then
    APPLE_CLI_BATS_APP_PRESERVE=true; running=000000
    if ! /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$state" --running "$running" --disabled 2>/dev/null; then app_lifecycle_error; return 1; fi
  else
    app_lifecycle_observe "$BATS_FILE_TMPDIR/apple-cli-app-snapshot"
    status=$?; if [ "$status" -ne 0 ]; then app_lifecycle_error; return "$status"; fi
    if ! app_lifecycle_check_phase_timer; then app_lifecycle_error; return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; fi
    running="$APPLE_CLI_BATS_APP_RESULT"
    if ! /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$state" --running "$running" 2>/dev/null; then app_lifecycle_error; return 1; fi
  fi
  APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
}

app_lifecycle_teardown_file_impl() {
  local state="$BATS_FILE_TMPDIR/apple-cli-app-state.json" plan_file="$BATS_FILE_TMPDIR/apple-cli-app-plan.txt"
  local current key identity status round=0 quiet_ticks=0 settle_ticks=0 processed="|" planned failed
  [ "$APPLE_CLI_BATS_APP_SNAPSHOT_READY" = true ] || return 0
  if [ "$APPLE_CLI_BATS_APP_PRESERVE" = true ]; then
    if ! /usr/bin/python3 "$HELPERS/app_lifecycle.py" finish-restore --state "$state" 2>/dev/null; then app_lifecycle_error; return 1; fi
    return 0
  fi
  umask 077
  while [ "$settle_ticks" -le "$APPLE_CLI_BATS_APP_SETTLE_TICKS" ]; do
    if ! app_lifecycle_check_phase_timer; then app_lifecycle_error; return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; fi
    app_lifecycle_observe "$BATS_FILE_TMPDIR/apple-cli-app-current.$round" true
    status=$?; if [ "$status" -ne 0 ]; then app_lifecycle_error; return "$status"; fi
    if ! app_lifecycle_check_phase_timer; then app_lifecycle_error; return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; fi
    current="$APPLE_CLI_BATS_APP_RESULT"
    if ! /usr/bin/python3 "$HELPERS/app_lifecycle.py" restore-plan --state "$state" --current "$current" > "$plan_file" 2>/dev/null; then app_lifecycle_error; return 1; fi
    planned=false; failed=false
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      planned=true
      case "$processed" in *"|$key|"*) failed=true; continue ;; esac
      if ! app_lifecycle_observed_identity "$key"; then failed=true; continue; fi
      identity="$APPLE_CLI_BATS_APP_RESULT"
      processed="${processed}${key}|"
      app_lifecycle_restore_one "$key" "$identity" "$BATS_FILE_TMPDIR/apple-cli-app-restore.$round.$key"; status=$?
      if [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -ne 0 ]; then app_lifecycle_error; return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; fi
      [ "$status" -eq 0 ] || failed=true
    done < "$plan_file"
    if [ "$failed" = true ]; then app_lifecycle_error; return 1; fi
    if [ "$planned" = true ]; then quiet_ticks=0
    elif [ "$quiet_ticks" -ge "$APPLE_CLI_BATS_APP_QUIET_TICKS" ]; then
      if ! /usr/bin/python3 "$HELPERS/app_lifecycle.py" finish-restore --state "$state" 2>/dev/null; then app_lifecycle_error; return 1; fi
      return 0
    else quiet_ticks=$((quiet_ticks + 1))
    fi
    [ "$settle_ticks" -lt "$APPLE_CLI_BATS_APP_SETTLE_TICKS" ] || break
    /bin/sleep "$APPLE_CLI_BATS_APP_POLL_SECONDS"
    if ! app_lifecycle_check_phase_timer; then app_lifecycle_error; return "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; fi
    settle_ticks=$((settle_ticks + 1)); round=$((round + 1))
  done
  app_lifecycle_error
  return 1
}

setup_file() {
  local status saved_umask cleanup_interrupt
  saved_umask="$(umask)"
  APPLE_CLI_BATS_APP_INTERRUPT_STATUS=0
  app_lifecycle_install_latch_traps
  if app_lifecycle_start_phase_timer "$APPLE_CLI_BATS_APP_SETUP_TIMEOUT_SECONDS"; then
    app_lifecycle_setup_file_impl; status=$?
    if [ "$status" -eq 0 ] && ! app_lifecycle_check_phase_timer; then status="$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; app_lifecycle_error; fi
  else status=1
  fi
  cleanup_interrupt="$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
  app_lifecycle_cleanup_child
  app_lifecycle_cleanup_phase_timer
  if [ "$cleanup_interrupt" -eq 0 ] && [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -ne 0 ]; then app_lifecycle_error; fi
  if [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -ne 0 ]; then status="$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; fi
  [ "$status" -eq 0 ] || APPLE_CLI_BATS_APP_SNAPSHOT_READY=false
  app_lifecycle_restore_latch_traps
  umask "$saved_umask"
  return "$status"
}

teardown_file() {
  local status saved_umask cleanup_interrupt
  saved_umask="$(umask)"
  app_lifecycle_install_latch_traps
  if app_lifecycle_start_phase_timer "$APPLE_CLI_BATS_APP_TEARDOWN_TIMEOUT_SECONDS"; then
    app_lifecycle_teardown_file_impl; status=$?
    if [ "$status" -eq 0 ] && ! app_lifecycle_check_phase_timer; then status="$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; app_lifecycle_error; fi
  else status=1
  fi
  cleanup_interrupt="$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"
  app_lifecycle_cleanup_child
  app_lifecycle_cleanup_phase_timer
  if [ "$cleanup_interrupt" -eq 0 ] && [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -ne 0 ]; then app_lifecycle_error; fi
  if [ "$APPLE_CLI_BATS_APP_INTERRUPT_STATUS" -ne 0 ]; then status="$APPLE_CLI_BATS_APP_INTERRUPT_STATUS"; fi
  app_lifecycle_restore_latch_traps
  umask "$saved_umask"
  return "$status"
}
