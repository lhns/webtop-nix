# Applies the desktop's time zone and locale before the session starts. Never fails the unit:
# a bad value is logged and skipped.
#   webtop-locale <uid> <locale-archive> <default-tz> <default-locale> [env-file...]
# Per setting, the first valid of: the user's ~/.config/webtop/session.conf (timeZone=, locale=),
# WEBTOP_TIME_ZONE / WEBTOP_LOCALE from the env files (later wins), the module's default.
# Nothing valid leaves /etc/localtime and /etc/locale.conf as the image has them.
uid=$1 archive=$2 default_tz=$3 default_locale=$4
shift 4

zonedir=/etc/zoneinfo

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

# The user file is untrusted: read as the user (the kernel then refuses what they cannot open, and a
# link cannot reach other files), a regular file of at most 64 KiB, a timeout against a FIFO.
user_tz='' user_locale=''
if pw=$(getent passwd "$uid") && home=$(cut -d: -f6 <<<"$pw") && name=$(cut -d: -f1 <<<"$pw") && [ -d "$home" ]; then
  f=$home/.config/webtop/session.conf
  rc=0
  # shellcheck disable=SC2016 # expanded by the user's sh
  content=$(runuser -u "$name" -- timeout 5 sh -c \
    '[ -f "$1" ] && [ ! -L "$1" ] || exit 3; [ "$(stat -c %s "$1")" -le 65536 ] || exit 4; cat -- "$1"' sh "$f" 2>/dev/null) || rc=$?
  case $rc in
    0) ;;
    3) [ ! -e "$f" ] && [ ! -L "$f" ] || log "ignoring $f: not a regular file" ;;
    *) log "ignoring $f: unreadable or over 64 KiB" ;;
  esac
  if [ "$rc" = 0 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      case $line in '' | '#'*) continue ;; esac
      if [[ $line =~ ^([A-Za-z]+)=(.*)$ ]]; then
        case ${BASH_REMATCH[1]} in
          timeZone) user_tz=${BASH_REMATCH[2]} ;;
          locale) user_locale=${BASH_REMATCH[2]} ;;
          onLogout | onLock) ;; # the gateway's
          *) log "session.conf: ignoring unknown key '$(printable "${BASH_REMATCH[1]}")'" ;;
        esac
      else
        log "session.conf: ignoring a line that is not key=value"
      fi
    done <<<"$content"
  fi
else
  log "no home for uid $uid: the user's session.conf is not read"
fi

env_tz='' env_locale=''
for ef in "$@"; do
  ef=${ef#-}
  [ -f "$ef" ] || continue
  v=$(grep -m1 '^WEBTOP_TIME_ZONE=' "$ef" | cut -d= -f2- || true); [ -z "$v" ] || env_tz=$v
  v=$(grep -m1 '^WEBTOP_LOCALE=' "$ef" | cut -d= -f2- || true); [ -z "$v" ] || env_locale=$v
done

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

tz=$(pick "time zone" tz_ok "user file:$user_tz" "pod env:$env_tz" "module default:$default_tz" 3>&1 >&2) || true
lc=$(pick "locale" locale_ok "user file:$user_locale" "pod env:$env_locale" "module default:$default_locale" 3>&1 >&2) || true

if [ -n "$tz" ]; then
  if ! { ln -sfn "$zonedir/$tz" /etc/localtime.new && mv -T /etc/localtime.new /etc/localtime; }; then log "could not set /etc/localtime"; fi
fi
if [ -n "$lc" ]; then
  # Replaces NixOS's link into the store, so localectl and the next start see it too.
  if ! { printf 'LANG=%s\n' "$lc" > /etc/locale.conf.new && mv -T /etc/locale.conf.new /etc/locale.conf; }; then log "could not set /etc/locale.conf"; fi
fi
exit 0
