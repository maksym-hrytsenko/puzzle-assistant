"""Test: find every loose puzzle piece on a photo and box it.

No matching against the reference — only detection. Pipeline:
1. Candidate points: centres of "thick" non-background areas (distance-transform
   peaks of a colour-based foreground mask). Over-generation is fine.
2. Segment Anything 2.1 turns every point into an object mask (all points of an
   image tile are sent in one batch, so the heavy image encoder runs once per tile).
3. Masks that do not look like one puzzle piece are dropped (size, shape,
   background share), duplicates are merged.
4. Every piece gets a rotated box and a number.

User-facing output is in Ukrainian.
"""

from __future__ import annotations

import argparse
import math
import time
from pathlib import Path

import cv2
import numpy as np

import puzzle_match as pm

WORK_SCALE = 0.5          # photos are processed at half resolution (piece ~150 px)
TILE = 1024               # SAM input tile, px at WORK_SCALE
STRIDE = 700              # tiles overlap so that every piece is whole in some tile
GRID_STEP = 70            # px at WORK_SCALE between prompt points (~half a piece)
TEXTURE_MIN = 6.0         # local grey-level std above which a pixel is "printed"
SAM_WEIGHTS = Path(__file__).resolve().parent / "models" / "sam2.1_b.pt"


def piece_like(region: np.ndarray, fg_share: float) -> tuple[bool, float]:
    """Shape test for a single classic piece; returns (ok, solidity)."""
    contours, _ = cv2.findContours(region, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return False, 0.0
    contour = max(contours, key=cv2.contourArea)
    area = cv2.contourArea(contour)
    hull = cv2.contourArea(cv2.convexHull(contour))
    solidity = area / max(hull, 1)
    (_, _), (w, h), _ = cv2.minAreaRect(contour)
    aspect = max(w, h) / max(min(w, h), 1)
    # Pieces are not convex (tabs/blanks), not elongated, and lie on top of background.
    ok = 0.55 < solidity < 0.97 and aspect < 1.8 and fg_share > 0.85
    return ok, solidity


def peaks(mask: np.ndarray, min_dist: float) -> np.ndarray:
    dist = cv2.distanceTransform(mask, cv2.DIST_L2, 5)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
    ys, xs = np.nonzero((dist == cv2.dilate(dist, kernel)) & (dist > min_dist))
    return np.stack([xs, ys], axis=1).astype(np.float32)


def segment_points(work, points, model, stats) -> list[dict]:
    """Run SAM on overlapping tiles; every point becomes one candidate mask."""
    H, W = work.shape[:2]
    found = []
    for ty in sorted({min(y, max(H - TILE, 0)) for y in range(0, H, STRIDE)}):
        for tx in sorted({min(x, max(W - TILE, 0)) for x in range(0, W, STRIDE)}):
            tile = np.ascontiguousarray(work[ty:ty + TILE, tx:tx + TILE])
            th, tw = tile.shape[:2]
            # Only points away from the tile border: their piece fits in this tile.
            local = points - [tx, ty]
            inside = (local[:, 0] > 60) & (local[:, 1] > 60) & (local[:, 0] < tw - 60) & (local[:, 1] < th - 60)
            local = local[inside]
            if len(local) == 0:
                continue
            result = model(tile, points=local.tolist(), labels=[1] * len(local), verbose=False)[0]
            if result.masks is None:
                continue
            masks = result.masks.data.cpu().numpy() > 0.5
            scores = result.boxes.conf.cpu().numpy()
            # Ultralytics may drop some masks, so masks are not matched to points by
            # index; each mask is taken on its own (its largest connected part).
            for mask, score in zip(masks, scores):
                n, labels, cc, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8))
                if n < 2:
                    stats["no_label"] += 1
                    continue
                label = 1 + int(np.argmax(cc[1:, cv2.CC_STAT_AREA]))
                region = (labels == label).astype(np.uint8)
                ys, xs = np.nonzero(region)
                if xs.min() <= 1 or ys.min() <= 1 or xs.max() >= tw - 2 or ys.max() >= th - 2:
                    stats["border"] += 1  # cut by the tile border; another tile sees it whole
                    continue
                contours, _ = cv2.findContours(region, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
                contour = (max(contours, key=cv2.contourArea) + [tx, ty]).astype(np.float32)
                found.append({"contour": contour, "area": float(len(xs)), "score": float(score),
                              "pixels": (ys + ty, xs + tx)})
    return found


def detect(image: np.ndarray, model, log) -> list[dict]:
    work = pm.resize(image, WORK_SCALE)
    H, W = work.shape[:2]
    fg = cv2.resize(pm.foreground_mask(pm.resize(image, pm.SEGMENT_SCALE)), (W, H),
                    interpolation=cv2.INTER_NEAREST)
    stats = {"no_label": 0, "border": 0, "shape": 0, "size": 0, "assembled": 0, "duplicate": 0}

    # Background = table colour AND smooth. Either test alone fails: light pieces
    # match the paper colour, dark pieces are smooth.
    gray = cv2.cvtColor(work, cv2.COLOR_BGR2GRAY).astype(np.float32)
    mean = cv2.blur(gray, (7, 7))
    smooth = np.sqrt(np.maximum(cv2.blur(gray * gray, (7, 7)) - mean * mean, 0)) < TEXTURE_MIN
    background = ((fg == 0) & smooth).astype(np.uint8)
    texture = background

    # Pass 1: a regular grid of points (about two per piece width). A colour
    # mask is not used here: it misses light pieces that look like paper.
    ys, xs = np.mgrid[GRID_STEP // 2:H:GRID_STEP, GRID_STEP // 2:W:GRID_STEP]
    points = np.stack([xs.ravel(), ys.ravel()], axis=1).astype(np.float32)
    log(f"    прохід 1: точок сітки {len(points)}")
    found = segment_points(work, points, model, stats)
    found = [f for f in found if shape_ok(f, texture, stats)]
    typical = float(np.median([f["area"] for f in found if f["score"] > 0.8] or [f["area"] for f in found]))
    assembled = assembled_mask(fg, typical)
    kept = select(found, typical, assembled, (H, W), stats, [])

    # Pass 2: new points on foreground that no kept piece covers yet.
    covered = np.zeros((H, W), np.uint8)
    for p in kept:
        covered[p["pixels"]] = 1
    rest = fg.copy()
    rest[cv2.dilate(covered, np.ones((9, 9), np.uint8)) > 0] = 0
    rest[assembled > 0] = 0
    rest = cv2.morphologyEx(rest, cv2.MORPH_OPEN, np.ones((9, 9), np.uint8))
    points = peaks(rest, 14)
    log(f"    прохід 2: точок на ще не покритих ділянках {len(points)}")
    found2 = [f for f in segment_points(work, points, model, stats) if shape_ok(f, texture, stats)]
    kept = select(found2, typical, assembled, (H, W), stats, kept)
    log(f"    відкинуто масок: {stats}")
    log(f"    типова площа шматка: {typical:.0f} px (при масштабі {WORK_SCALE})")
    return kept, assembled


def shape_ok(f: dict, texture: np.ndarray, stats) -> bool:
    ys, xs = f["pixels"]
    # Share of non-background pixels: low when SAM grabbed table between pieces.
    fg_share = float((texture[ys, xs] == 0).mean())
    canvas = np.zeros((ys.max() - ys.min() + 3, xs.max() - xs.min() + 3), np.uint8)
    canvas[ys - ys.min() + 1, xs - xs.min() + 1] = 1
    ok, _ = piece_like(canvas, fg_share)
    if not ok:
        stats["shape"] += 1
    return ok


def assembled_mask(fg: np.ndarray, typical: float) -> np.ndarray:
    """Already assembled part: foreground without any background gaps over
    a window of a few pieces (loose piles always show some table between pieces)."""
    win = int(math.sqrt(typical) * 2.5) | 1
    density = cv2.blur((fg > 0).astype(np.float32), (win, win))
    dense = (density > 0.97).astype(np.uint8)
    return cv2.dilate(dense, np.ones((win // 2, win // 2), np.uint8))


def select(found, typical, assembled, shape, stats, kept) -> list[dict]:
    """Keep single-piece-sized masks, best SAM score first, no duplicates."""
    occupied = np.zeros(shape, np.uint8)
    for p in kept:
        occupied[p["pixels"]] = 1
    kept = list(kept)
    for f in sorted(found, key=lambda f: -f["score"]):
        if not 0.5 * typical < f["area"] < 1.5 * typical:
            stats["size"] += 1
            continue
        ys, xs = f["pixels"]
        if (assembled[ys, xs] > 0).mean() > 0.5:
            stats["assembled"] += 1
            continue
        if (occupied[ys, xs] > 0).mean() > 0.25:
            stats["duplicate"] += 1
            continue
        kept.append(f)
        occupied[ys, xs] = 1
    return kept


PALETTE = [(0, 0, 255), (0, 200, 0), (255, 80, 0), (0, 200, 255), (255, 0, 200), (255, 255, 0)]


def draw(image: np.ndarray, pieces: list[dict], assembled: np.ndarray, out_path: Path) -> None:
    canvas = pm.resize(image, WORK_SCALE).copy()
    # Shade the already assembled part: it is not searched.
    shade = assembled > 0
    canvas[shade] = (canvas[shade] * 0.45).astype(np.uint8)
    for i, p in enumerate(pieces, 1):
        # Exact SAM outline of the piece.
        color = PALETTE[i % len(PALETTE)]
        cv2.polylines(canvas, [p["contour"].astype(np.int32)], True, color, 3, cv2.LINE_AA)
        cx, cy = p["contour"].reshape(-1, 2).mean(0)
        cv2.putText(canvas, str(i), (int(cx) - 14, int(cy) + 8), cv2.FONT_HERSHEY_SIMPLEX, 0.8,
                    (255, 255, 255), 4, cv2.LINE_AA)
        cv2.putText(canvas, str(i), (int(cx) - 14, int(cy) + 8), cv2.FONT_HERSHEY_SIMPLEX, 0.8,
                    color, 2, cv2.LINE_AA)
    cv2.imwrite(str(out_path), canvas, [cv2.IMWRITE_JPEG_QUALITY, 90])


def main() -> None:
    parser = argparse.ArgumentParser(description="Тест: знайти й обвести всі шматки на фото")
    root = Path(__file__).resolve().parents[2]
    parser.add_argument("photos", nargs="*", type=Path,
                        default=[root / "img" / n for n in ("IMG_8775.JPG", "IMG_8776.JPG", "IMG_8777.JPG")])
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "output")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    from ultralytics import SAM
    SAM_WEIGHTS.parent.mkdir(exist_ok=True)
    model = SAM(str(SAM_WEIGHTS))

    for path in args.photos:
        started = time.time()
        print(f"\n{path.name}:", flush=True)
        image = pm.load_image(path)
        pieces, assembled = detect(image, model, lambda m: print(m, flush=True))
        out = args.out / f"found_{path.stem}.jpg"
        draw(image, pieces, assembled, out)
        print(f"    ЗНАЙДЕНО ШМАТКІВ: {len(pieces)}  ({time.time() - started:.0f} с) -> {out.name}")


if __name__ == "__main__":
    main()
