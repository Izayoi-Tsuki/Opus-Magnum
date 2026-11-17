import math
import unittest

from alchemy.geometry import (
    EDGES, NEIGHBOR_DELTAS, POS_COORD, TRANSFORMS, TRI_SYMMETRIES, Layout, is_adjacent, layout_shape,
    placement_orbits, placements,
)
from alchemy.library import LibraryError, library_from_dict, parse_spec
from alchemy.report import build_export
from alchemy.rules import DEFAULT_RULES, rod_options
from alchemy.search import (
    KIND_ROD, KIND_SIDE, KIND_STACK, derivation_steps, explore, library_recipes, outcomes, shortest_paths,
)

R = DEFAULT_RULES


def L(spec):
    return parse_spec(spec, R.elements)


def S(spec):
    return layout_shape(L(spec))


def lib_of(*items):
    elems = [
        {"id": "earth", "name": "土元素", "base": True, "balls": {"0": "土"}},
        {"id": "air", "name": "气元素", "base": True, "balls": {"0": "气"}},
        {"id": "water", "name": "水元素", "base": True, "balls": {"0": "水"}},
        {"id": "fire", "name": "火元素", "base": True, "balls": {"0": "火"}},
    ]
    subs = []
    for sid, name, spec in items:
        lay = L(spec)
        subs.append({"id": sid, "name": name, "balls": {str(i): e for i, e in lay.balls},
                     "rods": [f"{a}-{b}" for a, b in lay.rods]})
    return library_from_dict({"substances": elems + subs}, R)


class GeometryTest(unittest.TestCase):
    def test_nine_short_edges(self):
        self.assertEqual(set(EDGES), {(0, 1), (0, 2), (1, 2), (1, 3), (1, 4), (2, 4), (2, 5), (3, 4), (4, 5)})

    def test_transforms_are_lattice_symmetries(self):
        for t in TRANSFORMS:
            self.assertEqual(t((0, 0)), (0, 0))
            self.assertEqual({t(d) for d in NEIGHBOR_DELTAS}, set(NEIGHBOR_DELTAS))
        chiral = [(0, 0), (1, 0), (2, 0), (0, 1)]
        images = {tuple(sorted(t(p) for p in chiral)) for t in TRANSFORMS}
        self.assertEqual(len(images), 12)

    def test_triangle_symmetries_keep_edges(self):
        self.assertEqual(len({tuple(sorted(g.items())) for g in TRI_SYMMETRIES}), 6)
        for g in TRI_SYMMETRIES:
            self.assertEqual({tuple(sorted((g[a], g[b]))) for a, b in EDGES}, set(EDGES))

    def test_position_does_not_matter(self):
        self.assertEqual(S("0=火 1=水"), S("1=火 2=水"))
        self.assertEqual(S("0=火 1=水"), S("4=火 5=水"))

    def test_rotation_and_mirror_are_same(self):
        self.assertEqual(S("3=火 4=水 5=土"), S("5=火 4=水 3=土"))
        self.assertEqual(S("3=火 4=水 1=土"), S("5=火 4=水 2=土"))
        self.assertEqual(S("3=火 4=水 1=土"), S("2=火 4=水 5=土"))

    def test_up_and_down_small_triangles_are_same(self):
        self.assertEqual(S("0=火 1=火 2=火"), S("1=火 2=火 4=火"))

    def test_angle_matters(self):
        self.assertNotEqual(S("3=火 4=火 5=火"), S("0=火 1=火 4=火"))
        self.assertNotEqual(S("3=火 4=火 5=火"), S("1=火 3=火 4=火"))

    def test_elements_and_rods_matter(self):
        self.assertNotEqual(S("3=火 4=水"), S("3=火 4=土"))
        self.assertNotEqual(S("3=火 4=水"), S("3=火 4=水 | 杆: 3-4"))
        self.assertEqual(S("1=火 3=火 4=火 | 杆: 1-3"), S("1=火 3=火 4=火 | 杆: 3-4"))
        self.assertNotEqual(S("3=火 4=火 5=水 | 杆: 3-4"), S("3=火 4=火 5=水 | 杆: 4-5"))
        self.assertEqual(S("3=火 4=火 5=火 | 杆: 3-4"), S("3=火 4=火 5=火 | 杆: 4-5"))

    def test_disconnected_shapes_keep_relative_geometry(self):
        self.assertEqual(S("3=火 5=水"), S("0=火 3=水"))
        self.assertNotEqual(S("3=火 5=水"), S("3=火 2=水"))
        self.assertNotEqual(S("3=火 5=水"), S("3=火 4=水"))

    def test_placement_counts(self):
        self.assertEqual(len(placements(S("0=火"))), 6)
        self.assertEqual(len(placements(S("3=火 4=火"))), 9)
        self.assertEqual(len(placements(S("3=火 4=水"))), 18)
        self.assertEqual(len(placements(S("3=火 4=火 5=火"))), 3)
        self.assertEqual(len(placements(S(" ".join(f"{i}=土" for i in range(6))))), 1)
        self.assertEqual(len(placement_orbits(S("0=火"))), 2)
        for p in placements(S("3=火 4=水 1=土 | 杆: 3-4")):
            self.assertEqual(layout_shape(p), S("3=火 4=水 1=土 | 杆: 3-4"))

    def test_adjacency_helper(self):
        self.assertTrue(is_adjacent(POS_COORD[1], POS_COORD[4]))
        self.assertFalse(is_adjacent(POS_COORD[0], POS_COORD[4]))


class RulesTest(unittest.TestCase):
    def test_dominance(self):
        order = ["土", "水", "火", "气"]
        for i, a in enumerate(order):
            for b in order[i + 1:]:
                self.assertEqual(R.stronger(a, b), a)
                self.assertEqual(R.stronger(b, a), a)

    def test_overlay_covers_and_merges_rods(self):
        res = R.overlay(L("3=火 4=水 | 杆: 3-4"), L("4=土 5=气 | 杆: 4-5"))
        self.assertEqual(res, L("3=火 4=土 5=气 | 杆: 3-4 4-5"))
        self.assertEqual(R.overlay(L("3=气"), L("3=火")), L("3=火"))

    def test_rod_needs_adjacent_balls(self):
        self.assertEqual(rod_options(L("3=火 5=水")), [])
        self.assertEqual([e for e, _ in rod_options(L("3=火 4=水"))], [(3, 4)])
        self.assertEqual(rod_options(L("3=火 4=水 | 杆: 3-4")), [])


class LibraryTest(unittest.TestCase):
    def test_spec_errors(self):
        for bad in ["3=火 5=水 | 杆: 3-5", "3=火 | 杆: 3-4", "3=金", "", "7=火", "3火"]:
            with self.assertRaises(LibraryError, msg=bad):
                L(bad)

    def test_duplicate_shapes_rejected(self):
        with self.assertRaises(LibraryError):
            lib_of(("a", "甲", "3=火 4=水"), ("b", "乙", "0=水 2=火"))
        lib = library_from_dict({"substances": [
            {"id": "a", "balls": {"3": "火", "4": "水"}}, {"id": "b", "balls": {"0": "水", "2": "火"}},
        ]}, R, strict=False)
        self.assertEqual(len(lib.substances), 1)
        self.assertEqual(len(lib.problems), 1)


class SearchTest(unittest.TestCase):
    def setUp(self):
        self.lib = lib_of(
            ("002", "氢气", "3=火 4=水"),
            ("h2r", "加杆氢气", "3=火 4=水 | 杆: 3-4"),
            ("mud", "泥", "3=土 4=水"),
        )
        self.recipes = library_recipes(self.lib, R)

    def find(self, output, kind, inputs):
        return [r for r in self.recipes if r.output == output and r.kind == kind and sorted(r.inputs) == sorted(inputs)]

    def test_hydrogen_side_by_side(self):
        found = self.find("002", KIND_SIDE, ("fire", "water"))
        self.assertEqual(len(found), 1)
        r = found[0]
        self.assertEqual(layout_shape(r.result), self.lib.by_id["002"].shape)
        self.assertFalse(r.layouts[0].positions & r.layouts[1].positions)

    def test_rod_recipe(self):
        self.assertEqual(len(self.find("h2r", KIND_ROD, ("002",))), 1)

    def test_stack_uses_dominance(self):
        # 土覆盖氢气里的火 → 土与水相邻 = 泥
        self.assertEqual(len(self.find("mud", KIND_STACK, ("002", "earth"))), 1)
        # 气覆盖不了火，所以氢气 + 气 叠放得不到新物质
        self.assertFalse([r for r in self.recipes if sorted(r.inputs) == ["002", "air"] and r.kind == KIND_STACK])

    def test_outputs_always_in_library(self):
        for r in self.recipes:
            self.assertIn(r.output, self.lib.by_id)
            self.assertEqual(layout_shape(r.result), self.lib.by_id[r.output].shape)

    def test_shortest_paths(self):
        paths = shortest_paths(self.lib, self.recipes)
        self.assertEqual(paths["fire"][0], 0)
        self.assertEqual(paths["002"][0], 1)
        self.assertEqual(paths["h2r"][0], 2)
        steps = derivation_steps("h2r", paths)
        self.assertEqual([s.output for s in steps], ["002", "h2r"])

    def test_unreachable(self):
        lib = lib_of(("x", "孤立", "3=火 4=火 5=火 | 杆: 3-4 4-5"))
        paths = shortest_paths(lib, library_recipes(lib, R))
        self.assertTrue(math.isinf(paths["x"][0]))

    def test_outcomes_include_nonexistent(self):
        fire, water = self.lib.by_id["fire"], self.lib.by_id["water"]
        found = outcomes(("fire", fire.shape), ("water", water.shape), R)
        shapes = {f.shape for f in found}
        self.assertIn(self.lib.by_id["002"].shape, shapes)
        self.assertIn(S("3=火 5=水"), shapes)
        self.assertIn(S("3=火 2=水"), shapes)
        # 水直接盖住火只剩下水，等于白白消耗火，不算一种结果
        self.assertEqual(len(shapes), 3)

    def test_explore(self):
        cands = explore(self.lib, R, depth=1)
        keys = {c.shape for c in cands}
        self.assertIn(S("3=火 4=火"), keys)
        self.assertTrue(keys.isdisjoint(self.lib.by_shape))
        deeper = explore(self.lib, R, depth=2, max_balls=3)
        self.assertGreater(len(deeper), len(cands))
        self.assertTrue(all(c.shape.ball_count <= 3 for c in deeper))

    def test_export(self):
        data = build_export(self.lib, R)
        self.assertEqual(data["substances"]["h2r"]["cost"], 2)
        ids = {r["id"] for r in data["recipes"]}
        for s in data["substances"].values():
            self.assertTrue(set(s["made_by"]) <= ids)


if __name__ == "__main__":
    unittest.main()
