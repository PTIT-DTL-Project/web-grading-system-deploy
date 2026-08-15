#!/usr/bin/env bash
set -euo pipefail

echo "=== Getting currently running image tags from k3s ==="
RUNNING_TAGS_FILE=$(mktemp)
kubectl get pods -n web-grading -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | grep -oP ':\K[^:]+$' | sort -u > "$RUNNING_TAGS_FILE"

echo "Running tags:"
cat "$RUNNING_TAGS_FILE"

if [ ! -s "$RUNNING_TAGS_FILE" ]; then
  echo "No running images found in web-grading namespace."
  rm -f "$RUNNING_TAGS_FILE"
  exit 0
fi

echo
echo "--- crictl (containerd) ---"

CRICTL_JSON=$(mktemp)
if ! sudo k3s crictl images --output json > "$CRICTL_JSON" 2>/dev/null; then
  echo "Warning: k3s crictl failed. Try with ctr instead."
  rm -f "$CRICTL_JSON" "$RUNNING_TAGS_FILE"
  exit 1
fi

python3 -c "
import json, subprocess, sys

with open('$RUNNING_TAGS_FILE') as f:
  running_tags = set(line.strip() for line in f if line.strip())

with open('$CRICTL_JSON') as f:
  data = json.load(f)

removed = 0

for img in data.get('images', []):
  tags = img.get('repoTags', [])
  if not tags:
    continue
  if not any('web-grading' in t or 'vucongtuanduong' in t for t in tags):
    continue
  img_tag = tags[0].split(':')[-1]
  if img_tag in running_tags:
    print(f'Keep:   {tags[0]}')
    continue
  print(f'Remove: {tags[0]}')
  subprocess.run(['sudo', 'k3s', 'crictl', 'rmi', img['id']], capture_output=True)
  removed += 1

print(f'Done. Removed {removed} images from crictl.')
"

rm -f "$CRICTL_JSON"

echo
echo "--- docker ---"
docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E 'web-grading|vucongtuanduong' | while read -r img; do
  tag="${img##*:}"
  keep=0
  while read -r rt; do
    [ -z "$rt" ] && continue
    if [ "$tag" = "$rt" ]; then
      keep=1
      break
    fi
  done < "$RUNNING_TAGS_FILE"
  if [ "$keep" = "1" ]; then
    echo "Keep:   $img"
  else
    echo "Remove: $img"
    docker rmi "$img" 2>/dev/null || true
  fi
done

rm -f "$RUNNING_TAGS_FILE"
