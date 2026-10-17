#!/bin/bash
# Publishes a build from GitHub Actions at home.hellupeptic.org/app, where
# SideStore picks it up as an update. Run on the Pi:
#   ./publish.sh            newest successful build
#   ./publish.sh <run-id>   a specific one
# The site reads data/app/builds.json; older .ipa files beyond the last
# three are deleted to save space.
set -euo pipefail

REPO=HelluPeptic/portal-ios
APP_DIR=/home/mc/website/data/app
HERE="$(cd "$(dirname "$0")" && pwd)"

RUN="${1:-$(gh run list -R "$REPO" --workflow build.yml --status success --limit 1 --json databaseId --jq '.[0].databaseId')}"
if [ -z "$RUN" ] || [ "$RUN" = "null" ]; then
    echo "No successful build to publish" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gh run download "$RUN" -R "$REPO" -n portal-ipa -D "$TMP"

mkdir -p "$APP_DIR"
python3 -I - "$TMP" "$APP_DIR" "$HERE" <<'EOF'
import json, os, shutil, subprocess, sys, datetime
tmp, app_dir, here = sys.argv[1:4]
info = json.load(open(os.path.join(tmp, 'build-info.json')))
version, build = info['version'], int(info['build'])
src = os.path.join(tmp, f'Portal-{version}.ipa')
name = f'portal-{build}.ipa'
shutil.copyfile(src, os.path.join(app_dir, name))

# What changed, for SideStore's update notes: the commit's subject line.
try:
    notes = subprocess.run(['git', '-C', here, 'log', '-1', '--format=%s', info['commit']],
                           capture_output=True, text=True, check=True).stdout.strip()
except Exception:
    notes = ''

manifest = os.path.join(app_dir, 'builds.json')
try:
    builds = json.load(open(manifest))
except Exception:
    builds = []
builds = [b for b in builds if int(b['build']) != build]
builds.append({
    'version': version,
    'build': build,
    'date': datetime.date.today().isoformat(),
    'file': name,
    'size': os.path.getsize(os.path.join(app_dir, name)),
    'notes': notes,
    'minOS': '16.0'
})
builds.sort(key=lambda b: int(b['build']))
for old in builds[:-3]:
    try:
        os.remove(os.path.join(app_dir, old['file']))
    except FileNotFoundError:
        pass
builds = builds[-3:]
with open(manifest + '.tmp', 'w') as f:
    json.dump(builds, f, indent=2)
os.replace(manifest + '.tmp', manifest)
print(f'Published {version} (build {build}), {os.path.getsize(os.path.join(app_dir, name)) // 1048576} MB')
EOF
