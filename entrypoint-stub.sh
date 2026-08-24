#!/bin/sh
# Stub entrypoint shipped by the loopwork BASE image (ghcr.io/ali-fhr/
# alissa-loopwork-base). The base is a substrate, not a daemon: every leaf
# image must COPY its own entrypoint over /usr/local/bin/entrypoint.sh.
# Reaching this stub at runtime means you ran the base image bare, or a leaf
# forgot its COPY — fail loudly either way.
echo "[alissa-loopwork-base] This is the loopwork BASE image — it runs no daemon." >&2
echo "[alissa-loopwork-base] Leaf images must COPY their entrypoint to /usr/local/bin/entrypoint.sh." >&2
echo "[alissa-loopwork-base] See https://github.com/ali-fhr/alissa-loopwork" >&2
exit 1
