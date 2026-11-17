"""图谱的固定类型。抽取、对齐、查询都以这里为准。"""
from __future__ import annotations

ITEM, DEVICE, PROCESS, PLACE, CONCEPT, ELEMENT = "物品", "设备", "工艺", "地点", "概念", "炼金物质"
ENTITY_TYPES = [ITEM, DEVICE, PROCESS, PLACE, CONCEPT]
PREFIX = {ITEM: "item", DEVICE: "dev", PROCESS: "proc", PLACE: "loc", CONCEPT: "concept", ELEMENT: "alc"}

# 关系：允许的（头类型，尾类型），以及转成句子的模板
RELATIONS: dict[str, tuple[set[str], set[str], str]] = {
    "原料":     ({ITEM}, {PROCESS}, "{h}是{t}的原料"),
    "产出":     ({PROCESS}, {ITEM}, "{h}产出{t}"),
    "使用设备": ({PROCESS}, {DEVICE}, "{h}需要用到{t}"),
    "获取于":   ({ITEM}, {PLACE}, "{h}可以在{t}获取"),
    "获取途径": ({ITEM}, {DEVICE, PROCESS}, "{h}可以通过{t}获得"),
    "安装于":   ({DEVICE}, {PLACE}, "{t}可以安装{h}"),
    "用于":     ({ITEM}, {PROCESS, CONCEPT, ITEM}, "{h}可用于{t}"),
    "存储于":   ({ITEM}, {DEVICE}, "{h}需要存储在{t}中"),
    "关联":     ({ITEM}, {ITEM, CONCEPT}, "{h}与{t}相关"),
}
EXTRACTED_RELATIONS = list(RELATIONS)

# 小模型常见的关系误用：(关系, 头类型, 尾类型) → 改写成的关系
REPAIRS = {
    ("获取途径", ITEM, PLACE): "获取于",
    ("获取于", ITEM, DEVICE): "获取途径",
    ("获取于", ITEM, PROCESS): "获取途径",
    ("产出", ITEM, ITEM): "用于",          # 甲 产出 乙 ≈ 甲用于制作乙
    ("产出", ITEM, PROCESS): "原料",       # 冰块 产出 加热 ≈ 冰块是加热的原料
    ("原料", ITEM, CONCEPT): "关联",       # 光 原料 神性 ≈ 光与神性相关
    ("原料", ITEM, ITEM): "用于",
}

# 非抽取来源的关系
LOCATED = "位于"          # 地图：子地点 → 父地点
ALCHEMY = "炼金合成"      # 算法推导：原料 → 产物
RELATIONS[LOCATED] = ({PLACE}, {PLACE}, "{h}位于{t}")
RELATIONS[ALCHEMY] = ({ITEM, ELEMENT}, {ITEM, ELEMENT}, "{h}是炼金合成{t}的原料")

SOURCE_EXTRACT, SOURCE_MAP, SOURCE_ALCHEMY, SOURCE_MANUAL = "抽取", "地图", "算法推导", "人工"
