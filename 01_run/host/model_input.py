"""Build the exact uint8 CHW tensor consumed by YOLOv5n's first convolution."""

import cv2
import numpy as np


def letterbox_bgr(image: np.ndarray, size: int = 320):
    """Return the padded image and exact geometry for inverse box mapping."""
    if image is None or image.ndim != 3 or image.shape[2] != 3 or min(image.shape[:2]) < 1:
        raise ValueError("expected a nonempty BGR image")
    if size < 32 or size % 32:
        raise ValueError("model size must be a positive multiple of 32")
    height, width = image.shape[:2]
    ratio = min(size / width, size / height)
    resized_w, resized_h = max(1, round(width * ratio)), max(1, round(height * ratio))
    left, top = (size - resized_w) // 2, (size - resized_h) // 2
    canvas = np.full((size, size, 3), 114, dtype=np.uint8)
    canvas[top:top + resized_h, left:left + resized_w] = cv2.resize(
        image, (resized_w, resized_h), interpolation=cv2.INTER_LINEAR)
    return canvas, dict(size=size, left=left, top=top,
                        scale_x=resized_w / width, scale_y=resized_h / height)


def quantized_focus_bgr(image: np.ndarray, scale: float, size: int = 640,
                        letterbox: bool = False) -> np.ndarray:
    if image is None or image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("expected a BGR image with three channels")
    if scale <= 0:
        raise ValueError("quantization scale must be positive")
    if size < 32 or size % 32:
        raise ValueError("model size must be a positive multiple of 32")
    # The supplied model uses direct 640x640 resize, RGB, float / 255, then
    # QuantStub. Its Focus order is (even,even), (odd,even), (even,odd),
    # (odd,odd), with three RGB channels in each group.
    resized = letterbox_bgr(image, size)[0] if letterbox else cv2.resize(
        image, (size, size), interpolation=cv2.INTER_LINEAR)
    rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
    quant = np.clip(np.rint(rgb.astype(np.float32) / (255.0 * scale)),
                    0, 255).astype(np.uint8)
    chw = np.transpose(quant, (2, 0, 1))
    return np.ascontiguousarray(np.concatenate((chw[:, ::2, ::2],
                                                chw[:, 1::2, ::2],
                                                chw[:, ::2, 1::2],
                                                chw[:, 1::2, 1::2]), axis=0))
