#!/bin/zsh
set -eu
project_root=${0:A:h}
source_app="$project_root/build/FOI Surround Monitor.app"
if (( $# > 1 )); then
  print -u2 'Usage: zsh install.sh [destination-directory] (default: ~/Applications)'
  exit 2
fi
applications=${1:-"$HOME/Applications"}
applications=${applications:a}
destination="$applications/FOI Surround Monitor.app"
if [[ ! -d "$source_app" ]]; then
  print -u2 'Build the app first with zsh build.sh.'
  exit 1
fi
if [[ -e "$destination" || -L "$destination" ]]; then
  print -u2 "An app already exists at $destination. Quit it and move it aside before installing this build."
  exit 1
fi
/usr/bin/python3 -B - "$project_root" "$source_app" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from package_app import verify_local_signature
verify_local_signature(Path(sys.argv[2]))
PY
mkdir -p "$applications"
staging=$(/usr/bin/mktemp -d "$applications/.foi-install.XXXXXX")
trap '/bin/rm -rf "$staging"' EXIT
/usr/bin/ditto "$source_app" "$staging/FOI Surround Monitor.app"
/usr/bin/python3 -B - "$project_root" "$staging/FOI Surround Monitor.app" "$destination" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from package_app import rename_exclusive, verify_local_signature
try:
    verify_local_signature(Path(sys.argv[2]))
    rename_exclusive(sys.argv[2], sys.argv[3])
    verify_local_signature(Path(sys.argv[3]))
except OSError as exc:
    raise SystemExit(f"Installation refused without replacing the destination: {exc}")
PY
print "Installed: $destination"
print 'Open it in Finder. Installation does not launch audio or request permission.'
