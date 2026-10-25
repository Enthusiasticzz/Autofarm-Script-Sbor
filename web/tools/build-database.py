"""Turn a DatabaseDump.json (pressed in game) into web/database.js.

    py tools/build-database.py [dump.json] [database.js]

Run from the web/ folder; the defaults are ../DatabaseDump.json and
../database.js, both next to this site.

The dump is the game's own data, so almost nothing here is invented: names,
types, stats, worth, shop prices, sources, descriptions, recipes and drops all
come straight from it. Four things are derived, because the game has no such
fields: the tab a record belongs to (from its game type), the equipment slot,
the cosmetic group shown in the overlays tab, and rarity (from drop rates).

Records keep the game's shape as far as the site needs it:

    id, name, type, kind, slot, group, level, skill, dmg, def, dex,
    worth, sell, sellAgility, rarity?, eventCurrency, obtained[], flags[],
    desc, effect { name, props[] }, drops[], recipe { skill, materials[] }

`rarity` exists only where the game gives a drop rate: it is the tier of the
record's rarest known 1-in-N drop. Records the game never revealed a drop for
are left blank, so they can be filled in by hand in the staff panel. The same
bands are used for the drop tables in the browser.
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.dirname(HERE)

DEFAULT_DUMP = os.path.join(WEB, "DatabaseDump.json")
DEFAULT_OUT = os.path.join(WEB, "database.js")

# Game type -> equipment slot. These are the pieces that carry stats: weapons
# (DMG), outfits (DEF / DEX), headwear (DEF / DEX) and shields (DEF). Armor3D
# is a cosmetic 3D shell worn over an outfit - it has no defence - so it is an
# overlay, not armor. Everything not listed here or below is a material or
# consumable, i.e. an item.
EQUIPMENT_SLOTS = {
    "One-Handed": "Weapon",
    "Two-Handed": "Weapon",
    "Rapier": "Weapon",
    "Dagger": "Weapon",
    "Melee": "Weapon",
    "Shield": "Offhand",
    "Outfit": "Armor",
    # Headwear is worn on the head; LowerHeadwear is the cape, scarf and
    # necklace layer, so the two are different slots.
    "UpperHeadwear": "Headwear",
    "LowerHeadwear": "Accessory",
    "FishingRod": "Tool",
}

# Cosmetic shells and skins: no stats of their own.
COSMETIC_TYPES = {
    "Armor3D",
    "Facewear",
    "OutfitOverlay",
    "UpperHeadwearOverlay",
    "LowerHeadwearOverlay",
    "One-HandedOverlay",
    "Two-HandedOverlay",
    "RapierOverlay",
    "DaggerOverlay",
    "MeleeOverlay",
    "ShieldOverlay",
}

# A friendlier label than the raw game type, for the overlays tab. The raw
# type is still kept on the record and shown in its detail sheet.
COSMETIC_GROUPS = {
    "Armor3D": "3D armor",
    "Facewear": "Facewear",
    "OutfitOverlay": "Outfit overlay",
    "UpperHeadwearOverlay": "Headwear overlay",
    "LowerHeadwearOverlay": "Accessory overlay",
    "One-HandedOverlay": "Weapon overlay",
    "Two-HandedOverlay": "Weapon overlay",
    "RapierOverlay": "Weapon overlay",
    "DaggerOverlay": "Weapon overlay",
    "MeleeOverlay": "Weapon overlay",
    "ShieldOverlay": "Shield overlay",
}

# Guild-locked cosmetics and gear are not traded and clutter the database, so
# they are left out of the site entirely.
EXCLUDED_SOURCES = {"Guild"}

# The game writes Obtained as a comma-separated list. These are the words it
# uses; anything else is a typo or a stray description and is dropped.
SOURCE_LABELS = {
    "event": "Event",
    "shop": "Shop",
    "smithing": "Smithing",
    "crafting": "Crafting",
    "unique": "Unique",
    "drop": "Drop",
    "gamepass": "Gamepass",
    "guild": "Guild",
    "quest": "Quest",
    "badge": "Badge",
    "mining": "Mining",
    "fishing": "Fishing",
}

FLAGS = ("Bound", "Pass", "Unobtainable", "Group", "Badge")

STAT_KEYS = {
    "LVL": "level",
    "Skill": "skill",
    "DMG": "dmg",
    "DEF": "def",
    "DEX": "dex",
}


def slug(text):
    return re.sub(r"[^a-z0-9]", "", text.lower())


def tier_for(one_in):
    """The site's rarity bands, the same ones the browser uses for drops."""
    k = max(1, number(one_in))

    if k <= 4:
        return "Common"
    if k <= 19:
        return "Uncommon"
    if k <= 99:
        return "Rare"
    if k <= 499:
        return "Epic"
    if k <= 4999:
        return "Legendary"
    return "Mythic"


def number(value):
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return int(value) if float(value).is_integer() else round(value, 3)
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return 0


def stats_of(item):
    return {stat["Key"]: stat.get("Value") for stat in item.get("Stats") or []}


def sources_of(item):
    raw = stats_of(item).get("Obtained")
    found = []

    for part in str(raw or "").split(","):
        word = part.strip().lower()

        if word in SOURCE_LABELS:
            label = SOURCE_LABELS[word]
        elif word.startswith("drop"):
            # The game has a few of these: "Drop..?", "Drop???".
            label = "Drop"
        else:
            continue

        if label not in found:
            found.append(label)

    return found


def effect_of(item):
    status = item.get("Status")

    if not status or not status.get("Name"):
        return None

    props = []

    for prop in status.get("Props") or []:
        value = prop.get("Value")

        if value is None or value == "":
            continue

        props.append({"label": str(prop.get("Label") or "").title(), "value": value})

    return {"name": str(status["Name"]), "props": props}


def describe(item):
    value = stats_of(item).get("Description")

    if value is None:
        return ""

    text = str(value).replace("\r\n", "\n").strip()
    return re.sub(r"\n{3,}", "\n\n", text)


def classify(game_type):
    if game_type in EQUIPMENT_SLOTS:
        return "equipment"
    if game_type in COSMETIC_TYPES:
        return "overlays"
    return "items"


def build(dump):
    mob_drops = {}

    for mob in dump.get("Mobs") or []:
        for drop in mob.get("Drops") or []:
            mob_drops.setdefault(drop["Name"], []).append(
                {
                    "mob": mob["Name"],
                    "oneIn": number(drop.get("Rarity")),
                    "rolls": max(1, number(drop.get("Rounds"))),
                }
            )

    recipes = {}

    for recipe in dump.get("Recipes") or []:
        recipes[recipe["Name"]] = {
            "skill": number(recipe.get("Skill")),
            "materials": [
                {"name": material["Name"], "amount": number(material.get("Amount"))}
                for material in recipe.get("Materials") or []
            ],
        }

    records = {"items": [], "equipment": [], "overlays": []}
    used_ids = set()

    for item in dump.get("Items") or []:
        name = item.get("Name")

        if not name:
            continue

        stats = stats_of(item)
        game_type = item.get("Type") or "Other"
        kind = classify(game_type)
        obtained = sources_of(item)
        sell = item.get("Sell") or {}

        if any(source in EXCLUDED_SOURCES for source in obtained):
            continue

        record = {
            "id": "",
            "name": name,
            "type": game_type,
            "kind": kind,
            "level": number(stats.get("LVL")),
            "worth": number(item.get("Worth")),
            "sell": number(sell.get("Normal")),
            "sellAgility": number(sell.get("Agility")),
            "source": obtained[0] if obtained else "",
        }

        if kind == "equipment":
            record["slot"] = EQUIPMENT_SLOTS[game_type]
        elif kind == "overlays":
            record["group"] = COSMETIC_GROUPS.get(game_type, "Overlay")

        for key, field in (("Skill", "skill"), ("DMG", "dmg"), ("DEF", "def"), ("DEX", "dex")):
            if stats.get(key) is not None:
                record[field] = number(stats[key])

        if item.get("EventCurrency"):
            record["eventCurrency"] = str(item["EventCurrency"])

        flags = [flag for flag in item.get("Flags") or [] if flag in FLAGS]

        if flags:
            record["flags"] = flags

        if len(obtained) > 1:
            record["obtained"] = obtained

        description = describe(item)

        if description:
            record["desc"] = description

        effect = effect_of(item)

        if effect:
            record["effect"] = effect

        drops = mob_drops.get(name)

        if drops:
            record["drops"] = sorted(drops, key=lambda drop: (drop["oneIn"], drop["mob"]))

            # Rarity comes from the game's own drop rate: the rarest known way
            # to get it. Unseen drops stay blank, for manual entry.
            record["rarity"] = tier_for(max(drop["oneIn"] for drop in drops))

        recipe = recipes.get(name)

        if recipe:
            record["recipe"] = recipe

        base = slug(name) or "record"
        candidate, suffix = base, 1

        while candidate in used_ids:
            suffix += 1
            candidate = base + "-" + str(suffix)

        used_ids.add(candidate)
        record["id"] = candidate
        records[kind].append(record)

    records["equipment"].sort(key=lambda r: (r["slot"], r["level"], r["name"]))
    records["items"].sort(key=lambda r: (r["type"], r["name"]))
    records["overlays"].sort(key=lambda r: (r["group"], r["name"]))

    mob_names = sorted({mob.get("Name") for mob in dump.get("Mobs") or [] if mob.get("Name")})

    return {
        "meta": {
            "game": dump.get("Game") or "",
            "placeId": dump.get("PlaceId") or 0,
            "dumpedAt": dump.get("DumpedAt") or "",
            "counts": {
                "items": len(records["items"]),
                "equipment": len(records["equipment"]),
                "overlays": len(records["overlays"]),
                "recipes": len(recipes),
                "mobs": len(mob_names),
            },
        },
        "mobs": mob_names,
        "items": records["items"],
        "equipment": records["equipment"],
        "overlays": records["overlays"],
    }


def main():
    dump_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DUMP
    out_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT

    with open(dump_path, encoding="utf-8") as handle:
        dump = json.load(handle)

    payload = build(dump)
    counts = payload["meta"]["counts"]

    text = (
        "/* Gilded Archive - generated database. Do not edit by hand.\n"
        "   Source: DatabaseDump.json from the game (pressed with the Asset\n"
        "   Explorer's DUMP DATABASE button). Rebuild with:\n\n"
        "     py tools/build-database.py\n\n"
        "   Record shape and the tab mapping are documented in that script. */\n"
        "window.GA_DB = "
        + json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        + ";\n"
    )

    with open(out_path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)

    print(
        "%s: %d items, %d equipment, %d overlays (%d recipes, %d mobs) -> %s (%.1f KB)"
        % (
            dump_path,
            counts["items"],
            counts["equipment"],
            counts["overlays"],
            counts["recipes"],
            counts["mobs"],
            out_path,
            len(text.encode("utf-8")) / 1024,
        )
    )


if __name__ == "__main__":
    main()
