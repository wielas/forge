"""Label normalisation — the July ladder's PR #6 (`t_624586d7`), in miniature."""


def normalize_label(raw: str) -> str:
    """Collapse whitespace and lower-case a label; an empty one is "untitled"."""
    words = raw.split()
    if not words:
        return "untitled"
    return "-".join(word.lower() for word in words)
