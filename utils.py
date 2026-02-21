# utils.py
"""
Image analysis: bright red + dark red (blood) pixel detection → severity 0.0–1.0.
Improved for scenes with blood pools, trauma, and graphic injury.
"""

import requests
from io import BytesIO
from PIL import Image

from config import IMAGE_RED_PERCENT_TO_SEVERITY


def detect_image_gore(url: str) -> tuple[bool, float]:
    """Legacy: (is_gore, red_percentage)."""
    _, pct = _blood_red_percentage(url)
    return (pct > IMAGE_RED_PERCENT_TO_SEVERITY, pct)


def image_gore_score(url: str) -> float:
    """
    Returns 0.0–1.0. Uses combined bright + dark red (blood-like) pixel percentage.
    Dark red catches blood pools; bright red catches fresh/arterial blood.
    """
    try:
        pct = _blood_red_percentage(url)[1]
        cap = max(0.01, IMAGE_RED_PERCENT_TO_SEVERITY)
        return min(1.0, pct / cap)
    except Exception:
        return 0.0


def _blood_red_percentage(url: str) -> tuple[bool, float]:
    """
    Fetch image, compute % of blood-like pixels.
    - Bright red: R > 140, G < 110, B < 110 (fresh/arterial blood, red surfaces).
    - Dark red: R > 70, G < 55, B < 55, R > G, R > B (dried blood, blood pools, dark red).
    Returns (success, percentage).
    """
    try:
        resp = requests.get(url, timeout=6)
        resp.raise_for_status()
        img = Image.open(BytesIO(resp.content))
        img = img.convert("RGB")
        pixels = list(img.getdata())
        total = len(pixels)
        count = 0
        for r, g, b in pixels:
            # Bright red
            if r > 140 and g < 110 and b < 110:
                count += 1
            # Dark red / blood pool (R dominant, low saturation)
            elif r > 70 and g < 55 and b < 55 and r > g and r > b:
                count += 1
        pct = (count / total * 100) if total > 0 else 0.0
        return True, pct
    except Exception:
        return False, 0.0
