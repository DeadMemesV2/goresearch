# scoring.py
"""
Severity scoring 0.0–1.0; display scale 0.1–1.0.
Combines text keywords (weighted) and optional image analysis.
"""

from config import (
    KEYWORD_WEIGHTS,
    FALSE_POSITIVE_EXCLUSIONS,
    FICTION_FAKE_INDICATORS,
    REAL_CONTENT_WEIGHTS,
    SEVERITY_COLOR_ANCHORS,
    SEVERITY_MIN,
    SEVERITY_MAX,
    IMAGE_RED_PERCENT_TO_SEVERITY,
)
from utils import image_gore_score


def _is_false_positive(text: str, keyword: str) -> bool:
    if keyword not in FALSE_POSITIVE_EXCLUSIONS:
        return False
    text_lower = text.lower()
    for excl in FALSE_POSITIVE_EXCLUSIONS[keyword]:
        if excl in text_lower:
            return True
    return False


def score_text(text: str) -> float:
    """
    Score text 0.0–1.0 from keyword weights. Multiple keywords add (capped at 1.0).
    Exclusions reduce contribution for that keyword.
    Fiction/fake indicators (movie, film, etc.) apply a heavy penalty.
    Real-content indicators (real footage, CCTV, etc.) add a bonus.
    """
    if not text or not text.strip():
        return 0.0
    text_lower = text.lower()
    total = 0.0
    # Base score from gore/violence keywords
    for keyword, weight in sorted(KEYWORD_WEIGHTS.items(), key=lambda x: -x[1]):
        if keyword in text_lower and not _is_false_positive(text_lower, keyword):
            total += weight
            if total >= 1.0:
                break
    total = min(1.0, total)

    # Penalty: movie / fake / fiction content gets much lower severity
    for indicator in FICTION_FAKE_INDICATORS:
        if indicator in text_lower:
            total *= 0.25
            break

    # Bonus: real footage / documentary / actual content gets boosted
    for phrase, bonus in sorted(REAL_CONTENT_WEIGHTS.items(), key=lambda x: -x[1]):
        if phrase in text_lower:
            total = min(1.0, total + bonus)
            break

    return max(0.0, min(1.0, total))


def score_image_from_url(url: str) -> float:
    """
    Score image 0.0–1.0 from red/blood-like pixel analysis.
    Uses IMAGE_RED_PERCENT_TO_SEVERITY: that % red → 1.0.
    """
    raw = image_gore_score(url)  # 0.0–1.0 from utils
    return min(1.0, max(0.0, raw))


def score_article(article: dict, include_image: bool = True) -> float:
    """
    Score a news article: text + optional image. Returns 0.0–1.0.
    Combined: max(text_score, image_score) so either signal raises severity.
    """
    title = article.get("title") or ""
    desc = article.get("description") or ""
    text_score = score_text(title + " " + desc)

    if not include_image:
        return text_score

    image_url = article.get("urlToImage")
    if not image_url:
        return text_score

    img_score = score_image_from_url(image_url)
    return max(text_score, img_score)


def clamp_severity_display(score: float) -> float:
    """Clamp to display scale 0.1–1.0 (never show 0.0)."""
    return max(SEVERITY_MIN, min(SEVERITY_MAX, round(score, 2)))


def score_to_color(score: float) -> str:
    """Map severity 0.0–1.0 to hex color using SEVERITY_COLOR_ANCHORS."""
    s = max(0.0, min(1.0, score))
    anchors = SEVERITY_COLOR_ANCHORS
    if s <= anchors[0][0]:
        return anchors[0][1]
    if s >= anchors[-1][0]:
        return anchors[-1][1]
    for i in range(len(anchors) - 1):
        a_val, a_hex = anchors[i]
        b_val, b_hex = anchors[i + 1]
        if a_val <= s <= b_val:
            t = (s - a_val) / (b_val - a_val) if b_val != a_val else 1.0
            return _lerp_hex(a_hex, b_hex, t)
    return anchors[-1][1]


def _lerp_hex(hex_a: str, hex_b: str, t: float) -> str:
    """Linear interpolate between two hex colors; t in [0,1]."""
    def parse(h):
        h = h.lstrip("#")
        return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
    a, b = parse(hex_a), parse(hex_b)
    r = int(a[0] + (b[0] - a[0]) * t)
    g = int(a[1] + (b[1] - a[1]) * t)
    b_ = int(a[2] + (b[2] - a[2]) * t)
    return f"#{r:02X}{g:02X}{b_:02X}"
