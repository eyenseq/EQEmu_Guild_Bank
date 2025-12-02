# EQEmu_Guild_Bank
Guild banking system that allow donation of items and withdraw by members. Withdraws controlled by grants set by leader/bank officers.

## Features

- **Guild-scoped bank** (one bank per guild, keyed by guild name)
- **Item donation** via cursor item (stackable + charged items fully supported)
- **Platinum donation** and officer/leader withdrawal
- **Per-player item grants** (one-time or persistent)
- **Officer & leader permissions**
- **Global grant-all mode**
  - `?guildbank grant all persist` → all members may withdraw any item  
  - `?guildbank revoke all` → turn global access off
- **Stackable item handling**
  - Bank tracks total units; withdraw 1 or 20 at a time
- **Charged item handling**
  - Items are grouped by charge count (e.g. “5 charges” vs “3 charges”)
  - Withdraws preserve the exact charges donated
- **Scrollable bank view** including:
  - Item name, total count, charge info, clickable withdraw links, and ItemID
- **Simple logging system** for recent donations and withdrawals
- **Debug output toggleable** via env variable

---

## Minimum Requirements

- **EQEmu server** with Perl quest support enabled
- **Perl** (matching your server’s quest engine setup)
- **Modules**
  - [x] `JSON::PP` (core in modern Perls)
- **Database schema**
  - `items` table (standard EQEmu) with at least:
    - `id`
    - `Name`
    - `stacksize`
    - `maxcharges`
  - `character_data` table with:
    - `id`
    - `name`
  - `guild_members` table with:
    - `char_id`
    - `guild_id`

---

## Installation

1. **Save the plugin**
Place the plugin file as:

   ```text
   quests/plugins/guildbank.pl
   ```
2. **Wire it into your global player script**

In your global_player.pl (or equivalent global player script), add:
```perl
sub EVENT_SAY {
    return if plugin::guildbank_handle_say($client, $text, $entity_list);
    # ... your other EVENT_SAY logic ...
}
```

3. **Restart zone/world** (or reload quests) so the plugin is picked up.

# Configuration
## Leader Rank

By default, the plugin treats guild ranks 0 and 1 as “leaders” for bank purposes:
```perl
our $GUILDBANK_LEADER_MAXRANK = 1;  # ranks 0..1 are considered leaders
```

If your server uses a different rank layout, adjust this constant in the plugin.

## Debug Messages

You can toggle debug output via an environment variable:
```perl
set GUILDBANK_DEBUG=1   # Enable debug
set GUILDBANK_DEBUG=0   # Disable debug (default)
```

When enabled, the plugin prints extra info (role resolution, load/save, etc.) to help troubleshoot.

## Data Storage

All bank data is stored in EQEmu data_buckets:
```text
Key format:

guildbank:<SANITIZED_GUILD_NAME>


Stored as JSON (via encode_json / decode_json):

Total platinum (pp)

Per-item records with:

Name

Entries grouped by charges (for non-stackables)

Stackable count

Per-player grants

Officer list

Logs

Global grant-all flag

Data is set with a long expiration (10 years), effectively persistent unless manually cleared.
```
# In-Game Usage
## Everyone in the Guild
```text
Donate item on cursor
?donate


If you have an item on your cursor, it will be deposited into the guild bank.

Behavior:

Stackable: uses the stack’s charge count as number of units (e.g. a stack of 20 arrows → +20 units).

Non-stack / charged items: stored as “1 item with N charges”.

Donate platinum
?donate <pp>


Example:

?donate 500


Donates 500 platinum from your character to the guild bank.

View guild bank
?guildbank


Shows:

Item name (via quest::varlink)

Count

Charges info:

stackable for stackables

Charges: N for charged items

Withdraw links (if you are allowed)

Total platinum in bank

For stackable items, you’ll see clickable links like:

[Withdraw 1]

[Withdraw 20]

For charged items, each row is a specific charge count with its own [Withdraw] link.

View logs
?guildbank logs


Shows recent donations and withdrawals (newest last).
```
## Officers & Leaders
```text
(Players with officer status or leader rank.)

Grant item access to a specific member

One-time grant:

?guildbank grant <playername> <itemid>


Example:

?guildbank grant Alice 12345


Alice can withdraw item 12345 once.

On successful withdraw, the grant is consumed.

Persistent grant:

?guildbank grant <playername> <itemid> persist


Example:

?guildbank grant Alice 12345 persist


Alice can withdraw item 12345 indefinitely.

Grant is not consumed by withdrawals.

Revoke item access from a member

Revoke a single item:

?guildbank revoke <playername> <itemid>


Example:

?guildbank revoke Alice 12345


Revoke all item grants:

?guildbank revoke <playername>


Example:

?guildbank revoke Alice

Withdraw items (officer/leader)

Officers and leaders can withdraw any item without grants:

?guildbank withdraw <itemid> [amount_or_charges]


Stackable:

amount_or_charges = number of units to withdraw.

Example:

?guildbank withdraw 13007 20


Non-stack / charged:

amount_or_charges = charge bucket (usually provided automatically via the [Withdraw] link).

Example (from link):

?guildbank withdraw 12345 5

Withdraw all platinum
?guildbank withdrawpp


Withdraws all platinum from the guild bank to the executing character.
```
## Leaders Only
```text
Global “everyone can withdraw anything” mode

Enable global access:

?guildbank grant all persist


All guild members may withdraw any item in the guild bank.

Officers and leaders still behave as usual.

Individual grants are not consumed while in global mode.

Disable global access:

?guildbank revoke all


Turns off global access.

Members will again require per-player grants to withdraw items.

Existing per-player grants remain intact.

Promote / demote guild-bank officers

Promote:

?guildbank promote <playername>


Example:

?guildbank promote Bob


Bob becomes a guild-bank officer (can grant/revoke items, withdraw items, withdraw pp).

Demote:

?guildbank demote <playername>


Example:

?guildbank demote Bob


Bob loses officer status.
```
# Notes & Behavior Details

## Stackable items
```text
Bank stores total units; withdrawals simply subtract from that total.

If you try to withdraw more than exists, you’ll get an error message.
```
## Charged items
```text
Each donated item is tracked in a bucket by its charge count:

e.g. “Item 1234 (5 charges)” and “Item 1234 (3 charges)” are separate rows.

When you click [Withdraw], the plugin withdraws from the correct charge bucket and summons an item with that charge count.
```
## Empty entries
```text
When an item count hits zero, its entry is removed from the bank.
```
## Multiple guilds
```text
Each guild has its own independent bank, keyed by sanitized guild name.
```
### License

### Use and modify freely for your EQEmu server. Attribution appreciated but not required.
