# Writes the system-wide KDE defaults that show or hide the Lock action, before each session start.
#   webtop-lock-config <default: true|false> [env-file...]
# WEBTOP_LOCK_SCREEN=true|false in an env file (later wins) beats the module default. Autolock and
# lock on resume are off in every case: the greeter cannot be used here.
default=$1
shift

val=$default
for ef in "$@"; do
  ef=${ef#-}
  [ -f "$ef" ] || continue
  v=$(grep -m1 '^WEBTOP_LOCK_SCREEN=' "$ef" | cut -d= -f2- || true)
  case $v in true | false) val=$v ;; esac
done

dir=/etc/xdg
mkdir -p "$dir"
printf '[Daemon]\nAutolock=false\nLockOnResume=false\n' >"$dir/kscreenlockerrc.new"
printf '[KDE Action Restrictions]\naction/lock_screen=%s\n' "$val" >"$dir/kdeglobals.new"
chmod 644 "$dir/kscreenlockerrc.new" "$dir/kdeglobals.new"
mv -T "$dir/kscreenlockerrc.new" "$dir/kscreenlockerrc"
mv -T "$dir/kdeglobals.new" "$dir/kdeglobals"
echo "webtop-lock-config: lock screen $val"
