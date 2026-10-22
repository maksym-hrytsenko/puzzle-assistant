#!/usr/bin/env bash
# Compiles the app's Vision code + this harness for macOS and runs it on img/.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:-$root/tools/ios_pipeline_check/output}"
build="$root/tools/ios_pipeline_check/.build"
mkdir -p "$out" "$build/models"
for m in ImageEncoder PromptEncoder MaskDecoder; do
  pkg="$root/PuzzleAssistant/MLModels/SAM2_1Small${m}FLOAT16.mlpackage"
  [ -d "$build/models/SAM2_1Small${m}FLOAT16.mlmodelc" ] || xcrun coremlcompiler compile "$pkg" "$build/models" >/dev/null
done
xcrun -sdk macosx metal "$root/PuzzleAssistant/Vision/Matching.metal" -o "$build/Matching.metallib"
v="$root/PuzzleAssistant/Vision"
swiftc -O -o "$build/check" "$root/tools/ios_pipeline_check/main.swift" \
  "$v/MaskGeometry.swift" "$v/PixelBuffer.swift" "$v/BackgroundModel.swift" "$v/SAMSegmenter.swift" \
  "$v/PieceDetector.swift" "$v/PuzzleGrid.swift" "$v/ReferenceMatcher.swift" "$v/ReferencePreparer.swift" "$v/PictureBoundary.swift"
SAM_MODELS_DIR="$build/models" MATCHING_METALLIB="$build/Matching.metallib" "$build/check" "$root/img" "$out" 2>&1 | grep -v E5RT
