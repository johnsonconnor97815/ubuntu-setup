# Catalog (the Data) — Spec Index

> Guidelines for authoring `ubuntu_setup/catalog/*.yaml`: the declarative software catalog the engine interprets, and the contract the future LLM phase generates against.

---

## Status

No source code yet. These specs are **prescriptive**, derived from `design-direction.md`. The field set must stay in sync with `catalog/schema.json` and the providers in [../core/catalog-and-providers.md](../core/catalog-and-providers.md).

---

## Guidelines

| Guide | What it covers |
|-------|----------------|
| [Authoring Guidelines](./authoring-guidelines.md) | Entry shape, the field set per `type`, `depends_on`, provenance/trust, authoring rules, and the constraints the LLM phase must obey |

---

## The non-negotiables

1. **Entries are data, not code.** Adding normal software touches YAML only, never Python.
2. **Prefer a declarative `type` over the `script` escape hatch.** `script` is the last resort and the only place arbitrary commands run.
3. **Every entry is idempotently checkable** (`script` needs a real `check`).
4. **`source` marks trust:** `official` / `community` / `ai-generated`; AI drafts are never auto-promoted.
5. **The LLM phase emits declarative, schema-valid entries only — never `script`.**
