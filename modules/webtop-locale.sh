# Applies the desktop's time zone, locale and formats before the session starts. Never fails the unit:
# a bad value is logged and skipped.
#   webtop-locale <uid> <locale-archive> <default-tz> <default-locale> <consumer-keys> <defaults-dir> <xdg-session-dir>
# Per key, the first valid of: the user's ~/.config/webtop/session.conf, the admin's <defaults-dir>/session.conf
# (the snapshot of services.webtop.defaults.source), the module's default (time zone and locale only).
# Keys: timeZone, locale (LANG), language (LANGUAGE) and the LC_* of `formats` below.
# Writes /etc/localtime, /etc/locale.conf and <xdg-session-dir>/plasma-localerc, the layer of Plasma's
# config cascade just below the user's own plasma-localerc. Nothing valid leaves the image's files as they are.
uid=$1 archive=$2 default_tz=$3 default_locale=$4 consumer_keys=" $5 "
defaults_dir=$6 xdg_session=$7

zonedir=/etc/zoneinfo
formats=(LC_TIME LC_NUMERIC LC_MONETARY LC_MEASUREMENT LC_PAPER LC_COLLATE LC_ADDRESS LC_NAME LC_TELEPHONE)
own_keys=" timeZone locale language ${formats[*]} "

log() { echo "webtop-locale: $*"; }
printable() { printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-64; }

# shellcheck disable=SC2329 # called through pick
# A name under the image's zoneinfo, resolving (through any links) to a TZif file inside it.
tz_ok() {
  local root real
  [[ $1 =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] && [ "${#1}" -le 64 ] || return 1
  root=$(realpath -e -- "$zonedir") && real=$(realpath -e -- "$zonedir/$1" 2>/dev/null) || return 1
  [ -f "$real" ] && [[ $real == "$root"/* ]] && [ "$(head -c4 -- "$real")" = TZif ]
}

# shellcheck disable=SC2329 # called through pick
# A locale of the image's archive; de_DE.UTF-8 is listed by `locale -a` as de_DE.utf8.
locale_ok() {
  local name all cs=
  [[ $1 =~ ^[A-Za-z]{1,3}(_[A-Z]{2})?(\.[A-Za-z0-9-]{1,16})?$ ]] || return 1
  name=${1%%.*}
  if [[ $1 == *.* ]]; then cs=.$(printf %s "${1#*.}" | tr '[:upper:]' '[:lower:]' | tr -d '-'); fi
  all=$(LOCALE_ARCHIVE=$archive locale -a) # not piped: grep -q closing early would fail pipefail
  grep -qxF -- "$name$cs" <<<"$all"
}

# shellcheck disable=SC2329 # called through pick
# LANGUAGE: a colon list of catalog names (de:en, pt_BR).
language_ok() {
  [[ $1 =~ ^[A-Za-z0-9_@.-]+(:[A-Za-z0-9_@.-]+)*$ ]] && [ "${#1}" -le 128 ]
}

# parse_conf <content> <label> <array>: key=value lines into the associative array.
# The grammar of a consumer's reader too: blanks around key and value ignored, # starts a comment line.
parse_conf() {
  local content=$1 label=$2 line key ignored=0 unknown=''
  local -n out=$3
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*([A-Za-z_]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]]; then
      key=${BASH_REMATCH[1]}
      if [[ $own_keys == *" $key "* ]]; then
        # shellcheck disable=SC2034,SC2004 # the caller's array, through the nameref
        out[$key]=${BASH_REMATCH[2]}
      else
        case $key in
          onLogout | onLock) ;; # webtop.ssoLogout's
          *) [[ $consumer_keys == *" $key "* ]] || { unknown=$key ignored=$((ignored + 1)); } ;;
        esac
      fi
    elif [[ $line =~ ^[[:space:]]*(#|$) ]]; then
      :
    else
      ignored=$((ignored + 1))
    fi
  done <<<"$content"
  # One line per start, however many lines the file has.
  [ "$ignored" = 0 ] || log "$label: ignored $ignored lines (unknown keys or not key=value${unknown:+, e.g. $(printable "$unknown")})"
}

declare -A admin_v=() user_v=()

# The admin's snapshot is root-owned; bounded like the user's file.
f=$defaults_dir/session.conf
if [ -f "$f" ]; then
  content=$(head -c 65537 -- "$f" | tr -d '\000')
  if [ "$(LC_ALL=C; echo "${#content}")" -gt 65536 ]; then
    log "ignoring $f: over 64 KiB"
  else
    parse_conf "$content" "defaults session.conf" admin_v
  fi
fi

# The user file is untrusted: read as the user, so the kernel refuses what they cannot open. It is
# usually a link into the store (home-manager), so links are followed. Bounded to 64 KiB by head, a
# timeout against a FIFO swapped in after the check.
if pw=$(getent passwd "$uid") && home=$(cut -d: -f6 <<<"$pw") && name=$(cut -d: -f1 <<<"$pw") && [ -d "$home" ]; then
  f=$home/.config/webtop/session.conf
  rc=0
  # shellcheck disable=SC2016 # expanded by the user's sh
  content=$(runuser -u "$name" -- timeout 5 sh -c \
    '[ -f "$1" ] || exit 3; head -c 65537 -- "$1" | tr -d "\000"' sh "$f" 2>/dev/null) || rc=$?
  case $rc in
    0) ;;
    3) [ ! -e "$f" ] && [ ! -L "$f" ] || log "ignoring $f: not a regular file" ;;
    *) log "ignoring $f: unreadable" ;;
  esac
  if [ "$rc" = 0 ] && [ "$(LC_ALL=C; echo "${#content}")" -gt 65536 ]; then
    log "ignoring $f: over 64 KiB"
    rc=4
  fi
  if [ "$rc" = 0 ]; then parse_conf "$content" "session.conf" user_v; fi
else
  log "no home for uid $uid: the user's session.conf is not read"
fi

# pick <what> <check> <source:value>...: prints the first valid value.
pick() {
  local what=$1 check=$2 item src val
  shift 2
  for item in "$@"; do
    src=${item%%:*} val=${item#*:}
    [ -n "$val" ] || continue
    if "$check" "$val"; then
      log "$what $val (from $src)"
      printf '%s' "$val" >&3
      return 0
    fi
    log "ignoring invalid $what '$(printable "$val")' from $src"
  done
}

# resolve <key> <check> [module default]: the key's value, empty if none is valid.
resolve() {
  pick "$1" "$2" "user file:${user_v[$1]:-}" "admin defaults:${admin_v[$1]:-}" "module default:${3:-}" 3>&1 >&2
}

tz=$(resolve timeZone tz_ok "$default_tz") || true
lc=$(resolve locale locale_ok "$default_locale") || true
language=$(resolve language language_ok) || true
declare -A fmt=()
fmts=''
for k in "${formats[@]}"; do
  fmt[$k]=$(resolve "$k" locale_ok) || true
  fmts+=${fmt[$k]}
done

if [ -n "$tz" ]; then
  if ! { ln -sfn "$zonedir/$tz" /etc/localtime.new && mv -T /etc/localtime.new /etc/localtime; }; then log "could not set /etc/localtime"; fi
fi

# LANG stays when only other keys resolve: startplasma writes the environment's LANG into the user's
# plasma-localerc when no layer has one, which would freeze it for that user.
lang=$lc
if [ -z "$lang" ] && [ -r /etc/locale.conf ]; then
  lang=$(grep -m1 '^LANG=' /etc/locale.conf | cut -d= -f2- || true)
fi

if [ -n "$lc$language$fmts" ]; then
  # Replaces NixOS's link into the store, so localectl and the next start see it too.
  if ! {
    {
      [ -z "$lang" ] || printf 'LANG=%s\n' "$lang"
      [ -z "$language" ] || printf 'LANGUAGE=%s\n' "$language"
      for k in "${formats[@]}"; do [ -z "${fmt[$k]}" ] || printf '%s=%s\n' "$k" "${fmt[$k]}"; done
    } >/etc/locale.conf.new && mv -T /etc/locale.conf.new /etc/locale.conf
  }; then log "could not set /etc/locale.conf"; fi
fi

# What startplasma and the Region & Language page read as the system default.
if [ -n "$lang" ]; then
  if ! {
    mkdir -p -- "$xdg_session" && {
      printf '[Formats]\n'
      printf 'LANG=%s\n' "$lang"
      for k in "${formats[@]}"; do [ -z "${fmt[$k]}" ] || printf '%s=%s\n' "$k" "${fmt[$k]}"; done
      [ -z "$language" ] || printf '\n[Translations]\nLANGUAGE=%s\n' "$language"
    } >"$xdg_session/plasma-localerc.new" && chmod 644 "$xdg_session/plasma-localerc.new" &&
      mv -T "$xdg_session/plasma-localerc.new" "$xdg_session/plasma-localerc"
  }; then log "could not write $xdg_session/plasma-localerc"; fi
fi
# timedated and localed keep what they read; stopping them (D-Bus starts them again on demand) makes
# the next query report this start's values. reset-failed keeps a quick series of starts under the rate limit.
if [ -n "$tz$lc$language$fmts" ]; then
  systemctl reset-failed systemd-timedated.service systemd-localed.service 2>/dev/null || true
  systemctl stop systemd-timedated.service systemd-localed.service || log "could not refresh timedated/localed"
fi
exit 0
