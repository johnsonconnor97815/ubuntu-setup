"""ubuntu-setup: an idempotent software manager/provisioner for fresh Ubuntu.

Package layout (see .trellis/spec/core/directory-structure.md):

- ``core/``  — THE BRAIN: pure logic, no ``textual`` import, runnable headless.
- ``catalog/`` — declarative catalog DATA (YAML) + ``schema.json``.
- ``tui/``  — THE FACE (Textual); not part of the MVP slice.
- ``cli.py`` — arg parsing + headless ``--apply`` / ``--install`` entry.
"""

__version__ = "0.0.1"
