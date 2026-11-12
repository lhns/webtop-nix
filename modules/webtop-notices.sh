# Runs in the desktop user's manager (ADR 0019). Shows the files of /run/webtop/notices as KDE
# notifications. The directory is the state: it is scanned at start and on every change, and every
# 30 s (a login or a thaw from Sleep leaves no event). A notice is shown once per content: dismissing it
# keeps it dismissed until the next login, a changed file shows it again in place, a removed one is
# closed. Files: <id>.json {"title","body","urgency":"low|normal|critical","action":"restart"}.
dir=/run/webtop/notices
# State per login: a new invocation of webtop-session is a new login and starts with nothing dismissed.
inv=$(systemctl show -P InvocationID webtop-session.service 2>/dev/null || true)
state=$XDG_RUNTIME_DIR/webtop/notices/${inv:-none}
max_bytes=16384
bus=org.freedesktop.Notifications
obj=/org/freedesktop/Notifications

declare -A hash nid dismissed action bad
wait_s=30

log() { echo "webtop-notices: $*"; }

# The only action: Plasma's own Restart, which asks for confirmation ($restart_cmd comes from the module).
restart() { "$BASH" -c "$restart_cmd"; }

save() { printf '%s %s %s %s\n' "${hash[$1]}" "${nid[$1]}" "${dismissed[$1]}" "${action[$1]}" >"$state/$1.new" && mv -T "$state/$1.new" "$state/$1"; }

# Body markup and links are rendered by Plasma, so the body is escaped; the title is plain text there.
# Quoted replacements: bash 5.2 reads an unquoted & in them as the matched text.
esc() {
  local amp='&amp;' lt='&lt;' gt='&gt;' s=$1
  s=${s//&/"$amp"}; s=${s//</"$lt"}; printf '%s' "${s//>/"$gt"}"
}

show() { # id title body urgency action
  local u=1 args=() reply
  case $4 in low) u=0 ;; critical) u=2 ;; esac
  [ "$5" = restart ] && args=(restart Restart)
  # expire_timeout 0 and resident: stays until the user dismisses it, also after a click on Restart
  # (they may cancel its confirmation). "--": a title may start with a dash.
  if ! reply=$(busctl --user -- call "$bus" "$obj" "$bus" Notify 'susssasa{sv}i' \
      Desktop "${nid[$1]:-0}" dialog-information "$2" "$(esc "$3")" ${#args[@]} "${args[@]}" 2 urgency y "$u" resident b true 0); then
    log "could not show $1"
    wait_s=3 # the notification server may not be up yet
    return 1
  fi
  nid[$1]=${reply#u }
}

close() { # id
  [ "${dismissed[$1]}" = 1 ] || busctl --user -- call "$bus" "$obj" "$bus" CloseNotification u "${nid[$1]}" >/dev/null 2>&1 || true
}

scan() {
  local f id h title body urgency act seen=" "
  wait_s=30
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    id=$(basename -- "$f" .json)
    case $id in .* | *[!A-Za-z0-9._-]*) continue ;; esac
    seen+="$id "
    # Not a link, small; read once so the hash is of what is shown.
    if [ -L "$f" ] || [ ! -f "$f" ] || [ "$(stat -c %s -- "$f")" -gt "$max_bytes" ]; then
      h=skip
      if [ "${bad[$id]:-}" != "$h" ]; then log "$id.json skipped: not a regular file under $max_bytes bytes"; bad[$id]=$h; fi
      continue
    fi
    content=$(cat -- "$f") || continue
    h=$(printf '%s' "$content" | sha256sum | cut -d' ' -f1)
    [ "${hash[$id]:-}" = "$h" ] && continue
    [ "${bad[$id]:-}" = "$h" ] && continue
    if ! parsed=$(printf '%s' "$content" | jq -r '
        if (type == "object" and (.title | type) == "string" and (.body | type) == "string"
            and ((.urgency // "normal") | . == "low" or . == "normal" or . == "critical")
            and ((.action // "") | type) == "string"
            and (.title | length) <= 200 and (.body | length) <= 2000)
        then [.title, .body, (.urgency // "normal"), (.action // "")] | map(gsub("\u0000"; "")) | @json
        else empty end' 2>/dev/null) || [ -z "$parsed" ]; then
      log "$id.json skipped: invalid"
      bad[$id]=$h
      continue
    fi
    title=$(jq -r '.[0]' <<<"$parsed"); body=$(jq -r '.[1]' <<<"$parsed")
    urgency=$(jq -r '.[2]' <<<"$parsed"); act=$(jq -r '.[3]' <<<"$parsed")
    [ "$act" = restart ] || act= # unknown action: no button
    if show "$id" "$title" "$body" "$urgency" "$act"; then
      hash[$id]=$h dismissed[$id]=0 action[$id]=$act
      unset "bad[$id]"
      save "$id"
      log "$id shown"
    fi
  done
  for id in "${!hash[@]}"; do
    case $seen in *" $id "*) continue ;; esac
    close "$id"
    unset "hash[$id]" "nid[$id]" "dismissed[$id]" "action[$id]"
    rm -f -- "$state/$id"
    log "$id withdrawn"
  done
}

mkdir -p -- "$state"
for old in "${state%/*}"/*; do [ "$old" = "$state" ] || rm -rf -- "$old"; done
for f in "$state"/*; do
  [ -f "$f" ] || continue
  id=$(basename -- "$f")
  read -r "hash[$id]" "nid[$id]" "dismissed[$id]" "action[$id]" <"$f" || true
done

# Events: "F" a change in the directory, "A id name" an action, "C id reason" a close. Both sources
# print whole lines at once. When either source dies the other is stopped, so the loop sees the end and
# the unit restarts; otherwise clicks would be lost while the scans go on.
events() {
  local p1 p2
  inotifywait -m -q -e close_write,moved_to,moved_from,delete,create --format F "$dir" &
  p1=$!
  dbus-monitor --session "type='signal',interface='$bus'" | awk '
    /^signal / { m = ""; if ($0 ~ /member=ActionInvoked$/) m = "A"; else if ($0 ~ /member=NotificationClosed$/) m = "C"; n = 0; next }
    /^[a-z]/ { m = ""; next }
    m != "" && $1 == "uint32" { if (n++ == 0) id = $2; else if (m == "C") { print "C " id " " $2; fflush() } next }
    m == "A" && $1 == "string" { sub(/^ *string "/, ""); sub(/"$/, ""); print "A " id " " $0; fflush(); m = "" }
  ' &
  p2=$!
  wait -n || true
  kill "$p1" "$p2" 2>/dev/null || true
}

handle() { # one event line
  local name id reason k
  case $1 in
    "A "*)
      read -r _ id name <<<"$1"
      for k in "${!nid[@]}"; do
        if [ "${nid[$k]}" = "$id" ] && [ "$name" = restart ] && [ "${action[$k]}" = restart ]; then
          log "$k: restart"
          restart || log "restart failed"
        fi
      done
      ;;
    "C "*)
      read -r _ id reason <<<"$1"
      # 3 is our own close; 1 and 2 are expiry and the user.
      for k in "${!nid[@]}"; do
        if [ "${nid[$k]}" = "$id" ] && [ "$reason" != 3 ] && [ "${dismissed[$k]}" = 0 ]; then
          dismissed[$k]=1
          save "$k"
        fi
      done
      ;;
  esac
}

trap 'exit 0' TERM INT
scan
while true; do
  if read -r -t "$wait_s" ev; then
    if [ "$ev" = F ]; then
      # A burst of changes is one scan; clicks and closes that arrive meanwhile are still handled.
      while read -r -t 0.3 more; do [ "$more" = F ] || handle "$more"; done
      scan
    else
      handle "$ev"
    fi
  else
    [ $? -gt 128 ] || { log "event sources ended"; exit 1; }
    scan
  fi
done < <(events)
