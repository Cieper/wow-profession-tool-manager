# Profession Tool Manager

Adds one-click "Equip Resourcefulness / Multicraft / Ingenuity" buttons to the profession crafting pages, so you stop tabbing out to your bags to swap tools before every craft.

## What it does

Adds a button next to Blizzard's own Create/Craft button, on both the regular crafting page and the crafting-order view. Clicking a button equips the best tool you own for that stat, then you hit Blizzard's Create/Craft button yourself — that button is never touched programmatically, so there's no taint or secure-execution risk.

A stat's button only shows up when it's actually worth clicking, meaning all of:

- the recipe uses that stat (per Crafting Details' `bonusStats`)
- you own a tool granting it that's rated higher than (or different from) what's currently equipped
- for Ingenuity specifically, "Apply Concentration" has to be turned on, since Ingenuity does nothing otherwise

The best tool is picked by rating, so a 150-Resourcefulness tool always beats an already-equipped 100. Matching accounts for both the tool's profession (by item subclass) and the craft's actual expansion (from the recipe's output item, not the equipped tool or tier name, since both of those are unreliable across expansions). The recommended button also gets Blizzard's own green tutorial glow, same as their new-player hints use.

## Usage

- `/ptm` — print a diagnostic: which tools are eligible, their stat ratings, and what's currently equipped.
- `/ptm dump` — also dump the equipped tool's raw stat keys, useful for chasing down a non-English client where the tooltip-text fallback might need adjusting.

## Compatibility

Targets WoW: Midnight (`## Interface: 120100`), verified against the `wow-ui-source` mirror at the matching tag.

## License

MIT, see [LICENSE](LICENSE).
