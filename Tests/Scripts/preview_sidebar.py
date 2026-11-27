"""Shared visual and selection checks for the Jarvis branch in the two preview galleries."""


def check_jarvis_branch(rows, selected):
    """Each row is a screen rectangle (x, y, width, height) plus its selection state."""
    marked = [key for key, (_, active) in rows.items() if active]
    assert marked == [selected], (selected, marked)
    parent, working, answered, next_bot = [rows[key][0] for key in ("jarvis", "tests", "rename", "patch")]
    x, y, width, height = parent
    assert height > 0 and width > 0, parent
    for child in (working, answered):
        left, _, child_width, child_height = child
        # The tree marker and the selected row both fit inside the parent column.
        assert left > x + height / 2 and left + child_width < x + width, (parent, child)
        assert height * 0.85 <= child_height <= height, (parent, child)
    assert abs(working[0] - answered[0]) <= 1 and abs(working[2] - answered[2]) <= 1, (working, answered)
    for upper, lower in zip((parent, working, answered), (working, answered, next_bot)):
        gap = lower[1] - (upper[1] + upper[3])
        assert 0 < gap < height / 4, (upper, lower)
    assert abs(next_bot[0] - x) <= 1, (parent, next_bot)
