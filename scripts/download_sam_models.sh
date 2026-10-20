#!/usr/bin/env bash
# Downloads Apple's Core ML conversion of Segment Anything 2.1 (small) into the app.
# The models are ~94 MB and are not committed to git.
set -euo pipefail
repo="apple/coreml-sam2.1-small"
dest="$(cd "$(dirname "$0")/.." && pwd)/PuzzleAssistant/MLModels"
mkdir -p "$dest"
for part in ImageEncoder PromptEncoder MaskDecoder; do
  pkg="SAM2_1Small${part}FLOAT16.mlpackage"
  for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    out="$dest/$pkg/$f"
    if [ ! -s "$out" ]; then
      mkdir -p "$(dirname "$out")"
      curl -fL --retry 3 -o "$out" "https://huggingface.co/$repo/resolve/main/$pkg/$f"
    fi
  done
done
echo "SAM 2.1 models are in $dest"
