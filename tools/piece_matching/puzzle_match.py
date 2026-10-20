"""Puzzle piece recognition test bench.

Finds the reference photo (full puzzle image) among the photos in a folder,
segments loose pieces on the other photos, locates each piece on the reference
with two independent methods and visualises the result.

Method A: SIFT keypoints + FLANN + RANSAC similarity transform (baseline).
Method B: coarse-to-fine colour template matching over rotation and scale,
          verified with the full piece mask (main method).

User-facing output is in Ukrainian; code is in English.
"""

from __future__ import annotations

import argparse
import csv
import math
import multiprocessing as mp
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff"}

# Working resolutions (fractions of the original image size).
SEGMENT_SCALE = 0.25          # piece photos are segmented at this scale
REF_LONG_SIDE = 7700          # rectified reference long side, px
COARSE_REF_SCALE = 0.4        # reference scale used for the coarse search
COARSE_ANGLE_STEP = 10        # degrees
COARSE_PEAKS_PER_ANGLE = 3

# Decision thresholds for method B (tuned on the control test, see README).
FOUND_SCORE = 0.62
FOUND_MARGIN = 0.06
# Method A decision threshold.
SIFT_MIN_INLIERS = 8


# --------------------------------------------------------------------------- #
# Data containers
# --------------------------------------------------------------------------- #

@dataclass
class Piece:
    piece_id: int
    photo: str
    contour: np.ndarray            # full-resolution contour in the photo
    center: tuple[float, float]    # centre of the inscribed circle, photo px
    radius: float                  # inscribed circle radius, photo px
    area: float
    isolation: float               # share of the outline touching background


@dataclass
class Match:
    found: bool
    x: float = math.nan            # piece centre on the reference, ref px
    y: float = math.nan
    angle: float = math.nan        # rotation of the piece, degrees
    scale: float = math.nan        # reference px per photo px
    score: float = 0.0             # method-specific raw score
    confidence: float = 0.0        # 0..1
    extra: dict = field(default_factory=dict)


# --------------------------------------------------------------------------- #
# Image helpers
# --------------------------------------------------------------------------- #

def load_image(path: Path) -> np.ndarray:
    # cv2.imread applies the EXIF orientation by default.
    image = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if image is None:
        raise RuntimeError(f"Не вдалося прочитати файл {path}")
    return image


def resize(image: np.ndarray, factor: float, nearest: bool = False) -> np.ndarray:
    if nearest:
        interp = cv2.INTER_NEAREST
    else:
        interp = cv2.INTER_AREA if factor < 1 else cv2.INTER_LINEAR
    return cv2.resize(image, None, fx=factor, fy=factor, interpolation=interp)


def kmeans_colors(samples: np.ndarray, k: int) -> tuple[np.ndarray, np.ndarray]:
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 50, 0.5)
    _, labels, centers = cv2.kmeans(samples.astype(np.float32), k, None, criteria, 3,
                                    cv2.KMEANS_PP_CENTERS)
    shares = np.bincount(labels.ravel(), minlength=k) / len(labels)
    return centers, shares


def min_color_distance(lab: np.ndarray, centers: np.ndarray,
                       weights=(1.0, 1.0, 1.0)) -> np.ndarray:
    w = np.float32(weights)
    return np.min([np.linalg.norm((lab - c) * w, axis=2) for c in centers], axis=0)


# --------------------------------------------------------------------------- #
# Step 1: find the reference photo and rectify it
# --------------------------------------------------------------------------- #

def detect_poster(image: np.ndarray) -> tuple[float, np.ndarray | None]:
    """Return (score, corners) of the largest rectangular picture in the photo.

    The border of the photo is assumed to be background (floor/table); the
    picture is the big region whose colours differ from the border colours.
    """
    factor = 1000 / max(image.shape[:2])
    small = resize(image, factor)
    lab = cv2.cvtColor(cv2.GaussianBlur(small, (5, 5), 0), cv2.COLOR_BGR2Lab).astype(np.float32)
    b = 15
    border = np.concatenate([lab[:b].reshape(-1, 3), lab[-b:].reshape(-1, 3),
                             lab[:, :b].reshape(-1, 3), lab[:, -b:].reshape(-1, 3)])
    centers, _ = kmeans_colors(border, 4)
    border_dist = np.min(np.linalg.norm(border[:, None, :] - centers[None], axis=2), axis=1)
    threshold = max(np.percentile(border_dist, 90) * 1.5, 12)
    mask = (min_color_distance(lab, centers) > threshold).astype(np.uint8) * 255
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((9, 9), np.uint8))
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not contours:
        return 0.0, None
    contour = max(contours, key=cv2.contourArea)
    hull = cv2.convexHull(contour)
    quad = cv2.approxPolyDP(hull, 0.02 * cv2.arcLength(hull, True), True)
    area_share = cv2.contourArea(hull) / mask.size
    if len(quad) != 4:
        return area_share * 0.3, None
    box_area = cv2.contourArea(cv2.boxPoints(cv2.minAreaRect(hull)).astype(np.float32))
    rectangularity = cv2.contourArea(hull) / max(box_area, 1)
    corners = refine_quad(contour.reshape(-1, 2).astype(np.float32),
                          quad.reshape(4, 2).astype(np.float32))
    return area_share * rectangularity, corners / factor


def refine_quad(points: np.ndarray, quad: np.ndarray) -> np.ndarray:
    """Fit a robust line to each side of the rough quad and intersect them."""
    lines = []
    for i in range(4):
        a, b = quad[i], quad[(i + 1) % 4]
        d = b - a
        normal = np.array([-d[1], d[0]]) / np.linalg.norm(d)
        dist = np.abs((points - a) @ normal)
        t = ((points - a) @ d) / (d @ d)
        side = points[(dist < 20) & (t > 0.1) & (t < 0.9)]
        if len(side) < 10:
            return quad
        lines.append(cv2.fitLine(side, cv2.DIST_HUBER, 0, 0.01, 0.01).ravel())
    corners = []
    for i in range(4):
        (vx1, vy1, x1, y1), (vx2, vy2, x2, y2) = lines[i - 1], lines[i]
        s = np.linalg.solve(np.array([[vx1, -vx2], [vy1, -vy2]]), np.array([x2 - x1, y2 - y1]))
        corners.append([x1 + s[0] * vx1, y1 + s[0] * vy1])
    return np.float32(corners)


def order_corners(corners: np.ndarray) -> np.ndarray:
    """Order as top-left, top-right, bottom-right, bottom-left (photo coords)."""
    s = corners.sum(1)
    d = corners[:, 0] - corners[:, 1]
    return np.float32([corners[np.argmin(s)], corners[np.argmax(d)],
                       corners[np.argmax(s)], corners[np.argmin(d)]])


def rectify_reference(image: np.ndarray, corners: np.ndarray, rotate: str) -> np.ndarray:
    tl, tr, br, bl = order_corners(corners)
    width = (np.linalg.norm(tr - tl) + np.linalg.norm(br - bl)) / 2
    height = (np.linalg.norm(bl - tl) + np.linalg.norm(br - tr)) / 2
    k = REF_LONG_SIDE / max(width, height)
    w, h = int(round(width * k)), int(round(height * k))
    dst = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    matrix = cv2.getPerspectiveTransform(np.float32([tl, tr, br, bl]), dst)
    rectified = cv2.warpPerspective(image, matrix, (w, h), flags=cv2.INTER_AREA)
    if rotate == "auto":
        rotate = "ccw" if h > w else "none"
    if rotate == "ccw":
        rectified = cv2.rotate(rectified, cv2.ROTATE_90_COUNTERCLOCKWISE)
    elif rotate == "cw":
        rectified = cv2.rotate(rectified, cv2.ROTATE_90_CLOCKWISE)
    elif rotate == "180":
        rectified = cv2.rotate(rectified, cv2.ROTATE_180)
    return rectified


# --------------------------------------------------------------------------- #
# Step 2: segment pieces
# --------------------------------------------------------------------------- #

def foreground_mask(small: np.ndarray) -> np.ndarray:
    """Pieces = everything that is not one of the bright, smooth background colours."""
    lab = cv2.cvtColor(cv2.GaussianBlur(small, (3, 3), 0), cv2.COLOR_BGR2Lab).astype(np.float32)
    lightness = lab[..., 0]
    mean = cv2.blur(lightness, (7, 7))
    std = np.sqrt(np.maximum(cv2.blur(lightness * lightness, (7, 7)) - mean * mean, 0))
    samples = lab[(std < 4) & (lightness > 120)][::10]
    centers, shares = kmeans_colors(samples, 3)
    centers = centers[shares > 0.05]
    # Lightness gets a low weight: shadows and cardboard corrugation vary mostly in L.
    dist = min_color_distance(lab, centers, (0.3, 1.0, 1.0))
    mask = (dist > 12).astype(np.uint8) * 255
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    # Fill small holes (specular highlights, white details on pieces).
    n, labels, stats, _ = cv2.connectedComponentsWithStats(255 - mask, connectivity=4)
    small_holes = np.where(stats[:, cv2.CC_STAT_AREA] < 400)[0]
    small_holes = small_holes[small_holes > 0]
    mask[np.isin(labels, small_holes)] = 255
    return mask


def segment_pieces(image: np.ndarray, photo: str, first_id: int,
                   max_pieces: int) -> tuple[list[Piece], np.ndarray, np.ndarray]:
    """Split touching pieces with a distance-transform watershed.

    Returns pieces, the foreground mask and the watershed labels (both at
    SEGMENT_SCALE).
    """
    small = resize(image, SEGMENT_SCALE)
    mask = foreground_mask(small)
    dist = cv2.distanceTransform(mask, cv2.DIST_L2, 5)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (25, 25))
    peaks = ((dist == cv2.dilate(dist, kernel)) & (dist > 12)).astype(np.uint8)
    n, markers = cv2.connectedComponents(peaks)
    markers = np.where(markers > 0, markers + 1, 0)
    markers[mask == 0] = 1
    labels = cv2.watershed(cv2.cvtColor(mask, cv2.COLOR_GRAY2BGR), markers.astype(np.int32))

    candidates = []
    h_img, w_img = mask.shape
    for label in range(2, n + 1):
        region = (labels == label).astype(np.uint8)
        area = int(region.sum())
        if area < 1500:
            continue
        x, y, w, h = cv2.boundingRect(region)
        if x < 3 or y < 3 or x + w > w_img - 3 or y + h > h_img - 3:
            continue
        contours, _ = cv2.findContours(region, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        contour = max(contours, key=cv2.contourArea)
        solidity = cv2.contourArea(contour) / max(cv2.contourArea(cv2.convexHull(contour)), 1)
        if solidity < 0.65 or max(w, h) / min(w, h) > 1.8:
            continue
        ring = cv2.dilate(region, np.ones((9, 9), np.uint8)) - cv2.dilate(region, np.ones((3, 3), np.uint8))
        isolation = float((mask[ring > 0] == 0).mean())
        region_dist = cv2.distanceTransform(region, cv2.DIST_L2, 5)
        _, radius, _, (cx, cy) = cv2.minMaxLoc(region_dist)
        candidates.append((area, contour, (cx, cy), radius, isolation))

    if not candidates:
        return [], mask, labels
    # Keep pieces of a typical single-piece size (clusters and fragments are rejected).
    typical_area = np.median([c[0] for c in candidates if c[4] > 0.5] or [c[0] for c in candidates])
    pieces = []
    for area, contour, (cx, cy), radius, isolation in candidates:
        if not (0.6 * typical_area < area < 1.6 * typical_area):
            continue
        k = 1 / SEGMENT_SCALE
        pieces.append(Piece(0, photo, (contour * k).astype(np.float32), (cx * k, cy * k),
                            radius * k, area * k * k, isolation))
    # Most isolated pieces first: their outline (and so the crop) is the most reliable.
    pieces.sort(key=lambda p: -p.isolation)
    pieces = pieces[:max_pieces]
    for i, piece in enumerate(pieces):
        piece.piece_id = first_id + i
    return pieces, mask, labels


def find_assembled_region(mask: np.ndarray, typical_area: float) -> np.ndarray | None:
    """Largest foreground blob that is much bigger than one piece (already assembled part)."""
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask)
    if n < 2:
        return None
    best = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    if stats[best, cv2.CC_STAT_AREA] < 40 * typical_area:
        return None
    region = (labels == best).astype(np.uint8) * 255
    # Erode so that sampled patches are well inside the assembled area.
    return cv2.erode(region, np.ones((41, 41), np.uint8))


# --------------------------------------------------------------------------- #
# Step 3a: method A — SIFT + RANSAC
# --------------------------------------------------------------------------- #

class SiftMatcher:
    def __init__(self, reference: np.ndarray):
        self.sift = cv2.SIFT_create(contrastThreshold=0.02)
        gray = cv2.cvtColor(reference, cv2.COLOR_BGR2GRAY)
        keypoints, descriptors = self.sift.detectAndCompute(gray, None)
        self.points = np.float32([kp.pt for kp in keypoints])
        self.matcher = cv2.FlannBasedMatcher(dict(algorithm=1, trees=5), dict(checks=64))
        self.matcher.add([descriptors])
        self.matcher.train()
        self.keypoint_count = len(keypoints)

    def match(self, image: np.ndarray, piece: Piece) -> Match:
        crop, mask, origin = crop_piece(image, piece, margin=20)
        mask = cv2.erode(mask, np.ones((15, 15), np.uint8))
        gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
        keypoints, descriptors = self.sift.detectAndCompute(gray, mask)
        if descriptors is None or len(keypoints) < 3:
            return Match(False, extra={"keypoints": 0, "good": 0})
        pairs = self.matcher.knnMatch(descriptors, k=2)
        good = [p[0] for p in pairs if len(p) == 2 and p[0].distance < 0.8 * p[1].distance]
        info = {"keypoints": len(keypoints), "good": len(good)}
        if len(good) < 3:
            return Match(False, extra=info)
        src = np.float32([keypoints[g.queryIdx].pt for g in good]) + origin
        dst = self.points[[g.trainIdx for g in good]]
        transform, inliers = cv2.estimateAffinePartial2D(src, dst, method=cv2.RANSAC,
                                                         ransacReprojThreshold=8)
        if transform is None:
            return Match(False, extra=info)
        count = int(inliers.sum())
        x, y = transform @ np.array([piece.center[0], piece.center[1], 1.0])
        scale = float(np.hypot(transform[0, 0], transform[1, 0]))
        angle = float(np.degrees(np.arctan2(transform[1, 0], transform[0, 0])))
        found = count >= SIFT_MIN_INLIERS
        confidence = min(1.0, count / 20)
        info["inliers"] = count
        return Match(found, x, y, angle, scale, count, confidence, info)


# --------------------------------------------------------------------------- #
# Step 3b: method B — coarse-to-fine template matching
# --------------------------------------------------------------------------- #

def crop_piece(image: np.ndarray, piece: Piece, margin: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    x, y, w, h = cv2.boundingRect(piece.contour.astype(np.int32))
    x0, y0 = max(x - margin, 0), max(y - margin, 0)
    x1, y1 = min(x + w + margin, image.shape[1]), min(y + h + margin, image.shape[0])
    crop = image[y0:y1, x0:x1].copy()
    mask = np.zeros(crop.shape[:2], np.uint8)
    cv2.drawContours(mask, [(piece.contour - [x0, y0]).astype(np.int32)], -1, 255, -1)
    return crop, mask, np.float32([x0, y0])


@dataclass
class PieceView:
    """Small crop around one piece: everything a worker process needs to match it."""
    piece_id: int
    crop: np.ndarray
    mask: np.ndarray
    center: tuple[float, float]    # inscribed-circle centre, crop coords
    radius: float                  # photo px


def make_view(image: np.ndarray, piece: Piece, color_params=None) -> PieceView:
    crop, mask, origin = crop_piece(image, piece, margin=12)
    if color_params is not None:
        crop = apply_color_transfer(crop, color_params)
    # Drop the outermost pixels: they mix piece colours with background/shadow.
    mask = cv2.erode(mask, np.ones((9, 9), np.uint8))
    center = (piece.center[0] - origin[0], piece.center[1] - origin[1])
    return PieceView(piece.piece_id, crop, mask, center, piece.radius)


def make_square_view(image: np.ndarray, cx: float, cy: float, half: float, view_id: int,
                     color_params=None) -> PieceView:
    x0, y0 = int(cx - half) - 12, int(cy - half) - 12
    size = int(2 * half) + 24
    crop = image[y0:y0 + size, x0:x0 + size].copy()
    if color_params is not None:
        crop = apply_color_transfer(crop, color_params)
    mask = np.zeros(crop.shape[:2], np.uint8)
    mask[12:-12, 12:-12] = 255
    return PieceView(view_id, crop, mask, (cx - x0, cy - y0), half / 1.4)


def piece_to_ref_matrix(center: tuple[float, float], angle: float, scale: float,
                        target: tuple[float, float]) -> np.ndarray:
    """Similarity transform: photo coords -> reference coords."""
    matrix = cv2.getRotationMatrix2D((float(center[0]), float(center[1])), angle, scale)
    matrix[:, 2] += np.float32(target) - np.float32(center)
    return matrix


def warp_view(view: PieceView, angle: float, scale: float):
    """Rotate/scale the piece into reference geometry.

    Returns (template, mask, (cx, cy)) cropped to the piece; (cx, cy) is where the
    piece centre lands inside the template.
    """
    size = int(math.ceil(max(view.crop.shape[:2]) * scale * 1.5)) + 2
    half = size / 2
    matrix = piece_to_ref_matrix(view.center, angle, scale, (half, half))
    template = cv2.warpAffine(view.crop, matrix, (size, size), flags=cv2.INTER_AREA)
    mask = cv2.warpAffine(view.mask, matrix, (size, size), flags=cv2.INTER_NEAREST)
    ys, xs = np.where(mask > 0)
    if len(xs) < 12:
        return None
    x0, y0, x1, y1 = xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
    return template[y0:y1, x0:x1].copy(), mask[y0:y1, x0:x1].copy(), (half - x0, half - y0)


def suppress_peaks(result: np.ndarray, count: int, radius: int) -> list[tuple[float, int, int]]:
    result = result.copy()
    peaks = []
    for _ in range(count):
        _, value, _, (x, y) = cv2.minMaxLoc(result)
        if not np.isfinite(value) or value <= -1:
            break
        peaks.append((float(value), x, y))
        cv2.rectangle(result, (x - radius, y - radius), (x + radius, y + radius), -2, -1)
    return peaks


def color_transfer_params(image: np.ndarray, mask: np.ndarray, reference: np.ndarray):
    """Lab mean/std of the pieces and of the picture (Reinhard colour transfer).

    Piece photos and the reference photo are taken under different light; this
    maps piece colours into the reference's colour statistics.
    """
    small_ref = resize(reference, 0.1)
    ref_lab = cv2.cvtColor(small_ref, cv2.COLOR_BGR2Lab).reshape(-1, 3).astype(np.float32)
    small = resize(image, SEGMENT_SCALE)
    lab = cv2.cvtColor(small, cv2.COLOR_BGR2Lab)[mask > 0].astype(np.float32)
    return lab.mean(0), lab.std(0) + 1e-3, ref_lab.mean(0), ref_lab.std(0)


def apply_color_transfer(crop: np.ndarray, params) -> np.ndarray:
    src_mean, src_std, dst_mean, dst_std = params
    lab = cv2.cvtColor(crop, cv2.COLOR_BGR2Lab).astype(np.float32)
    lab = (lab - src_mean) / src_std * dst_std + dst_mean
    return cv2.cvtColor(np.clip(lab, 0, 255).astype(np.uint8), cv2.COLOR_Lab2BGR)


# Penalty per unit of Lab colour difference (lightness counts half): NCC alone is
# blind to the overall hue because it subtracts each channel's mean.
COLOR_WEIGHT = 0.012


def color_distance(mean_a: np.ndarray, mean_b: np.ndarray) -> np.ndarray:
    d = mean_a - mean_b
    return np.sqrt((0.5 * d[..., 0]) ** 2 + d[..., 1] ** 2 + d[..., 2] ** 2)


# Reference images shared by the worker processes (set in init_worker).
_REF: np.ndarray | None = None
_REF_COARSE: np.ndarray | None = None
_REF_COARSE_LAB: np.ndarray | None = None


def init_worker(reference_path: str) -> None:
    global _REF, _REF_COARSE, _REF_COARSE_LAB
    cv2.setNumThreads(1)
    _REF = np.load(reference_path, mmap_mode="r")
    _REF_COARSE = resize(np.asarray(_REF), COARSE_REF_SCALE)
    _REF_COARSE_LAB = cv2.cvtColor(_REF_COARSE, cv2.COLOR_BGR2Lab).astype(np.float32)


def template_lab_mean(template: np.ndarray, mask: np.ndarray) -> np.ndarray:
    lab = cv2.cvtColor(template, cv2.COLOR_BGR2Lab).astype(np.float32)
    return np.float32(cv2.mean(lab, mask)[:3])


def coarse_candidates(view: PieceView, scale: float, angle_step: int = COARSE_ANGLE_STEP,
                      angles=None) -> list[tuple[float, float, float, float]]:
    """Fast unmasked search on the downscaled reference.

    Pixels outside the piece are filled with the piece's mean colour, so they do
    not contribute to the correlation numerator and the fast FFT path is used.
    Returns (score, angle, x, y) with x, y = piece centre in full reference px.
    """
    out = []
    s = scale * COARSE_REF_SCALE
    for angle in (range(0, 360, angle_step) if angles is None else angles):
        warped = warp_view(view, angle, s)
        if warped is None:
            continue
        template, mask, (cx, cy) = warped
        piece_lab = template_lab_mean(template, mask)
        mean = cv2.mean(template, mask)[:3]
        template[mask == 0] = mean
        result = cv2.matchTemplate(_REF_COARSE, template, cv2.TM_CCOEFF_NORMED)
        result = np.nan_to_num(result, nan=-1, posinf=-1, neginf=-1)
        th, tw = template.shape[:2]
        local = cv2.blur(_REF_COARSE_LAB, (tw, th), anchor=(0, 0))[:result.shape[0], :result.shape[1]]
        result = result - COLOR_WEIGHT * color_distance(local, piece_lab)
        for value, x, y in suppress_peaks(result, COARSE_PEAKS_PER_ANGLE, max(template.shape[:2])):
            out.append((value, float(angle), (x + cx) / COARSE_REF_SCALE, (y + cy) / COARSE_REF_SCALE))
    out.sort(key=lambda c: -c[0])
    return out


def masked_score(view: PieceView, angle: float, scale: float, x: float, y: float,
                 window: int) -> tuple[float, float, float]:
    """Full-mask NCC in a small window around (x, y) on the full-resolution reference."""
    warped = warp_view(view, angle, scale)
    if warped is None:
        return -1.0, x, y
    template, mask, (cx, cy) = warped
    H, W = _REF.shape[:2]
    left = int(round(x - cx)) - window
    top = int(round(y - cy)) - window
    right = left + template.shape[1] + 2 * window
    bottom = top + template.shape[0] + 2 * window
    if left < 0 or top < 0 or right > W or bottom > H:
        return -1.0, x, y
    area = np.ascontiguousarray(_REF[top:bottom, left:right])
    result = cv2.matchTemplate(area, template, cv2.TM_CCOEFF_NORMED, mask=mask)
    result = np.nan_to_num(result, nan=-1, posinf=-1, neginf=-1)
    _, value, _, (dx, dy) = cv2.minMaxLoc(result)
    window_lab = template_lab_mean(area[dy:dy + template.shape[0], dx:dx + template.shape[1]], mask)
    value -= COLOR_WEIGHT * float(color_distance(window_lab, template_lab_mean(template, mask)))
    return float(value), left + dx + cx, top + dy + cy


def refine(view: PieceView, candidate, scale: float, half_step: float = COARSE_ANGLE_STEP / 2):
    _, angle0, x, y = candidate
    best = (-1.0, angle0, scale, x, y)
    # The coarse step leaves up to ±half_step degrees and a few px of error.
    window = int(3 / COARSE_REF_SCALE) + 2
    for angle in np.arange(angle0 - half_step, angle0 + half_step + 0.1, 2.5):
        for s in (scale * 0.94, scale, scale * 1.06):
            value, nx, ny = masked_score(view, angle, s, x, y, window)
            if value > best[0]:
                best = (value, angle, s, nx, ny)
    value, angle, s, x, y = best
    for da, ds in ((-1.2, 1), (1.2, 1), (0, 0.97), (0, 1.03)):
        v, nx, ny = masked_score(view, angle + da, s * ds, x, y, 3)
        if v > best[0]:
            best = (v, angle + da, s * ds, nx, ny)
    return best


def match_view(view: PieceView, scale: float, top_k: int = 8) -> Match:
    candidates = coarse_candidates(view, scale)
    if not candidates:
        return Match(False)
    refined = sorted((refine(view, c, scale) for c in candidates[:top_k]), key=lambda r: -r[0])
    score, angle, s, x, y = refined[0]
    # Distinctiveness: margin to the best candidate at a *different* place.
    piece_size = view.radius * 2.5 * scale
    others = [r[0] for r in refined[1:] if math.hypot(r[3] - x, r[4] - y) > piece_size]
    runner_up = others[0] if others else -1.0
    margin = score - runner_up
    found = score >= FOUND_SCORE and margin >= FOUND_MARGIN
    confidence = float(np.clip((score - 0.45) / 0.4, 0, 1) * np.clip(margin / 0.15, 0, 1))
    return Match(found, x, y, angle % 360, s, score, confidence,
                 {"margin": margin, "runner_up": runner_up})


def task_match(args) -> tuple[int, Match]:
    view, scale = args
    return view.piece_id, match_view(view, scale)


def task_coarse_top(args) -> tuple[float, float]:
    view, scale = args
    cands = coarse_candidates(view, scale, angle_step=20)
    return scale, (cands[0][0] if cands else -1.0)


def calibrate_scale(pool, views: list[PieceView], log) -> float:
    """Pick the photo->reference scale that gives the strongest coarse matches.

    Camera distance differs between photos, so this runs per photo: a geometric
    sweep over scales (covers ~4x zoom), the median best score over sample pieces.
    """
    sample = views[:8]
    grid = np.geomspace(0.12, 0.7, 16)
    tasks = [(v, float(s)) for s in grid for v in sample]
    by_scale: dict[float, list[float]] = {}
    for scale, value in pool.imap_unordered(task_coarse_top, tasks):
        by_scale.setdefault(scale, []).append(value)
    medians = {s: float(np.median(v)) for s, v in by_scale.items()}
    best = max(medians, key=medians.get)
    log(f"    калібрування масштабу: {best:.3f} px еталона на 1 px фото "
        f"(медіанний збіг {medians[best]:.2f})")
    return best


# --------------------------------------------------------------------------- #
# Control test: patches cut from the already assembled part
# --------------------------------------------------------------------------- #

def control_views(image: np.ndarray, region: np.ndarray, radius: float,
                  count: int = 24) -> tuple[list[PieceView], list[tuple[float, float]]]:
    """Piece-sized square patches spread over the assembled area."""
    ys, xs = np.where(region > 0)
    if len(xs) < count:
        return [], []
    rng = np.random.default_rng(0)
    order = rng.permutation(len(xs))
    chosen: list[tuple[float, float]] = []
    min_gap = radius * 2.5 * SEGMENT_SCALE
    edge = (radius * 1.4 + 14) * SEGMENT_SCALE
    for i in order:
        p = (float(xs[i]), float(ys[i]))
        if not (edge < p[0] < region.shape[1] - edge and edge < p[1] < region.shape[0] - edge):
            continue
        if all(math.hypot(p[0] - q[0], p[1] - q[1]) > min_gap for q in chosen):
            chosen.append(p)
            if len(chosen) == count:
                break
    half = radius * 1.4
    h, w = image.shape[:2]
    border = half + 14
    centers = [(x / SEGMENT_SCALE, y / SEGMENT_SCALE) for x, y in chosen]
    centers = [(x, y) for x, y in centers if border < x < w - border and border < y < h - border]
    views = [make_square_view(image, cx, cy, half, -(i + 1)) for i, (cx, cy) in enumerate(centers)]
    return views, centers


def evaluate_control(centers, matches: list[Match], tolerance: float):
    """Patches from an assembled area keep their mutual geometry on the reference.

    A RANSAC similarity fit over all patch positions gives pseudo ground truth:
    patches consistent with the fit are correct, the rest are wrong. This is the
    only quantitative accuracy check possible without manual labels.
    """
    src = np.float32(centers)
    dst = np.float32([[m.x, m.y] for m in matches])
    valid = np.isfinite(dst).all(1)
    if valid.sum() < 4:
        return None
    transform, inliers = cv2.estimateAffinePartial2D(src[valid], dst[valid], method=cv2.RANSAC,
                                                     ransacReprojThreshold=tolerance)
    if transform is None:
        return None
    correct = np.zeros(len(centers), bool)
    correct[np.where(valid)[0]] = inliers.ravel().astype(bool)
    return {"centers": centers, "matches": matches, "correct": correct, "transform": transform}


# --------------------------------------------------------------------------- #
# Step 4: visualisation
# --------------------------------------------------------------------------- #

def confidence_color(conf: float) -> tuple[int, int, int]:
    # red (low) -> yellow -> green (high), BGR
    conf = float(np.clip(conf, 0, 1))
    if conf < 0.5:
        return (0, int(255 * conf * 2), 255)
    return (0, 255, int(255 * (1 - (conf - 0.5) * 2)))


def put_label(img, text, org, color, scale=1.0, thickness=2):
    x, y = int(org[0]), int(org[1])
    (tw, th), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, scale, thickness)
    cv2.rectangle(img, (x - 3, y - th - 5), (x + tw + 3, y + 5), (0, 0, 0), -1)
    cv2.putText(img, text, (x, y), cv2.FONT_HERSHEY_SIMPLEX, scale, color, thickness, cv2.LINE_AA)


def contour_on_reference(piece: Piece, match: Match) -> np.ndarray:
    matrix = piece_to_ref_matrix(piece.center, match.angle, match.scale, (match.x, match.y))
    pts = cv2.transform(piece.contour.reshape(-1, 1, 2), matrix)
    return pts.astype(np.int32)


def draw_reference_result(reference, pieces, matches, out_path, grid, show_unconfident=True):
    canvas = (reference * 0.75).astype(np.uint8)
    cols, rows = grid
    H, W = canvas.shape[:2]
    for c in range(1, cols):
        x = int(c * W / cols)
        cv2.line(canvas, (x, 0), (x, H), (255, 255, 255) if c % 10 == 0 else (110, 110, 110), 3 if c % 10 == 0 else 1)
    for r in range(1, rows):
        y = int(r * H / rows)
        cv2.line(canvas, (0, y), (W, y), (255, 255, 255) if r % 10 == 0 else (110, 110, 110), 3 if r % 10 == 0 else 1)
    for piece in pieces:
        m = matches[piece.piece_id]
        if not np.isfinite(m.x):
            continue
        if not m.found and not show_unconfident:
            continue
        pts = contour_on_reference(piece, m)
        if m.found:
            color = confidence_color(m.confidence)
            cv2.polylines(canvas, [pts], True, color, 6, cv2.LINE_AA)
            put_label(canvas, str(piece.piece_id), pts.reshape(-1, 2).min(0) + [0, -8], color, 1.6, 3)
    factor = 3000 / canvas.shape[1]
    small = resize(canvas, factor)
    cv2.imwrite(str(out_path), small, [cv2.IMWRITE_JPEG_QUALITY, 92])
    return small


def draw_photo_pieces(image, pieces, matches, mask, out_path):
    factor = 0.35
    canvas = resize(image, factor)
    dim = resize(mask, factor / SEGMENT_SCALE, nearest=True) == 0
    canvas[dim] = (canvas[dim] * 0.45).astype(np.uint8)
    for piece in pieces:
        m = matches[piece.piece_id]
        color = confidence_color(m.confidence) if m.found else (80, 80, 80)
        pts = (piece.contour * factor).astype(np.int32)
        cv2.polylines(canvas, [pts], True, color, 3 if m.found else 2, cv2.LINE_AA)
        put_label(canvas, str(piece.piece_id), (piece.center[0] * factor - 12, piece.center[1] * factor + 8),
                  color if m.found else (200, 200, 200), 0.7, 2)
    cv2.imwrite(str(out_path), canvas, [cv2.IMWRITE_JPEG_QUALITY, 90])


def draw_gallery(images, reference, pieces, matches, out_path, tile=150):
    """Each row: piece (aligned to the found pose) | reference patch at that place."""
    rows = []
    for piece in pieces:
        m = matches[piece.piece_id]
        if not np.isfinite(m.x):
            continue
        image = images[piece.photo]
        size = int(piece.radius * 3.4 * m.scale)
        half = size / 2
        matrix = piece_to_ref_matrix(piece.center, m.angle, m.scale, (half, half))
        aligned = cv2.warpAffine(image, matrix, (size, size), flags=cv2.INTER_AREA)
        amask = np.zeros(image.shape[:2], np.uint8)
        x, y, w, h = cv2.boundingRect(piece.contour.astype(np.int32))
        cv2.drawContours(amask, [piece.contour.astype(np.int32)], -1, 255, -1)
        amask = cv2.warpAffine(amask, matrix, (size, size), flags=cv2.INTER_NEAREST)
        aligned[amask == 0] = (40, 40, 40)
        x0, y0 = int(m.x - half), int(m.y - half)
        ref_patch = cv2.copyMakeBorder(reference, size, size, size, size, cv2.BORDER_CONSTANT)[
            y0 + size:y0 + 2 * size, x0 + size:x0 + 2 * size].copy()
        outline = cv2.findContours(amask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)[0]
        color = confidence_color(m.confidence) if m.found else (128, 128, 128)
        cv2.drawContours(ref_patch, outline, -1, color, 1, cv2.LINE_AA)
        a = cv2.resize(aligned, (tile, tile))
        b = cv2.resize(ref_patch, (tile, tile))
        cell = np.full((tile + 28, tile * 2 + 6, 3), 255, np.uint8)
        cell[28:, :tile] = a
        cell[28:, tile + 6:] = b
        status = "OK" if m.found else "?"
        cv2.putText(cell, f"#{piece.piece_id} {status} {m.score:.2f}", (4, 20),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 0), 1, cv2.LINE_AA)
        rows.append(cell)
    if not rows:
        return
    per_row = 6
    blank = np.full_like(rows[0], 255)
    while len(rows) % per_row:
        rows.append(blank)
    grid = np.vstack([np.hstack([cv2.copyMakeBorder(c, 6, 6, 6, 6, cv2.BORDER_CONSTANT, value=(255, 255, 255))
                                 for c in rows[i:i + per_row]]) for i in range(0, len(rows), per_row)])
    cv2.imwrite(str(out_path), grid, [cv2.IMWRITE_JPEG_QUALITY, 92])


def draw_control(reference, ctrl, out_path):
    canvas = (reference * 0.75).astype(np.uint8)
    for (cx, cy), m, ok in zip(ctrl["centers"], ctrl["matches"], ctrl["correct"]):
        if not np.isfinite(m.x):
            continue
        color = (0, 220, 0) if ok else (0, 0, 255)
        cv2.circle(canvas, (int(m.x), int(m.y)), 40, color, 8)
        if not ok:
            true_xy = ctrl["transform"] @ np.array([cx, cy, 1.0])
            cv2.line(canvas, (int(m.x), int(m.y)), (int(true_xy[0]), int(true_xy[1])), color, 4)
    cv2.imwrite(str(out_path), resize(canvas, 2000 / canvas.shape[1]), [cv2.IMWRITE_JPEG_QUALITY, 90])


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def grid_shape(width: int, height: int, pieces: int) -> tuple[int, int]:
    """Columns x rows closest to `pieces` cells with the picture's aspect ratio."""
    cols = max(1, round(math.sqrt(pieces * width / height)))
    rows = max(1, round(pieces / cols))
    return cols, rows


def grid_cell(x: float, y: float, width: int, height: int, cols: int, rows: int) -> tuple[int, int] | None:
    if not (np.isfinite(x) and 0 <= x < width and 0 <= y < height):
        return None
    return int(y / height * rows) + 1, int(x / width * cols) + 1


def agree(a: Match, b: Match, tolerance: float) -> bool:
    return (np.isfinite(a.x) and np.isfinite(b.x)
            and math.hypot(a.x - b.x, a.y - b.y) <= tolerance)


def main() -> int:
    parser = argparse.ArgumentParser(description="Тест розпізнавання шматків пазла")
    root = Path(__file__).resolve().parents[2]
    parser.add_argument("--images", type=Path, default=root / "img", help="папка з фото")
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "output",
                        help="папка для результатів")
    parser.add_argument("--max-pieces", type=int, default=25,
                        help="скільки шматків перевіряти на кожному фото")
    parser.add_argument("--ref-rotate", choices=["auto", "none", "cw", "ccw", "180"], default="auto",
                        help="поворот еталона після вирівнювання")
    parser.add_argument("--grid-pieces", type=int, default=4000,
                        help="кількість шматків пазла (для сітки клітинок на еталоні)")
    parser.add_argument("--no-control", action="store_true", help="пропустити контрольний тест")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    started = time.time()

    def log(msg: str) -> None:
        print(msg, flush=True)

    paths = sorted(p for p in args.images.iterdir() if p.suffix.lower() in IMAGE_EXTENSIONS)
    if len(paths) < 2:
        log(f"У папці {args.images} потрібно щонайменше 2 фото, знайдено {len(paths)}.")
        return 1
    log(f"Знайдено фото: {len(paths)} у {args.images}")

    # ---- Step 1: reference ------------------------------------------------
    log("\n[1/4] Визначаю еталонне фото (повна картинка)...")
    images = {p.name: load_image(p) for p in paths}
    scores = {}
    for name, image in images.items():
        score, corners = detect_poster(image)
        scores[name] = (score, corners)
        log(f"    {name}: оцінка «це повна картинка» = {score:.2f}")
    ref_name = max(scores, key=lambda n: scores[n][0])
    ref_score, ref_corners = scores[ref_name]
    if ref_corners is None or ref_score < 0.3:
        log("Не вдалося впевнено знайти еталон: на жодному фото немає великої прямокутної картинки.")
        return 1
    log(f"    -> еталон: {ref_name}; решта фото містять фрагменти.")
    reference = rectify_reference(images[ref_name], ref_corners, args.ref_rotate)
    cv2.imwrite(str(args.out / "reference_rectified.jpg"), resize(reference, 0.4))
    piece_photos = [n for n in images if n != ref_name]
    H, W = reference.shape[:2]
    cols, rows = grid_shape(W, H, args.grid_pieces)
    log(f"    еталон вирівняно до прямокутника {W}x{H} px і поділено на сітку "
        f"{cols} x {rows} = {cols * rows} клітинок (~{W / cols:.0f} px на шматок)")

    # ---- Step 2: segmentation ---------------------------------------------
    log("\n[2/4] Виділяю окремі шматки на фото з фрагментами...")
    all_pieces: dict[str, list[Piece]] = {}
    masks = {}
    next_id = 1
    for name in piece_photos:
        pieces, mask, _ = segment_pieces(images[name], name, next_id, args.max_pieces)
        all_pieces[name] = pieces
        masks[name] = mask
        next_id += len(pieces)
        log(f"    {name}: відібрано {len(pieces)} шматків для перевірки "
            f"(найкраще відокремлених від сусідів)")

    # ---- Step 3: matching -------------------------------------------------
    log("\n[3/4] Шукаю кожен шматок на еталоні двома методами...")
    t0 = time.time()
    sift = SiftMatcher(reference)
    log(f"    метод A (SIFT): {sift.keypoint_count} ключових точок на еталоні ({time.time() - t0:.1f} с)")
    # Method B runs in worker processes (matchTemplate is single-threaded);
    # they share the reference through a memory-mapped file.
    reference_cache = args.out / "_reference_cache.npy"
    np.save(reference_cache, cv2.GaussianBlur(reference, (3, 3), 0))
    workers = max(1, min(8, (os.cpu_count() or 2) - 1))
    pool = mp.get_context("spawn").Pool(workers, initializer=init_worker,
                                        initargs=(str(reference_cache),))

    # Scale (reference px per photo px) is calibrated on piece-sized patches cut
    # from the already assembled part: they are large and fully textured, which
    # makes the sweep reliable. Small loose pieces bias it towards tiny templates.
    control_sets = {}
    for name in piece_photos:
        pieces = all_pieces[name]
        if not pieces:
            continue
        typical_area = np.median([p.area for p in pieces]) * SEGMENT_SCALE ** 2
        region = find_assembled_region(masks[name], typical_area)
        radius = float(np.median([p.radius for p in pieces]))
        if region is not None:
            views, centers = control_views(images[name], region, radius)
            if views:
                control_sets[name] = (views, centers, radius)

    matches_a: dict[int, Match] = {}
    matches_b: dict[int, Match] = {}
    scales: dict[str, float] = {}
    for name in piece_photos:
        pieces = all_pieces[name]
        if not pieces:
            continue
        log(f"  {name}:")
        views = [make_view(images[name], p) for p in pieces]
        if name in control_sets:
            scales[name] = calibrate_scale(pool, control_sets[name][0], log)
        elif scales:
            scales[name] = float(np.median(list(scales.values())))
            log(f"    зібраної ділянки немає, беру масштаб з інших фото: {scales[name]:.3f}")
        else:
            scales[name] = calibrate_scale(pool, views, log)
        for piece in pieces:
            matches_a[piece.piece_id] = sift.match(images[name], piece)
        for piece_id, match in pool.imap(task_match, [(v, scales[name]) for v in views]):
            matches_b[piece_id] = match
            log(f"    шматок #{piece_id:>3}: "
                f"{'знайдено' if match.found else 'не впевнено'} (збіг {match.score:.2f})")

    control = []
    if not args.no_control:
        log("\n    Контрольний тест: ділянки з уже зібраної частини пазла...")
        for name, (views, centers, radius) in control_sets.items():
            results = pool.map(task_match, [(v, scales[name]) for v in views])
            ctrl = evaluate_control(centers, [m for _, m in results], radius * scales[name] * 1.2)
            if ctrl:
                ctrl["photo"] = name
                control.append(ctrl)
                log(f"    {name}: правильне місце для {int(ctrl['correct'].sum())} з {len(views)} ділянок")
                draw_control(reference, ctrl, args.out / f"control_{Path(name).stem}.jpg")
    pool.close()
    pool.join()
    reference_cache.unlink(missing_ok=True)

    # ---- Step 4: output ---------------------------------------------------
    log("\n[4/4] Зберігаю візуалізацію...")
    pieces_flat = [p for name in piece_photos for p in all_pieces[name]]
    draw_reference_result(reference, pieces_flat, matches_b, args.out / "result_on_reference.jpg", (cols, rows))
    for name in piece_photos:
        draw_photo_pieces(images[name], all_pieces[name], matches_b, masks[name],
                          args.out / f"pieces_{Path(name).stem}.jpg")
    draw_gallery(images, reference, pieces_flat, matches_b, args.out / "pieces_vs_reference.jpg")

    with open(args.out / "results.csv", "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["piece_id", "photo", "photo_x", "photo_y", "grid_row", "grid_col",
                         "B_found", "B_ref_x", "B_ref_y", "B_angle", "B_score", "B_margin", "B_confidence",
                         "A_found", "A_ref_x", "A_ref_y", "A_inliers", "methods_agree"])
        for p in pieces_flat:
            a, b = matches_a[p.piece_id], matches_b[p.piece_id]
            tol = p.radius * 2 * b.scale if np.isfinite(b.scale) else 0
            cell = grid_cell(b.x, b.y, W, H, cols, rows) or ("", "")
            writer.writerow([p.piece_id, p.photo, round(p.center[0]), round(p.center[1]), cell[0], cell[1],
                             int(b.found), round(b.x, 1), round(b.y, 1), round(b.angle, 1),
                             round(b.score, 3), round(b.extra.get("margin", 0), 3), round(b.confidence, 2),
                             int(a.found), round(a.x, 1) if np.isfinite(a.x) else "",
                             round(a.y, 1) if np.isfinite(a.y) else "", a.extra.get("inliers", 0),
                             int(agree(a, b, tol))])

    # ---- Console summary --------------------------------------------------
    log("\n" + "=" * 96)
    log("ПІДСУМОК ПО КОЖНОМУ ШМАТКУ (основний метод B: template matching)")
    log(f"Координати — пікселі вирівняного еталона {W}x{H}; у дужках — % ширини/висоти.")
    log("=" * 96)
    log(f"{'#':>4}  {'фото':<13} {'результат':<12} {'клітинка р,с':<13} {'x, y на еталоні':<26} {'кут':>5}  "
        f"{'збіг':>5} {'відрив':>6} {'впевн.':>6}  {'SIFT':<10}")
    for p in pieces_flat:
        a, b = matches_a[p.piece_id], matches_b[p.piece_id]
        status = "ЗНАЙДЕНО" if b.found else "не знайдено"
        coords = (f"{b.x:6.0f}, {b.y:5.0f} ({b.x / W * 100:4.1f}%, {b.y / H * 100:4.1f}%)"
                  if np.isfinite(b.x) else "—")
        sift_txt = f"{a.extra.get('inliers', 0)} т." + (" ✓" if a.found else "")
        cell = grid_cell(b.x, b.y, W, H, cols, rows)
        cell_txt = f"{cell[0]:>2}, {cell[1]:>2}" if cell else "—"
        log(f"{p.piece_id:>4}  {p.photo:<13} {status:<12} {cell_txt:<13} {coords:<26} {b.angle:5.0f}  "
            f"{b.score:5.2f} {b.extra.get('margin', 0):6.2f} {b.confidence * 100:5.0f}%  {sift_txt:<10}")

    total = len(pieces_flat)
    found_b = sum(matches_b[p.piece_id].found for p in pieces_flat)
    found_a = sum(matches_a[p.piece_id].found for p in pieces_flat)
    both = sum(matches_a[p.piece_id].found and matches_b[p.piece_id].found for p in pieces_flat)
    agreed = sum(matches_a[p.piece_id].found and matches_b[p.piece_id].found and
                 agree(matches_a[p.piece_id], matches_b[p.piece_id], p.radius * 2 * matches_b[p.piece_id].scale)
                 for p in pieces_flat)
    log("\nПОРІВНЯННЯ МЕТОДІВ")
    log(f"  Метод A (SIFT + RANSAC):          впевнено знайдено {found_a} з {total}")
    log(f"  Метод B (template matching):      впевнено знайдено {found_b} з {total}")
    log(f"  Обидва методи знайшли:            {both}; з них вказали те саме місце: {agreed}")
    for ctrl in control:
        n = len(ctrl["correct"])
        ok = int(ctrl["correct"].sum())
        found_ok = sum(1 for m, c in zip(ctrl["matches"], ctrl["correct"]) if m.found and c)
        found_all = sum(1 for m in ctrl["matches"] if m.found)
        precision = f"{found_ok / found_all * 100:.0f}%" if found_all else "—"
        log(f"  Контроль ({ctrl['photo']}): правильне місце для {ok}/{n} ділянок ({ok / n * 100:.0f}%); "
            f"серед позначених «знайдено» правильних {found_ok}/{found_all} ({precision})")
    log(f"\nРезультати збережено в {args.out}:")
    log("  result_on_reference.jpg  — еталон із контурами знайдених шматків і номерами")
    log("  pieces_<фото>.jpg        — фото фрагментів із тими самими номерами")
    log("  pieces_vs_reference.jpg  — шматок поруч із місцем, яке знайдено на еталоні")
    log("  control_<фото>.jpg       — контрольний тест (зелене = правильно, червоне = помилка)")
    log("  results.csv              — таблиця з усіма числами")
    log(f"Час роботи: {time.time() - started:.0f} с")
    return 0


if __name__ == "__main__":
    sys.exit(main())
