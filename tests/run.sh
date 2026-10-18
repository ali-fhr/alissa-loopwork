#!/bin/bash
# Build-and-smoke the base image locally (same steps CI runs):
#   tests/run.sh [slim|polyglot|all]      (default: slim)
# Images are tagged alissa-loopwork-base:smoke-<variant>.
set -euo pipefail
cd "$(dirname "$0")/.."

VARIANTS="${1:-slim}"
[ "$VARIANTS" = all ] && VARIANTS="slim polyglot"

for VARIANT in $VARIANTS; do
    case "$VARIANT" in
        slim|polyglot) ;;
        *) echo "usage: tests/run.sh [slim|polyglot|all]" >&2; exit 2 ;;
    esac
    IMAGE="alissa-loopwork-base:smoke-${VARIANT}"
    docker build --target "$VARIANT" -t "$IMAGE" .
    # --entrypoint overrides the stub (which exits 1 by design); the smoke
    # scripts are mounted, not baked — the image ships no test files.
    docker run --rm \
        --entrypoint /bin/bash \
        -e LOOPWORK_VARIANT="$VARIANT" \
        -v "$(pwd)/tests/smoke.sh:/smoke.sh:ro" \
        "$IMAGE" /smoke.sh
    if [ "$VARIANT" = polyglot ]; then
        docker run --rm \
            --entrypoint /bin/bash \
            -v "$(pwd)/tests/polyglot:/polyglot:ro" \
            "$IMAGE" /polyglot/smoke.sh
    fi
done

# Both variants built: assert polyglot = slim + layers (its layer chain starts
# with slim's), the same gate ci.yml and publish.yml run. Needs jq on the host.
case " $VARIANTS " in
    *" slim "*" polyglot "*)
        s="$(docker image inspect -f '{{json .RootFS.Layers}}' alissa-loopwork-base:smoke-slim)"
        p="$(docker image inspect -f '{{json .RootFS.Layers}}' alissa-loopwork-base:smoke-polyglot)"
        if jq -en --argjson s "$s" --argjson p "$p" \
            '($p | length) > ($s | length) and $p[:($s | length)] == $s' > /dev/null; then
            echo "ok   polyglot = slim + layers"
        else
            echo "FAIL polyglot's layer chain does not start with slim's" >&2
            exit 1
        fi
        ;;
esac
