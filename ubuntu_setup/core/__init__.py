"""The brain: pure logic (catalog, planning, checking, execution, manifest).

Nothing under ``core/`` may import ``textual`` or ``tui`` — the dependency
direction is ``cli -> tui -> core`` (see directory-structure.md).
"""
