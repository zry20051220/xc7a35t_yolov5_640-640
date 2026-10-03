import cv2
import numpy as np

def letterbox_bgr_to_rgb(image, size=640):
    h, w = image.shape[:2]
    scale = min(size / w, size / h)
    nw, nh = int(round(w * scale)), int(round(h * scale))
    resized = cv2.resize(image, (nw, nh), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((size, size, 3), 114, dtype=np.uint8)
    x, y = (size - nw) // 2, (size - nh) // 2
    canvas[y:y+nh, x:x+nw] = resized
    return cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB), scale, (x, y)
