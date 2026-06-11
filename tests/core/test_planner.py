"""Planner tests — desired list -> ordered Plan, with typed errors (exit 2)."""

from __future__ import annotations

import unittest

from ubuntu_setup.core.errors import CatalogError
from ubuntu_setup.core.models import CatalogEntry, Op
from ubuntu_setup.core.planner import build_plan

def _entry(eid: str, *, deps: "tuple[str, ...]" = ()) -> CatalogEntry:
    return CatalogEntry(id=eid, description="x", type="apt",
                        depends_on=deps, fields={"package": eid})


_CATALOG = {
    "ripgrep": _entry("ripgrep"),
    "tree": _entry("tree"),
}

#: docker-repo <- docker dependency chain plus an independent entry
_DEP_CATALOG = {
    "docker-repo": _entry("docker-repo"),
    "docker": _entry("docker", deps=("docker-repo",)),
    "tree": _entry("tree"),
}


class TestBuildPlan(unittest.TestCase):
    def test_maps_desired_in_listed_order(self):
        plan = build_plan(
            [{"id": "tree", "op": "install"}, {"id": "ripgrep", "op": "install"}],
            _CATALOG,
        )
        self.assertEqual([a.entry.id for a in plan], ["tree", "ripgrep"])
        self.assertEqual([a.op for a in plan], [Op.INSTALL, Op.INSTALL])

    def test_op_defaults_to_install(self):
        plan = build_plan([{"id": "tree"}], _CATALOG)
        self.assertEqual(plan.actions[0].op, Op.INSTALL)

    def test_unknown_id_raises_catalog_error(self):
        with self.assertRaises(CatalogError):
            build_plan([{"id": "nope"}], _CATALOG)

    def test_unknown_op_raises_catalog_error(self):
        with self.assertRaises(CatalogError):
            build_plan([{"id": "tree", "op": "explode"}], _CATALOG)

    def test_missing_id_raises_catalog_error(self):
        with self.assertRaises(CatalogError):
            build_plan([{"op": "install"}], _CATALOG)

    def test_non_mapping_item_raises_catalog_error(self):
        # a hand-written manifest with `desired: ["ripgrep"]` must be exit 2,
        # not an AttributeError traceback
        with self.assertRaises(CatalogError):
            build_plan(["ripgrep"], _CATALOG)  # type: ignore[list-item]

    def test_duplicate_same_op_is_deduped(self):
        plan = build_plan([{"id": "tree"}, {"id": "tree", "op": "install"}], _CATALOG)
        self.assertEqual([a.entry.id for a in plan], ["tree"])

    def test_conflicting_duplicate_ops_raise(self):
        with self.assertRaises(CatalogError):
            build_plan([{"id": "tree", "op": "install"},
                        {"id": "tree", "op": "remove"}], _CATALOG)


class TestClosureAndTopoSort(unittest.TestCase):
    """depends_on closure expansion + deterministic, stable topological order."""

    def test_install_pulls_dependency_in_before_dependent(self):
        plan = build_plan([{"id": "docker"}], _DEP_CATALOG)
        self.assertEqual([a.entry.id for a in plan], ["docker-repo", "docker"])
        self.assertEqual([a.op for a in plan], [Op.INSTALL, Op.INSTALL])

    def test_transitive_closure(self):
        catalog = {
            "a": _entry("a", deps=("b",)),
            "b": _entry("b", deps=("c",)),
            "c": _entry("c"),
        }
        plan = build_plan([{"id": "a"}], catalog)
        self.assertEqual([a.entry.id for a in plan], ["c", "b", "a"])

    def test_shared_dependency_is_deduped(self):
        catalog = {
            "repo": _entry("repo"),
            "one": _entry("one", deps=("repo",)),
            "two": _entry("two", deps=("repo",)),
        }
        plan = build_plan([{"id": "one"}, {"id": "two"}], catalog)
        self.assertEqual([a.entry.id for a in plan], ["repo", "one", "two"])

    def test_explicit_dep_listed_after_dependent_is_ordered_first_not_duplicated(self):
        plan = build_plan([{"id": "docker"}, {"id": "docker-repo"}], _DEP_CATALOG)
        self.assertEqual([a.entry.id for a in plan], ["docker-repo", "docker"])

    def test_independent_entries_keep_input_order(self):
        plan = build_plan([{"id": "tree"}, {"id": "docker"}], _DEP_CATALOG)
        self.assertEqual([a.entry.id for a in plan],
                         ["tree", "docker-repo", "docker"])

    def test_upgrade_expands_dependencies_with_implicit_install(self):
        plan = build_plan([{"id": "docker", "op": "upgrade"}], _DEP_CATALOG)
        self.assertEqual([(a.entry.id, a.op) for a in plan],
                         [("docker-repo", Op.INSTALL), ("docker", Op.UPGRADE)])

    def test_remove_does_not_pull_dependencies_in(self):
        plan = build_plan([{"id": "docker", "op": "remove"}], _DEP_CATALOG)
        self.assertEqual([(a.entry.id, a.op) for a in plan],
                         [("docker", Op.REMOVE)])

    def test_cycle_raises_with_cycle_path(self):
        catalog = {
            "a": _entry("a", deps=("b",)),
            "b": _entry("b", deps=("a",)),
        }
        with self.assertRaises(CatalogError) as ctx:
            build_plan([{"id": "a"}], catalog)
        self.assertIn("a -> b -> a", str(ctx.exception))

    def test_self_dependency_raises(self):
        catalog = {"a": _entry("a", deps=("a",))}
        with self.assertRaises(CatalogError) as ctx:
            build_plan([{"id": "a"}], catalog)
        self.assertIn("a -> a", str(ctx.exception))

    def test_dependency_missing_from_catalog_raises(self):
        # the loader resolves deps against the full catalog; a filtered subset
        # must fail loudly, not plan a half-built chain
        subset = {"docker": _DEP_CATALOG["docker"]}
        with self.assertRaises(CatalogError) as ctx:
            build_plan([{"id": "docker"}], subset)
        self.assertIn("docker-repo", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
