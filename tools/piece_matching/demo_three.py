"""Demo: pick a few clearly separated pieces, show them on white and show the
most likely places for each of them on the full picture with probabilities.

Reuses the pipeline from puzzle_match.py. User-facing output is in Ukrainian.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import cv2
import numpy as np

import puzzle_match as pm

MIN_PROBABILITY = 0.05  # candidates below this are not shown

PIECE_COLORS = [(40, 40, 230), (230, 120, 20), (30, 170, 30), (200, 40, 200), (20, 190, 220)]


def texture_score(image: np.ndarray, piece: pm.Piece) -> float:
    """Pieces with more detail are easier to locate; flat ones are hopeless."""
    crop, mask, _ = pm.crop_piece(image, piece, margin=0)
    mask = cv2.erode(mask, np.ones((15, 15), np.uint8))
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY).astype(np.float32)
    lap = cv2.Laplacian(cv2.GaussianBlur(gray, (5, 5), 0), cv2.CV_32F)
    return float(lap[mask > 0].std()) if (mask > 0).any() else 0.0


def body_square(region: np.ndarray):
    """Find the square body of a classic piece (tabs removed by a morphological opening).

    Returns (ok, angle, side): ok is False when the shape is not a whole classic
    piece (a fragment, two merged pieces, ...).
    """
    area = float(region.sum())
    k = int(0.5 * math.sqrt(area)) | 1
    body = cv2.morphologyEx(region, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
    contours, _ = cv2.findContours(body, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not contours:
        return False, 0.0, 0.0
    contour = max(contours, key=cv2.contourArea)
    (_, _), (w, h), angle = cv2.minAreaRect(contour)
    if min(w, h) < 1:
        return False, 0.0, 0.0
    aspect = max(w, h) / min(w, h)
    fill = cv2.contourArea(cv2.convexHull(contour)) / (w * h)
    share = w * h / area
    ok = aspect < 1.25 and fill > 0.75 and 0.35 < share < 1.0
    return ok, float(angle), float((w + h) / 2)


def paper_mask(small: np.ndarray) -> np.ndarray:
    """Pieces = everything that is not white paper (paper colour estimated from the photo)."""
    lab = cv2.cvtColor(small, cv2.COLOR_BGR2Lab).astype(np.int16)
    chroma = np.hypot(lab[..., 1] - 128, lab[..., 2] - 128)
    paper_lab = np.median(lab[(lab[..., 0] > 170) & (chroma < 15)], axis=0)
    paper = (np.abs(lab[..., 0] - paper_lab[0]) < 95) & \
            (np.hypot(lab[..., 1] - paper_lab[1], lab[..., 2] - paper_lab[2]) < 6)
    mask = (~paper).astype(np.uint8) * 255
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    # Fill small paper-coloured spots inside pieces (white details, glare).
    n, labels, stats, _ = cv2.connectedComponentsWithStats(255 - mask, connectivity=4)
    holes = np.where(stats[:, cv2.CC_STAT_AREA] < 250)[0]
    mask[np.isin(labels, holes[holes > 0])] = 255
    return mask


def segment_whole_pieces(image: np.ndarray, photo: str):
    """Whole pieces: split touching pieces at their contact points.

    A strong erosion leaves only the core of each piece body (tabs and contacts
    disappear); every core is then grown back over the piece mask.
    """
    small = pm.resize(image, pm.SEGMENT_SCALE)
    mask = paper_mask(small)
    dist = cv2.distanceTransform(mask, cv2.DIST_L2, 5)
    core = (dist > 12).astype(np.uint8)
    n, markers = cv2.connectedComponents(core)
    markers = markers + 1
    markers[(mask > 0) & (core == 0)] = 0
    relief = cv2.cvtColor(255 - np.clip(dist * 8, 0, 255).astype(np.uint8), cv2.COLOR_GRAY2BGR)
    labels = cv2.watershed(relief, markers.astype(np.int32))
    out = []
    k = 1 / pm.SEGMENT_SCALE
    for label in range(2, n + 1):
        region = (labels == label).astype(np.uint8)
        area = int(region.sum())
        if not 1500 < area < 6000:
            continue
        x, y, w, h = cv2.boundingRect(region)
        if x < 5 or y < 5 or x + w > small.shape[1] - 5 or y + h > small.shape[0] - 5:
            continue
        ok, angle, side = body_square(region)
        if not ok:
            continue
        ring = cv2.dilate(region, np.ones((7, 7), np.uint8)) - cv2.dilate(region, np.ones((3, 3), np.uint8))
        isolation = float((mask[ring > 0] == 0).mean())
        # Smooth full-resolution outline from the upscaled region.
        big = cv2.resize(cv2.GaussianBlur(region.astype(np.float32), (5, 5), 0), None, fx=k, fy=k,
                         interpolation=cv2.INTER_LINEAR)
        contours, _ = cv2.findContours((big > 0.5).astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        contour = max(contours, key=cv2.contourArea).astype(np.float32)
        full = np.zeros(big.shape, np.uint8)
        cv2.drawContours(full, [contour.astype(np.int32)], -1, 1, -1)
        rdist = cv2.distanceTransform(full, cv2.DIST_L2, 5)
        _, radius, _, center = cv2.minMaxLoc(rdist)
        piece = pm.Piece(0, photo, contour, (float(center[0]), float(center[1])), radius,
                         float(full.sum()), isolation)
        out.append((piece, angle, side * k))
    return out


SAM_WEIGHTS = Path(__file__).resolve().parent / "models" / "sam2.1_b.pt"
_sam_model = None


def sam_model():
    """Segment Anything 2.1 (base): outlines an object from one point on it.

    Classic colour/edge methods cannot tell the border between two touching
    pieces from a line in the printed picture; SAM is trained on object
    boundaries and separates them reliably. Weights download on first use.
    """
    global _sam_model
    if _sam_model is None:
        from ultralytics import SAM
        SAM_WEIGHTS.parent.mkdir(exist_ok=True)
        _sam_model = SAM(str(SAM_WEIGHTS))
    return _sam_model


def segment_at(image: np.ndarray, x: float, y: float, photo: str, half: int = 400):
    """Cut out the single whole piece under (x, y) at full resolution."""
    x0, y0 = int(max(x - half, 0)), int(max(y - half, 0))
    crop = np.ascontiguousarray(image[y0:int(y + half), x0:int(x + half)])
    px, py = int(x - x0), int(y - y0)
    result = sam_model()(crop, points=[[px, py]], labels=[1], verbose=False)
    region = (result[0].masks.data.cpu().numpy()[0] > 0.5).astype(np.uint8)
    region = cv2.morphologyEx(region, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    n, labels = cv2.connectedComponents(region)
    if labels[py, px] == 0:
        raise RuntimeError(f"У точці ({x:.0f}, {y:.0f}) не знайдено шматка")
    region = (labels == labels[py, px]).astype(np.uint8)
    contours, _ = cv2.findContours(region, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    contour = (max(contours, key=cv2.contourArea) + [x0, y0]).astype(np.float32)
    full = np.zeros(crop.shape[:2], np.uint8)
    cv2.drawContours(full, [(contour - [x0, y0]).astype(np.int32)], -1, 1, -1)
    rdist = cv2.distanceTransform(full, cv2.DIST_L2, 5)
    _, radius, _, center = cv2.minMaxLoc(rdist)
    piece = pm.Piece(0, photo, contour, (center[0] + x0, center[1] + y0), radius, float(full.sum()), 1.0)
    ok, angle, side = body_square(full)
    return piece, angle, side


def pick_pieces(image, found, count):
    """Best isolated whole pieces, then the most detailed among them."""
    found = sorted(found, key=lambda f: -f[0].isolation)[:count * 3]
    found.sort(key=lambda f: -texture_score(image, f[0]))
    return found[:count]


def upright_angle(piece: pm.Piece, body_angle: float) -> float:
    """Rotation that makes the body square axis-aligned (mod 90 degrees).

    The straight parts of the body sides dominate the outline directions, so the
    peak of a length-weighted histogram of edge directions (mod 90) gives the
    body orientation; tabs and blanks are curved and spread out.
    """
    poly = cv2.approxPolyDP(piece.contour.reshape(-1, 1, 2).astype(np.float32), 3, True).reshape(-1, 2).astype(np.float32)
    seg = np.roll(poly, -1, axis=0) - poly
    length = np.hypot(seg[:, 0], seg[:, 1])
    direction = np.degrees(np.arctan2(seg[:, 1], seg[:, 0])) % 90
    hist = np.zeros(90)
    for d, l in zip(direction, length):
        for k in range(-4, 5):
            hist[int(round(d + k)) % 90] += l * l * math.exp(-k * k / 8)
    edge_angle = float(np.argmax(hist))
    # Rotating by this angle makes the dominant edges horizontal/vertical.
    best, best_area = 0.0, float("inf")
    for a in (edge_angle, (-edge_angle) % 90):
        matrix = cv2.getRotationMatrix2D(piece.center, a, 1.0)
        pts = cv2.transform(piece.contour.reshape(-1, 1, 2), matrix).reshape(-1, 2)
        w, h = pts.max(0) - pts.min(0)
        if w * h < best_area:
            best, best_area = a, w * h
    return best


def location_candidates(view: pm.PieceView, scale: float, base_angle: float, top_k: int = 12,
                        keep: int = 4) -> list[tuple[float, float, float, float, float]]:
    """Distinct candidate places: (score, angle, scale, x, y), best first.

    In the assembled puzzle every piece sits upright, so only the 4 rotations
    that keep the body square axis-aligned are tried (plus a small tolerance).
    """
    angles = [base_angle + 90 * k for k in range(4)]
    coarse = pm.coarse_candidates(view, scale, angles=angles)
    coarse = [c for s in (0.94, 1.06) for c in pm.coarse_candidates(view, scale * s, angles=angles)] + coarse
    coarse.sort(key=lambda c: -c[0])
    refined = sorted((pm.refine(view, c, scale, half_step=2.5) for c in coarse[:top_k]), key=lambda r: -r[0])
    distinct = []
    min_gap = view.radius * 2.5 * scale
    for r in refined:
        if all(math.hypot(r[3] - d[3], r[4] - d[4]) > min_gap for d in distinct):
            distinct.append(r)
        if len(distinct) == keep:
            break
    return distinct


def probabilities(scores: list[float], temperature: float = 0.025) -> list[float]:
    """Softmax over candidate scores: how the probability splits between candidates.

    Includes an implicit 'somewhere else' option (score of a typical wrong match),
    so a single weak candidate does not get 100%.
    """
    background = 0.58
    values = np.array(list(scores) + [background]) / temperature
    values = np.exp(values - values.max())
    values /= values.sum()
    return [float(v) for v in values[:-1]]


def white_sheet(image: np.ndarray, pieces: list[pm.Piece], angles: list[float], out_path: Path,
                tile: int = 420) -> None:
    """Whole pieces on white, rotated upright (body square axis-aligned)."""
    cells = []
    for number, (piece, angle) in enumerate(zip(pieces, angles), 1):
        view = pm.make_view(image, piece)
        warped = pm.warp_view(pm.PieceView(0, view.crop, cv2.dilate(view.mask, np.ones((9, 9), np.uint8)),
                                           view.center, view.radius), angle, 1.0)
        crop, mask, _ = warped
        crop[mask == 0] = 255
        h, w = crop.shape[:2]
        k = (tile - 40) / max(h, w)
        crop = cv2.resize(crop, None, fx=k, fy=k, interpolation=cv2.INTER_AREA)
        cell = np.full((tile + 70, tile, 3), 255, np.uint8)
        y0, x0 = 70 + (tile - crop.shape[0]) // 2, (tile - crop.shape[1]) // 2
        cell[y0:y0 + crop.shape[0], x0:x0 + crop.shape[1]] = crop
        color = PIECE_COLORS[(number - 1) % len(PIECE_COLORS)]
        cv2.putText(cell, str(number), (tile // 2 - 20, 55), cv2.FONT_HERSHEY_SIMPLEX, 1.8, color, 4, cv2.LINE_AA)
        cells.append(cv2.copyMakeBorder(cell, 10, 10, 10, 10, cv2.BORDER_CONSTANT, value=(255, 255, 255)))
    cv2.imwrite(str(out_path), np.hstack(cells), [cv2.IMWRITE_JPEG_QUALITY, 95])


def draw_locations(reference, pieces, views, results, grid, out_path: Path) -> None:
    canvas = (reference * 0.8).astype(np.uint8)
    H, W = canvas.shape[:2]
    cols, rows = grid
    for number, (piece, view, cands) in enumerate(zip(pieces, views, results), 1):
        color = PIECE_COLORS[(number - 1) % len(PIECE_COLORS)]
        for rank, (score, angle, scale, x, y, prob) in enumerate(cands):
            if prob < MIN_PROBABILITY:
                continue  # not a likely place: do not clutter the picture
            matrix = pm.piece_to_ref_matrix(piece.center, angle, scale, (x, y))
            pts = cv2.transform(piece.contour.reshape(-1, 1, 2), matrix).astype(np.int32)
            cv2.polylines(canvas, [pts], True, color, 8, cv2.LINE_AA)
            # Big ring so the place is easy to spot on the whole picture.
            cv2.circle(canvas, (int(x), int(y)), int(view.radius * scale * 5), color, 16, cv2.LINE_AA)
            row, col = pm.grid_cell(x, y, W, H, cols, rows)
            label = f"{number}{'abcd'[rank]}: {prob * 100:.0f}%  [{row},{col}]"
            pm.put_label(canvas, label, (x + view.radius * scale * 5.5, y + 25), color, 3.5, 8)
    small = pm.resize(canvas, 2600 / W)
    cv2.imwrite(str(out_path), small, [cv2.IMWRITE_JPEG_QUALITY, 92])


def draw_closeups(image, reference, pieces, results, out_path: Path, tile: int = 260) -> None:
    """Row per piece: the piece (rotated as in the best match) | each candidate place."""
    rows_img = []
    for number, (piece, cands) in enumerate(zip(pieces, results), 1):
        color = PIECE_COLORS[(number - 1) % len(PIECE_COLORS)]
        cells = []
        for rank, (score, angle, scale, x, y, prob) in enumerate(cands):
            size = int(piece.radius * 4.5 * scale)
            half = size / 2
            matrix = pm.piece_to_ref_matrix(piece.center, angle, scale, (half, half))
            if rank == 0:
                aligned = cv2.warpAffine(image, matrix, (size, size), flags=cv2.INTER_AREA,
                                         borderValue=(255, 255, 255))
                amask = np.zeros(image.shape[:2], np.uint8)
                cv2.drawContours(amask, [piece.contour.astype(np.int32)], -1, 255, -1)
                amask = cv2.warpAffine(amask, matrix, (size, size), flags=cv2.INTER_NEAREST)
                aligned[amask == 0] = 255
                cell = cv2.resize(aligned, (tile, tile))
                cells.append(caption(cell, f"Shmatok {number}", color))
            x0, y0 = int(x - half), int(y - half)
            padded = cv2.copyMakeBorder(reference, size, size, size, size, cv2.BORDER_CONSTANT)
            patch = padded[y0 + size:y0 + 2 * size, x0 + size:x0 + 2 * size].copy()
            outline_mask = np.zeros(image.shape[:2], np.uint8)
            cv2.drawContours(outline_mask, [piece.contour.astype(np.int32)], -1, 255, -1)
            outline_mask = cv2.warpAffine(outline_mask, matrix, (size, size), flags=cv2.INTER_NEAREST)
            outline = cv2.findContours(outline_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)[0]
            cv2.drawContours(patch, outline, -1, color, 2, cv2.LINE_AA)
            cell = cv2.resize(patch, (tile, tile))
            cells.append(caption(cell, f"{number}{'abcd'[rank]}: {prob * 100:.0f}%", color))
        while len(cells) < 5:
            cells.append(caption(np.full((tile, tile, 3), 255, np.uint8), "", color))
        rows_img.append(np.hstack([cv2.copyMakeBorder(c, 8, 8, 8, 8, cv2.BORDER_CONSTANT, value=(255, 255, 255))
                                   for c in cells]))
    cv2.imwrite(str(out_path), np.vstack(rows_img), [cv2.IMWRITE_JPEG_QUALITY, 95])


def caption(cell, text, color):
    out = np.full((cell.shape[0] + 40, cell.shape[1], 3), 255, np.uint8)
    out[40:] = cell
    cv2.putText(out, text, (6, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, color, 2, cv2.LINE_AA)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description="Демо: 3 шматки і можливі місця на картині")
    root = Path(__file__).resolve().parents[2]
    parser.add_argument("--images", type=Path, default=root / "img")
    parser.add_argument("--reference", default="IMG_8774.JPG")
    parser.add_argument("--photo", default="IMG_8775.JPG", help="фото, з якого брати шматки")
    parser.add_argument("--scale", type=float, default=0.307,
                        help="px еталона на 1 px фото (з калібрування для IMG_8775)")
    parser.add_argument("--count", type=int, default=3)
    parser.add_argument("--at", type=float, nargs="*", default=[3737, 2662, 4000, 2762, 3737, 3050],
                        help="координати шматків на фото: x1 y1 x2 y2 ... (порожньо = автовибір)")
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "output")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    print("Готую еталон...", flush=True)
    ref_image = pm.load_image(args.images / args.reference)
    _, corners = pm.detect_poster(ref_image)
    reference = pm.rectify_reference(ref_image, corners, "auto")
    H, W = reference.shape[:2]
    grid = pm.grid_shape(W, H, 4000)
    cache = args.out / "_reference_cache.npy"
    np.save(cache, cv2.GaussianBlur(reference, (3, 3), 0))
    pm.init_worker(str(cache))

    print(f"Виділяю шматки на {args.photo}...", flush=True)
    image = pm.load_image(args.images / args.photo)
    mask = pm.foreground_mask(pm.resize(image, pm.SEGMENT_SCALE))
    color_params = pm.color_transfer_params(image, mask, reference)
    if args.at:
        points = list(zip(args.at[0::2], args.at[1::2]))
        picked = [segment_at(image, x, y, args.photo) for x, y in points]
    else:
        found = segment_whole_pieces(image, args.photo)
        print(f"  цілих шматків класичної форми знайдено: {len(found)}")
        picked = pick_pieces(image, found, args.count)
    chosen = [p for p, _, _ in picked]
    for i, p in enumerate(chosen, 1):
        p.piece_id = i
    base_angles = [upright_angle(p, a) for p, a, _ in picked]
    white_sheet(image, chosen, base_angles, args.out / "demo_pieces_on_white.jpg")
    for i, (p, a, side) in enumerate(picked, 1):
        if side > 0:
            print(f"  шматок {i}: квадрат тіла {side:.0f} px на фото -> ~{side * args.scale:.0f} px на еталоні")

    views, results = [], []
    for number, piece in enumerate(chosen, 1):
        print(f"Шукаю шматок {number}...", flush=True)
        view = pm.make_view(image, piece, color_params)
        cands = location_candidates(view, args.scale, base_angles[number - 1])
        probs = probabilities([c[0] for c in cands])
        scored = [(*c, p) for c, p in zip(cands, probs)]
        # Only places that are actually likely; if none is, keep just the best one.
        likely = [c for c in scored if c[5] >= MIN_PROBABILITY]
        views.append(view)
        results.append(likely or scored[:1])
    cache.unlink(missing_ok=True)

    draw_locations(reference, chosen, views, results, grid, args.out / "demo_locations.jpg")
    draw_closeups(image, reference, chosen, results, args.out / "demo_closeups.jpg")

    print("\nРЕЗУЛЬТАТ")
    print(f"Сітка картини: {grid[0]} стовпців x {grid[1]} рядків (~4000 клітинок)")
    for number, (piece, cands) in enumerate(zip(chosen, results), 1):
        cx, cy = piece.center
        print(f"\nШматок {number} (на фото {args.photo} в точці x={cx:.0f}, y={cy:.0f}):")
        for rank, (score, angle, scale, x, y, prob) in enumerate(cands):
            row, col = pm.grid_cell(x, y, W, H, *grid)
            print(f"  варіант {number}{'abcd'[rank]}: ймовірність {prob * 100:4.0f}%  "
                  f"клітинка рядок {row}, стовпець {col}  (x={x / W * 100:.0f}% ширини, "
                  f"y={y / H * 100:.0f}% висоти)  збіг {score:.2f}")
        rest = max(0.0, 1 - sum(c[5] for c in cands))
        if cands[0][5] < MIN_PROBABILITY:
            print("  -> метод не впевнений: жодне місце не виділяється серед інших")
        print(f"  десь в іншому місці: {rest * 100:.0f}%")
    print(f"\nФайли: {args.out / 'demo_pieces_on_white.jpg'}, demo_locations.jpg, demo_closeups.jpg")


if __name__ == "__main__":
    main()
