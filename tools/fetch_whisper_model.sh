#!/usr/bin/env bash
# Downloads a ggml Whisper model for on-device transcription.
#
#   ./tools/fetch_whisper_model.sh            # tiny.en, quantised (~31 MB)
#   ./tools/fetch_whisper_model.sh base q5_1  # better accuracy (~57 MB)
#
# Quantised q5_1 weights roughly halve both the download and the runtime
# memory with very little accuracy cost - worth it on phones.
set -euo pipefail

MODEL="${1:-tiny.en}"
QUANT="${2:-q5_1}"
OUT_DIR="${3:-assets/models}"
NAME="ggml-${MODEL}-${QUANT}.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${NAME}"

mkdir -p "$OUT_DIR"
echo "Downloading ${NAME} ..."
curl -L --fail --progress-bar -o "${OUT_DIR}/${NAME}" "$URL"
echo "Saved ${OUT_DIR}/${NAME} ($(du -h "${OUT_DIR}/${NAME}" | cut -f1))"
echo
echo "Note: use a multilingual model (drop the .en suffix) for languages other than English."
