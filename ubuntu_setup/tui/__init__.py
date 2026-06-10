"""THE FACE (Textual). Not part of the MVP slice.

The TUI only renders state and collects intent; it holds no install logic, no
``subprocess``, no ``sudo``, and the brain (``core/``) never imports it. See
``.trellis/spec/tui/ui-guidelines.md``.
"""
