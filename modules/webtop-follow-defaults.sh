# Removes each entry of the user's KDE config that equals the admin's, so the user follows later admin
# changes again (ADR 0015, amendment 2026-11-12): a settings page's Defaults saves the admin's value into
# the user's file instead of removing it whenever the admin's layer sets the key.
#   webtop-follow-defaults <admin xdg dir> <user config dir>
# Only kdeglobals and *rc files: they are the ones KConfig cascades over the user's file.
# Equal means the same line in the same group header. Anything else (spacing, flags) stays as it is.
admin=$1 cfg=$2

[ -d "$admin" ] || exit 0
for a in "$admin"/*; do
  if [ ! -f "$a" ]; then continue; fi
  u=$cfg/$(basename -- "$a")
  # Not a home-manager link or anything else the user did not write as a plain file.
  if [ ! -f "$u" ] || [ -L "$u" ] || [ ! -w "$u" ]; then continue; fi
  tmp=$(mktemp -- "$u.XXXXXX")
  if n=$(awk -v out="$tmp" '
      FNR == 1 { g = "" }
      /^\[.*\]$/ { g = $0; if (NR != FNR) print > out; next }
      NR == FNR { if ($0 !~ /^#/ && index($0, "=")) admin[g SUBSEP $0] = 1; next }
      (g SUBSEP $0) in admin { n++; next }
      { print > out }
      END { print n + 0; exit n ? 0 : 1 }' "$a" "$u"); then
    chmod --reference="$u" -- "$tmp"
    mv -f -- "$tmp" "$u"
    echo "webtop-follow-defaults: $u: removed $n entries equal to the admin's"
  else
    rm -f -- "$tmp"
  fi
done
