"""Planner tests — desired list -> ordered Plan, with typed errors (exit 2)."""

from __future__ import annotations

import unittest

from ubuntu_setup.core.errors import CatalogError
from ubuntu_setup.core.models import CatalogEntry, Op
from ubuntu_setup.core.planner import build_plan

_CATALOG = {
    "ripgrep": CatalogEntry(id="ripgrep", description="x", type="apt",
                            fields={"package": "ripgrep"}),
    "tree": CatalogEntry(id="tree", description="x", type="apt",
                         fields={"package": "tree"}),
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


if __name__ == "__main__":
    unittest.main()
