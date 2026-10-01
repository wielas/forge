"""Slugs for chunk branches — a change whose tests pin every line."""


def slugify(title: str, max_len: int = 12) -> str:
    words = [word for word in title.lower().split() if word.isalnum()]
    slug = "-".join(words)
    if len(slug) > max_len:
        slug = slug[:max_len].rstrip("-")
    return slug or "untitled"
