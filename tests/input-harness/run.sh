#!/bin/bash
# PocketForge input harness - one command (AC1).
#
#   tests/input-harness/run.sh [--out DIR] [--no-build] [--rm-image]
#
# Builds the harness container (pinned gamescope fork + clients), runs a
# headless gamescope session with all test clients and the negative-control
# client inside it, then evaluates the run with report.py on the host.
# Prints PASS/FAIL with transcript paths.
#
# Safety: docker run --rm only, no anonymous volumes, never privileged,
# never an init/systemd PID 1, never mounts the host root or the docker
# socket. Images are labelled pf.bead=tsp-ihne1.2. Blast radius: README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=tests/input-harness/pins.env
. "$HERE/pins.env"

OUT=""
BUILD=1
RM_IMAGE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT="${2:?--out needs a directory}"; shift 2 ;;
		--no-build) BUILD=0; shift ;;
		--rm-image) RM_IMAGE=1; shift ;;
		*) echo "usage: run.sh [--out DIR] [--no-build] [--rm-image]" >&2; exit 2 ;;
	esac
done

if [ -z "$OUT" ]; then
	OUT="$HOME/.cache/pf-input-harness/run-$(date -u +%Y%m%dT%H%M%SZ)"
fi

"$HERE/tools/require-empty-output.sh" "$OUT"

if [ ! -e /dev/uinput ]; then
	echo "FAIL: input-harness reason=no_uinput hint=/dev/uinput missing or not permitted on this host"
	exit 1
fi

if [ "$BUILD" = 1 ]; then
	echo "==> building $IMAGE_TAG (gamescope ${GAMESCOPE_COMMIT:0:12})"
	docker build \
		-f tests/input-harness/Containerfile \
		--build-arg GAMESCOPE_URL="$GAMESCOPE_URL" \
		--build-arg GAMESCOPE_COMMIT="$GAMESCOPE_COMMIT" \
		--build-arg WAYLAND_PROTOCOLS_URL="$WAYLAND_PROTOCOLS_URL" \
		--build-arg WAYLAND_PROTOCOLS_COMMIT="$WAYLAND_PROTOCOLS_COMMIT" \
		--build-arg BASE_IMAGE="$BASE_IMAGE" \
		--label pf.bead=tsp-ihne1.2 \
		-t "$IMAGE_TAG" .
fi

OUT="$(cd "$OUT" && pwd)"

echo "==> running headless session, output in $OUT"
set +e
docker run --rm \
	--label pf.bead=tsp-ihne1.2 \
	--network none \
	--device /dev/uinput \
	--device-cgroup-rule "c 13:* rmw" \
	-v /dev/input:/dev/input \
	-v "$OUT":/out \
	-e HOST_UID="$(id -u)" \
	-e HOST_GID="$(id -g)" \
	-e OUT=/out \
	"$IMAGE_TAG"
rc=$?
set -e

if [ "$RM_IMAGE" = 1 ]; then
	docker image rm "$IMAGE_TAG"
else
	echo "==> keeping image $IMAGE_TAG (labelled pf.bead=tsp-ihne1.2);"
	echo "    remove with: docker image rm $IMAGE_TAG"
fi

echo "==> transcripts:"
find "$OUT" -name '*.jsonl' -print | sort
echo "==> screenshots:"
find "$OUT/screenshots" -name '*.png' -print | sort

echo "==> verdict"
set +e
python3 -B tests/input-harness/report/report.py "$OUT"
report_rc=$?
set -e

if [ $rc -ne 0 ] && [ $report_rc -eq 0 ]; then
	echo "FAIL: input-harness reason=container_rc hint=container exited rc=$rc but report passed"
	exit 1
fi
exit $report_rc
