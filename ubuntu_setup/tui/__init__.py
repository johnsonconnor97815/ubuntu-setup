"""THE FACE (Textual): browse -> plan-confirm -> progress.

The TUI only renders state and collects intent; it holds no install logic, no
``subprocess``, no ``sudo`` — it consumes the ``core/service.py`` facade from
workers, and the brain (``core/``) never imports it. Entered by the bare
``python -m ubuntu_setup`` (the CLI imports this package only in that branch,
so headless runs never load ``textual``). See
``.trellis/spec/tui/ui-guidelines.md``.
"""
