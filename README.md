# SlipPacker

Windower 4 addon for FFXI. Packs gear from your inventory onto storage slips that are also in your inventory, and shows what is stored on each slip.

No gear lists to set up. Put the slips and the gear in your inventory, stand at a Porter Moogle, and run `//sp pack`.

**Author:** Meechie
**Version:** 1.0.0

## Install

1. Copy the `SlipPacker` folder into `Windower/addons/`.
2. In game: `//lua load slippacker`

## Commands

| Command | What it does |
| --- | --- |
| `//sp pack` | Pack every inventory item whose slip is also in inventory |
| `//sp pack 13` | Pack only items that go on slip 13 |
| `//sp check` | Preview what `pack` would store. Nothing moves |
| `//sp check 13` | Preview for slip 13 only |
| `//sp list` | Slips in inventory with stored counts, plus slips in other bags and slips you're missing |
| `//sp list all` | Same, for slips in every bag |
| `//sp show 13` | Every item stored on slip 13 (any bag) |
| `//sp show` | Every slip in inventory with its items |
| `//sp show all` | Every slip in every bag with its items |
| `//sp items 13` | Everything slip 13 can hold, split into stored and not stored |
| `//sp dump` | Write all slip contents to `data/<name>_slips.txt` |
| `//sp stop` | Stop a pack in progress and reset |

Short forms: `p`, `c`, `l`, `s`, `i`, `d`. `reset` works the same as `stop`. `//sp` with no command shows the help list. `//slippacker` works in place of `//sp`.

## How It Works

- `pack` checks that you're idle and a Porter Moogle is in range, then trades one slip plus up to 7 items for it at a time.
- After each trade it waits for the items to show up on the slip before moving on.
- If a trade doesn't land, it retries that slip one item at a time. An item that fails twice is skipped and listed at the end.
- It stops if the porter fails 6 trades in a row, if you zone or log out, if you stop being idle, or if the porter menu gets cancelled.
- When it finishes it reports how many items went onto how many slips, and lists anything left behind and why.
- Don't move until it says it's done.

## Rules

- Only inventory is scanned. Gear in wardrobes, satchel, etc. is left alone.
- Equipped gear is skipped.
- The slip has to be in inventory. `check` and `pack` list items whose slip is somewhere else, and say which bag it's in.
- A slip holds one copy of an item. Extra copies are listed and left in inventory.
- Augmented gear follows the porter's rules and is listed if it can't be stored.
- `show`, `list`, `items` and `dump` work anywhere. `pack` needs a Porter Moogle in range and an idle character.

## Porter Zones

Northern San d'Oria, Bastok Markets, Port Windurst, Lower Jeuno, Southern San d'Oria [S], Bastok Markets [S], Windurst Waters [S], Rabao, Selbina, Mhaura, Kazham, Norg, Tavnazian Safehold, Aht Urhgan Whitegate, Nashmau, Western Adoulin, Mog Garden, Walk of Echoes [P1] and [P2].

## Credits

Porter Moogle packet details come from PorterPacker by Ivaar (modified by Gimlic and Siyual) and the PorterPacker refactor by ejouanchicot.
