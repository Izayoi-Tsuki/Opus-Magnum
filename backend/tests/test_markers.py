"""回答标记的整理：补名称、去重复名称、去资料标题式引用。在 backend 目录运行：python -m pytest tests/test_markers.py"""
from types import SimpleNamespace

from pipeline.markers import Markers, MarkerStream

ITEMS = {"001": "纯净水", "003": "光", "912": "铁锭", "920": "清洁剂", "901": "臭氧"}
LOCS = {"factory_lab": "化工实验室", "home_garden": "住处种植区", "market_shop": "杂货铺", "market": "集市"}


def world():
    return SimpleNamespace(
        items=set(ITEMS), stubs=set(),
        item_names={n: i for i, n in ITEMS.items()},
        location_names={n: i for i, n in LOCS.items()},
        locations={i: SimpleNamespace(name=n) for i, n in LOCS.items()},
        item_name=lambda i: ITEMS.get(i, i),
    )


M = Markers(world())


def test_nameless_marker_gets_name():
    assert M.sanitize("去[[loc:home_garden]]看看") == "去[[loc:home_garden|住处种植区]]看看"


def test_stream_nameless_marker():
    s = MarkerStream(M)
    out = s.feed("在[[loc:home_") + s.feed("garden]]种") + s.flush()
    assert out == "在[[loc:home_garden|住处种植区]]种"


def test_dedupe_name_before_marker():
    assert M.finalize("在化工实验室 [[loc:factory_lab|化工实验室]]组装") == "在[[loc:factory_lab|化工实验室]]组装"
    assert M.finalize("需要**铁锭**[[item:912|铁锭]]。") == "需要[[item:912|铁锭]]。"
    assert M.finalize("纯净水[[item:001|纯净水]]和") == "[[item:001|纯净水]]和"


def test_dedupe_paren_and_repeated_marker():
    assert M.finalize("制作清洁剂（[[item:920|清洁剂]]）等") == "制作[[item:920|清洁剂]]等"
    assert M.finalize("在[[loc:factory_lab|化工实验室]] [[loc:factory_lab]]，") == "在[[loc:factory_lab|化工实验室]]，"


def test_dedupe_keeps_prefix_words():
    assert M.finalize("去集市杂货铺 [[loc:market_shop|杂货铺]]买") == "去[[loc:market|集市]][[loc:market_shop|杂货铺]]买"
    # 单字名称不吞前面的词，隔着空格或括号时才算重复
    assert M.finalize("阳光[[item:003|光]]照射") == "阳光[[item:003|光]]照射"
    assert M.finalize("了解光 [[item:003|光]]等物品") == "了解[[item:003|光]]等物品"


def test_title_citations_removed():
    text = "会慢慢失效 [[item:901|臭氧]]、 [[item:920|清洁剂]]·存储]。设备须通风  臭氧·注意]、 臭氧发生器·注意]。"
    assert M.finalize(text) == "会慢慢失效 [[item:901|臭氧]]、 [[item:920|清洁剂]]。设备须通风。"
    assert M.finalize("远离纯净水[3] 电池·存储]。") == "远离[[item:001|纯净水]]。"
    assert M.finalize("现制现用（臭氧·存储）。") == "现制现用。"


def test_quoted_title_becomes_name():
    assert M.finalize("图鉴里记载“电池·存储”需放在干燥处") == "图鉴里记载电池需放在干燥处"
    assert M.finalize("明确记载：**「铁锭·存储」**要求") == "明确记载：[[item:912|铁锭]]要求"


def test_id_note_removed():
    assert M.finalize("果酒（注：资料中为 item:910）等物品") == "果酒等物品"


def test_empty_paren_and_space_before_punct():
    assert M.finalize("只能充进电池里保存（[2]）。远离[[item:001|纯净水]] [1]。") == \
        "只能充进电池里保存。远离[[item:001|纯净水]]。"
    assert M.finalize("用[[item:912|铁锭]] 和塑料") == "用[[item:912|铁锭]] 和塑料"
