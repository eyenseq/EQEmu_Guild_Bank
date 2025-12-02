package plugin;

use JSON::PP qw(encode_json decode_json);

# -----------------------------------------------------
# Guild Bank Plugin (data_buckets + hashes)
#
# Commands (must be in a guild, all via /say):
#
# Everyone in guild:
#   ?donate                     - donate item on cursor OR
#   ?donate <pp>                - donate that much platinum
#   ?guildbank                  - view guild bank
#   ?guildbank logs             - view recent logs (withdraws)
#
# Leader + Officer:
#   ?guildbank grant <name> <itemid>
#   ?guildbank grant <name> <itemid> [persist]
#   ?guildbank revoke <name> <itemid>
#   ?guildbank revoke <name>    - revoke ALL item grants for player
#   ?guildbank withdraw <itemid> [amount_or_charges]
#   ?guildbank withdrawpp       - withdraw ALL bank platinum
#
# Leader only:
#   ?guildbank promote <name>   - give guild-bank officer status
#   ?guildbank demote <name>    - remove guild-bank officer status
#
# Data bucket key = "guildbank:<SANITIZED_GUILD_NAME>"
# Data structure:
#   {
#     pp       => INT total platinum,
#     items    => {
#       itemid => {
#         name    => STR,
#         entries => {
#           charges => { count => INT, charges => INT },
#         },
#       },
#       ...
#     },
#     grants   => { UPPER_PLAYERNAME => { itemid => { persist => 0|1 }, ... }, ... },
#     officers => { UPPER_PLAYERNAME => 1, ... },
#     logs     => [ { ts, player, type, msg }, ... ],
#   }
# -----------------------------------------------------

our $GUILDBANK_PREFIX        = 'guildbank:';  # by guild name
our $GUILDBANK_LOG_MAX       = 200;          # cap logs
our $GUILDBANK_LEADER_MAXRANK = 1;           # treat ranks 0..1 as guild leaders
our $GUILDBANK_DEBUG         = 0;            # set to 1 to enable debug

# -----------------------------------------------------
# Debug helpers
# -----------------------------------------------------
sub _gb_debug_zone {
    return unless $GUILDBANK_DEBUG;
    my ($msg) = @_;
    quest::debug("[guildbank] $msg");
}

sub _gb_debug_client {
    return unless $GUILDBANK_DEBUG;
    my ($client, $msg) = @_;
    return unless $client;
    $client->Message(15, "[GBANK DEBUG] $msg");
}

# -----------------------------------------------------
# Entry point
# -----------------------------------------------------
sub guildbank_handle_say {
    my ($client, $text, $entity_list) = @_;
    return 0 unless $client;
    return 0 unless defined $text;

    # Only care about ?donate / ?guildbank
    return 0 unless $text =~ /^\?(donate|guildbank)\b/i;

    my $guild_id = $client->GuildID();
    if (!$guild_id) {
        $client->Message(13, "You must be in a guild to use the guild bank.");
        return 1;
    }

    my $guild_name = quest::getguildnamebyid($guild_id) || "Guild$guild_id";
    my $key        = _gb_key_for_guild($guild_name);
    my $bank       = _gb_load_bank($key);
    my $role       = _gb_role_for_client($client, $bank);  # leader/officer/member/none

    my ($root, @rest) = split(/\s+/, $text);

    my $dirty = 0;  # whether we modified bank data

    if (lc $root eq '?donate') {
        # ?donate OR ?donate <pp>
        my $pp_arg = 0;
        if (@rest && $rest[0] =~ /^(\d+)$/) {
            $pp_arg = $1;
        }
        $dirty ||= _gb_handle_donate($client, $bank, $pp_arg);
    }
    elsif (lc $root eq '?guildbank') {
        my $sub = lc(shift(@rest) || 'show');

        if    ($sub eq 'show')      { _gb_show_bank($client, $bank, $role); }
        elsif ($sub eq 'logs')      { _gb_show_logs($client, $bank); }
        elsif ($sub eq 'grant')     { $dirty ||= _gb_cmd_grant($client, $bank, $role, $entity_list, @rest); }
        elsif ($sub eq 'revoke')    { $dirty ||= _gb_cmd_revoke($client, $bank, $role, $entity_list, @rest); }
        elsif ($sub eq 'promote')   { $dirty ||= _gb_cmd_promote($client, $bank, $role, $entity_list, @rest); }
        elsif ($sub eq 'demote')    { $dirty ||= _gb_cmd_demote($client, $bank, $role, $entity_list, @rest); }
        elsif ($sub eq 'withdraw')  { $dirty ||= _gb_cmd_withdraw_item($client, $bank, $role, @rest); }
        elsif ($sub eq 'withdrawpp'){ $dirty ||= _gb_cmd_withdraw_pp($client, $bank, $role); }
        else                        { _gb_show_help($client, $role); }
    }

    # Save bank if changed
    if ($dirty) {
        _gb_save_bank($key, $bank);
    }

    return 1;  # handled
}

# -----------------------------------------------------
# Key + load/save helpers
# -----------------------------------------------------
sub _gb_key_for_guild {
    my ($guild_name) = @_;
    $guild_name ||= 'UNKNOWN';
    $guild_name =~ s/\s+/_/g;
    $guild_name =~ s/[^A-Za-z0-9_]/_/g;
    return $GUILDBANK_PREFIX . uc($guild_name);
}

sub _gb_load_bank {
    my ($key) = @_;
    my $raw = quest::get_data($key);

    my $data;

    if (defined $raw && $raw ne '') {
        my $ok = eval { $data = decode_json($raw); 1 };
        if (!$ok) {
            _gb_debug_zone("failed to decode JSON for '$key': $@");
            $data = undef;
        }
    }

    $data ||= {
        pp       => 0,
        items    => {},
        grants   => {},
        officers => {},
        logs     => [],
    };

    # Enforce structure
    $data->{pp}       = 0        unless defined $data->{pp};
    $data->{items}    = {}       unless ref($data->{items})    eq 'HASH';
    $data->{grants}   = {}       unless ref($data->{grants})   eq 'HASH';
    $data->{officers} = {}       unless ref($data->{officers}) eq 'HASH';
    $data->{logs}     = []       unless ref($data->{logs})     eq 'ARRAY';
	$data->{global_grant_all} = 0 unless defined $data->{global_grant_all};
	
    my $icount = scalar keys %{ $data->{items} };
    _gb_debug_zone("load '$key' pp=$data->{pp} items=$icount");

    return $data;
}

sub _gb_save_bank {
    my ($key, $bank) = @_;

    my $icount = scalar keys %{ $bank->{items} || {} };
    my $pp     = $bank->{pp} || 0;

    my $json = encode_json($bank);

    # 10-year expiration (in seconds) to be safe
    my $ten_years = 10 * 365 * 24 * 60 * 60;  # 315360000

    quest::set_data($key, $json, $ten_years);

    _gb_debug_zone("save key='$key' pp=$pp items=$icount len=" . length($json));
}

# -----------------------------------------------------
# Role helper
#   leader  = guild ranks 0..$GUILDBANK_LEADER_MAXRANK
#   officer = stored in bank.officers
#   member  = everyone else in guild
# -----------------------------------------------------
sub _gb_role_for_client {
    my ($client, $bank) = @_;
    return 'none' unless $client;

    my $gid   = $client->GuildID();
    my $rank  = $client->GuildRank();          # server-specific
    my $uname = uc $client->GetCleanName();

    # If not in a guild at all, hard 'none'
    if (!$gid) {
        _gb_debug_client($client,
            "gid=$gid rank=" . (defined $rank ? $rank : 'undef') . " -> role=none (no guild)");
        return 'none';
    }

    my $role = 'member';

    if (defined $rank && $rank >= 0 && $rank <= $GUILDBANK_LEADER_MAXRANK) {
        $role = 'leader';
    }
    elsif ($bank->{officers}{$uname}) {
        $role = 'officer';
    }

    _gb_debug_client(
        $client,
        "gid=$gid rank=" . (defined $rank ? $rank : 'undef') . " uname=$uname -> role=$role"
    );

    return $role;
}

# -----------------------------------------------------
# Helper: find a player's grant hash (case-insensitive)
# Returns: ($key_used, $grants_hashref) or (undef, undef)
# -----------------------------------------------------
sub _gb_user_grants {
    my ($bank, $uname) = @_;
    my $grants = $bank->{grants} || {};

    # Exact match first
    if (exists $grants->{$uname} && ref($grants->{$uname}) eq 'HASH') {
        return ($uname, $grants->{$uname});
    }

    # Fallback: case-insensitive match (for any older or weirdly-cased keys)
    foreach my $k (keys %$grants) {
        next unless defined $k;
        if (uc($k) eq $uname && ref($grants->{$k}) eq 'HASH') {
            return ($k, $grants->{$k});
        }
    }

    return (undef, undef);
}

sub _gb_can_withdraw_item {
    my ($client, $bank, $role, $itemid) = @_;
    return 0 unless $client;
    return 0 unless $client->GuildID();

    my $uname = uc $client->GetCleanName();

    # Leader/Officer: always full rights
    return 1 if $role eq 'leader' || $role eq 'officer';
	
	# Global grant-all mode: all members may withdraw any item
    if ($bank->{global_grant_all}) {
        return 1;
    }
	
    # Members: must have a grant for this item
    my (undef, $g_user) = _gb_user_grants($bank, $uname);
    return 0 unless $g_user && ref($g_user) eq 'HASH';

    my $gref = $g_user->{$itemid};
    return 0 unless defined $gref;

    # If it's a simple scalar, any truthy value is a grant
    return 1 if !ref($gref) && $gref;

    # If it's a hash, any presence is enough for "can withdraw"
    return 1 if ref($gref) eq 'HASH';

    return 0;
}

sub _gb_maybe_consume_grant {
    my ($client, $bank, $role, $itemid) = @_;
    return unless $client;
    return unless $client->GuildID();

    my $uname = uc $client->GetCleanName();

    # Leaders/Officers don't rely on grants; don't touch their grants here
    return if $role eq 'leader' || $role eq 'officer';
	
	# In global mode, we don't consume any per-player grants
    return if $bank->{global_grant_all};
	
    my ($grant_key, $g_user) = _gb_user_grants($bank, $uname);
    return unless $grant_key && $g_user && ref($g_user) eq 'HASH';

    my $gref = $g_user->{$itemid};
    return unless defined $gref;

    # Hash grants: respect persist flag
    if (ref($gref) eq 'HASH') {
        return if $gref->{persist};  # persistent grant: do not clear
        # otherwise treat as one-time
    }

    # Scalar or non-persist hash → one-time: clear it
    delete $bank->{grants}{$grant_key}{$itemid};
    delete $bank->{grants}{$grant_key} unless keys %{ $bank->{grants}{$grant_key} || {} };

    my $iname = _gb_item_name($itemid);
    $client->Message(15, "[GuildBank] Your withdraw rights for $iname (ID $itemid) have been used.");
}

# -----------------------------------------------------
# Item name helper (DB lookup from items table)
# -----------------------------------------------------
our %GUILDBANK_ITEMNAME_CACHE;

sub _gb_item_name {
    my ($itemid) = @_;
    return "Item#$itemid" unless $itemid;

    # Simple cache to avoid hammering DB
    return $GUILDBANK_ITEMNAME_CACHE{$itemid}
        if exists $GUILDBANK_ITEMNAME_CACHE{$itemid};

    my $name = '';

    my $dbh = plugin::LoadMysql();
    if ($dbh) {
        my $sth = $dbh->prepare("SELECT Name FROM items WHERE id = ? LIMIT 1");
        if ($sth) {
            $sth->execute($itemid);
            ($name) = $sth->fetchrow_array();
            $sth->finish();
        }
    }

    $name ||= "Item#$itemid";
    $GUILDBANK_ITEMNAME_CACHE{$itemid} = $name;

    return $name;
}

# -----------------------------------------------------
# Item stack/charge helper
#   Returns: (stacksize, maxcharges)
# -----------------------------------------------------
sub _gb_item_stackinfo {
    my ($itemid) = @_;
    my ($stacksize, $maxcharges) = (0, 0);

    my $dbh = plugin::LoadMysql();
    if ($dbh) {
        my $sth = $dbh->prepare("SELECT stacksize, maxcharges FROM items WHERE id = ? LIMIT 1");
        if ($sth) {
            $sth->execute($itemid);
            ($stacksize, $maxcharges) = $sth->fetchrow_array();
            $sth->finish();
        }
    }

    $stacksize  ||= 0;
    $maxcharges ||= 0;
    return ($stacksize, $maxcharges);
}

# -----------------------------------------------------
# Donate logic
#   - If item on cursor: donate that stack / item
#   - If pp_arg > 0: donate that many PP from wallet
# -----------------------------------------------------
sub _gb_handle_donate {
    my ($client, $bank, $pp_arg) = @_;

    my $changed = 0;

    # -----------------------
    # 1) Item on cursor
    # -----------------------
    my $cursor_slot = quest::getinventoryslotid("cursor");
    my $cinst       = eval { $client->GetItemAt($cursor_slot) };

    if ($cinst) {
        my $itemid = $cinst->GetID();
        my ($stacksize, $maxcharges) = _gb_item_stackinfo($itemid);

        my $items = $bank->{items};
        my $rec   = $items->{$itemid} ||= {
            name    => _gb_item_name($itemid),
            entries => {},              # charges -> { count, charges }
        };
        $rec->{entries} ||= {};

        if ($stacksize && $stacksize > 1) {
            # Stackable item: treat GetCharges() as "units in this stack"
            my $units = $cinst->GetCharges();
            $units = 1 if !$units || $units < 1;

            my $e = $rec->{entries}{0} ||= {
                count   => 0,
                charges => 0,           # "no charges", stackable
            };
            $e->{count} += $units;

            $client->Message(15, "You donate $units x $rec->{name} to the guild bank.");
            _gb_log($bank, $client, 'donate_item', {
                item_id   => $itemid,
                item_name => $rec->{name},
                amount    => $units,
            });
        }
        else {
            # Non-stack item (gear or charged clickies):
            # Donate this *one* item; track by its current charges
            my $charges = $cinst->GetCharges();
            $charges = 0 if !defined $charges || $charges < 0;

            my $e = $rec->{entries}{$charges} ||= {
                count   => 0,
                charges => $charges,
            };
            $e->{count} += 1;

            $client->Message(
                15,
                "You donate 1 x $rec->{name} (Charges: $charges) to the guild bank."
            );
            _gb_log($bank, $client, 'donate_item', {
                item_id   => $itemid,
                item_name => $rec->{name},
                amount    => 1,
            });
        }

        # Remove the item from cursor (all charges in that slot)
        $client->DeleteItemInInventory($cursor_slot, 0, 1);

        $changed = 1;
    }
    else {
        my $cursor_id = $client->GetItemIDAt($cursor_slot);
        _gb_debug_client(
            $client,
            "no item instance at cursor (slot=$cursor_slot, id=" . ($cursor_id // 0) . ")"
        );
    }

    # -----------------------
    # 2) Platinum donation
    # -----------------------
    if ($pp_arg && $pp_arg > 0) {
        my $copper = $pp_arg * 1000;   # 1pp = 1000c
        $client->TakeMoneyFromPP($copper, 1);

        $bank->{pp} ||= 0;
        $bank->{pp} += $pp_arg;

        $client->Message(15, "You donate $pp_arg platinum to the guild bank.");
        _gb_log($bank, $client, 'donate_pp', { pp => $pp_arg });

        $changed = 1;
    }

    # -----------------------
    # 3) Help text if nothing donated
    # -----------------------
    if (!$changed) {
        $client->Message(15, "To donate: put an item on your cursor and say ?donate,");
        $client->Message(15, "or say ?donate <pp> to donate platinum from your wallet.");
    }

    return $changed;
}

# -----------------------------------------------------
# View bank (member / officer / leader)
# -----------------------------------------------------
sub _gb_show_bank {
    my ($client, $bank, $role) = @_;

    my $gname = quest::getguildnamebyid($client->GuildID()) || 'your guild';
    my $items = $bank->{items} || {};

    # Upgrade any old flat records to "entries" format
    foreach my $iid (keys %$items) {
        my $rec = $items->{$iid} || next;

        if (!exists $rec->{entries}) {
            my $count = $rec->{count} || 0;
            my $name  = $rec->{name}  || _gb_item_name($iid);

            $rec->{name}    = $name;
            $rec->{entries} = {};
            if ($count > 0) {
                $rec->{entries}{0} = {
                    count   => $count,
                    charges => 0,
                };
            }
            delete $rec->{count};
        }
    }

    # Normalize: drop zero-count entries and fix names
    foreach my $iid (keys %$items) {
        my $rec = $items->{$iid} || next;
        my $entries = $rec->{entries} || {};

        foreach my $ch (keys %$entries) {
            my $e = $entries->{$ch} || next;
            my $count = $e->{count} || 0;
            if ($count <= 0) {
                delete $entries->{$ch};
                next;
            }

            # Ensure "charges" is set
            $e->{charges} = $ch unless defined $e->{charges};
        }

        # Drop items with no valid entries
        if (!keys %$entries) {
            delete $items->{$iid};
            next;
        }

        # Ensure item name is valid
        $rec->{name} ||= _gb_item_name($iid);
    }

    my $pp = $bank->{pp} || 0;

    $client->Message(15, "===== Guild Bank for $gname =====");

    # Build display list
    my @display;

    foreach my $iid (keys %$items) {
        my $rec = $items->{$iid} || next;
        my $name = $rec->{name} || _gb_item_name($iid);
        my $entries = $rec->{entries} || {};

        my ($stacksize, $maxcharges) = _gb_item_stackinfo($iid);
        my $is_stackable = ($stacksize && $stacksize > 1) ? 1 : 0;

        foreach my $ch (keys %$entries) {
            my $e = $entries->{$ch} || next;
            my $count = $e->{count} || 0;
            next if $count <= 0;

            push @display, {
                id           => $iid,
                name         => $name,
                count        => $count,
                charges      => $ch,
                is_stackable => $is_stackable,
            };
        }
    }

    if (!@display && !$pp) {
        $client->Message(15, "  (The guild bank is currently empty.)");
        _gb_show_help($client, $role);
        return;
    }

    # Sort by item name (case-insensitive), then by item ID, then charges
    @display = sort {
        lc($a->{name}) cmp lc($b->{name}) ||
        $a->{id}       <=> $b->{id}       ||
        $a->{charges}  <=> $b->{charges}
    } @display;

    # Render rows
    foreach my $e (@display) {
        my $itemid       = $e->{id};
        my $name         = $e->{name};
        my $count        = $e->{count};
        my $charges      = $e->{charges};
        my $is_stackable = $e->{is_stackable};

        my $link = quest::varlink($itemid);

        my $charges_txt;
        if ($is_stackable) {
            $charges_txt = "stackable";
        } else {
            $charges_txt = $charges;
        }

        my $line = sprintf("  %s x%d (Charges: %s)", $link, $count, $charges_txt);

        my $can_withdraw = _gb_can_withdraw_item($client, $bank, $role, $itemid);
        if ($can_withdraw) {
            if ($is_stackable) {
                # Withdraw 1 and 20 units
                my $w1  = quest::saylink("?guildbank withdraw $itemid 1",  1, "[Withdraw 1]");
                my $w20 = quest::saylink("?guildbank withdraw $itemid 20", 1, "[Withdraw 20]");
                $line .= " $w1 $w20";
            } else {
                # Non-stack, per-charge row: pass charges so we know which pool to pull from
                my $w = quest::saylink("?guildbank withdraw $itemid $charges", 1, "[Withdraw]");
                $line .= " $w";
            }
        }

        # Officers/leaders see ID
        if ($role ne 'member') {
            $line .= " (ID $itemid)";
        }

        $client->Message(15, $line);
    }

    $client->Message(15, sprintf("Total platinum in guild bank: %d", $pp));
    if ($pp > 0 && $role ne 'member') {
        my $plink = quest::saylink("?guildbank withdrawpp", 1, "[Withdraw All PP]");
        $client->Message(15, "  $plink");
    }

    _gb_show_help($client, $role);
}

# -----------------------------------------------------
# Help text
# -----------------------------------------------------
sub _gb_show_help {
    my ($client, $role) = @_;
    $client->Message(15, "----- Guild Bank Commands -----");
    $client->Message(15, " ?donate                 - Donate item on cursor");
    $client->Message(15, " ?donate <pp>           - Donate that much platinum");
    $client->Message(15, " ?guildbank              - View guild bank");
    $client->Message(15, " ?guildbank logs         - View recent withdraw logs");
    if ($role eq 'officer' || $role eq 'leader') {
        $client->Message(15, " ?guildbank grant <name> <itemid> [persist]");
        $client->Message(15, "    (omit 'persist' for a one-time grant that is used up on withdraw)");
        $client->Message(15, " ?guildbank revoke <name> [itemid]");
        $client->Message(15, " ?guildbank withdraw <itemid> [amount]");
        $client->Message(15, " ?guildbank withdrawpp       (all platinum)");
    }
    if ($role eq 'leader') {
        $client->Message(15, " ?guildbank grant all persist  (allow ALL members to withdraw any item)");
        $client->Message(15, " ?guildbank revoke all         (turn off global access)");
        $client->Message(15, " ?guildbank promote <name>     (guild-bank officer)");
        $client->Message(15, " ?guildbank demote <name>      (remove officer)");
    }
}

# -----------------------------------------------------
# Logs
# -----------------------------------------------------
sub _gb_log {
    my ($bank, $client, $type, $info) = @_;
    $bank->{logs} ||= [];
    my $logs = $bank->{logs};

    my $name = $client ? $client->GetCleanName() : 'Unknown';
    my $msg;

    if ($type eq 'withdraw_item') {
        $msg = sprintf("withdrew %d x %s (ID %d)",
            $info->{amount} || 0,
            $info->{item_name} || "Item#$info->{item_id}",
            $info->{item_id}  || 0
        );
    }
    elsif ($type eq 'withdraw_pp') {
        $msg = sprintf("withdrew %d platinum", $info->{pp} || 0);
    }
    elsif ($type eq 'donate_item') {
        $msg = sprintf("donated %d x %s (ID %d)",
            $info->{amount} || 0,
            $info->{item_name} || "Item#$info->{item_id}",
            $info->{item_id}  || 0
        );
    }
    elsif ($type eq 'donate_pp') {
        $msg = sprintf("donated %d platinum", $info->{pp} || 0);
    }
    else {
        $msg = $info->{msg} || $type;
    }

    my $entry = {
        ts     => scalar localtime(),
        player => $name,
        type   => $type,
        msg    => $msg,
    };

    push @$logs, $entry;
    # Trim oldest if too many
    while (@$logs > $GUILDBANK_LOG_MAX) {
        shift @$logs;
    }
}

sub _gb_show_logs {
    my ($client, $bank) = @_;
    my $logs = $bank->{logs} || [];
    if (!@$logs) {
        $client->Message(15, "Guild bank has no logs yet.");
        return;
    }

    my $max   = 30;
    my $total = scalar @$logs;
    my $start = $total > $max ? $total - $max : 0;

    $client->Message(15, "===== Recent Guild Bank Logs (newest last) =====");

    for (my $i = $start; $i < $total; ++$i) {
        my $e = $logs->[$i];
        my $line = sprintf("[%s] %s %s",
            $e->{ts}     || '',
            $e->{player} || '',
            $e->{msg}    || '',
        );
        $client->Message(15, $line);
    }
}

# -----------------------------------------------------
# Grant / revoke
# -----------------------------------------------------
sub _gb_cmd_grant {
    my ($client, $bank, $role, $entity_list, @args) = @_;

    if ($role ne 'leader' && $role ne 'officer') {
        $client->Message(13, "Only guild-bank officers or guild leaders can grant withdraw rights.");
        return 0;
    }

    if (!@args) {
        $client->Message(13, "Usage: ?guildbank grant <playername> <itemid> [persist]");
        $client->Message(13, "        ?guildbank grant all persist   (global access)");
        return 0;
    }

    my $persist = 0;
    # Optional trailing "persist"
    if (@args && lc($args[-1]) eq 'persist') {
        $persist = 1;
        pop @args;
    }

    my ($name, $itemid) = @args;

    # --- NEW: global 'all' grant (leader only) ---
    if (defined $name && lc($name) eq 'all' && !defined $itemid) {
        if ($role ne 'leader') {
            $client->Message(13, "Only the guild leader can grant global guild bank access.");
            return 0;
        }

        # We don't really care about 'persist' here; global is always "on until revoked"
        $bank->{global_grant_all} = 1;
        $client->Message(15, "Global guild bank access enabled: all guild members may now withdraw any item.");
        return 1;
    }
    # --------------------------------------------

    if (!$name || !$itemid || $itemid !~ /^\d+$/) {
        $client->Message(13, "Usage: ?guildbank grant <playername> <itemid> [persist]");
        return 0;
    }

    my ($uname, $tcli) = _gb_resolve_guild_member($client, $entity_list, $name);
    unless ($uname) {
        $client->Message(13, "Player '$name' must be in your guild.");
        return 0;
    }

    $bank->{grants}{$uname} ||= {};
    $bank->{grants}{$uname}{$itemid} = { persist => ($persist ? 1 : 0) };

    my $iname = _gb_item_name($itemid);
    if ($persist) {
        $client->Message(15, "Granted *persistent* withdraw rights for $iname (ID $itemid) to $uname.");
        $tcli->Message(15, "You have been granted persistent guild bank withdraw rights for $iname (ID $itemid).")
            if $tcli;
    } else {
        $client->Message(15, "Granted one-time withdraw rights for $iname (ID $itemid) to $uname.");
        $tcli->Message(15, "You have been granted one-time guild bank withdraw rights for $iname (ID $itemid). It will be used up on withdraw.")
            if $tcli;
    }

    return 1;
}

sub _gb_cmd_revoke {
    my ($client, $bank, $role, $entity_list, @args) = @_;

    if ($role ne 'leader' && $role ne 'officer') {
        $client->Message(13, "Only guild-bank officers or guild leaders can revoke withdraw rights.");
        return 0;
    }

    my ($name, $itemid) = @args;
    if (!$name) {
        $client->Message(13, "Usage: ?guildbank revoke <playername> [itemid]");
        $client->Message(13, "        ?guildbank revoke all         (turn off global access)");
        return 0;
    }

    # --- NEW: global revoke-all (leader only) ---
    if (lc($name) eq 'all' && !$itemid) {
        if ($role ne 'leader') {
            $client->Message(13, "Only the guild leader can revoke global guild bank access.");
            return 0;
        }

        $bank->{global_grant_all} = 0;
        $client->Message(15, "Global guild bank access has been revoked. Members now require normal grants again.");
        return 1;
    }
    # -------------------------------------------

    my ($uname, $tcli) = _gb_resolve_guild_member($client, $entity_list, $name);
    unless ($uname) {
        $client->Message(13, "Player '$name' must be in your guild.");
        return 0;
    }

    if ($itemid && $itemid =~ /^\d+$/) {
        delete $bank->{grants}{$uname}{$itemid};
        delete $bank->{grants}{$uname} unless keys %{ $bank->{grants}{$uname} || {} };

        $client->Message(15, "Revoked withdraw rights for item ID $itemid from $uname.");
        $tcli->Message(15, "Your guild bank withdraw rights for item ID $itemid have been revoked.")
            if $tcli;
    }
    else {
        delete $bank->{grants}{$uname};
        $client->Message(15, "Revoked ALL guild bank withdraw rights from $uname.");
        $tcli->Message(15, "All your guild bank withdraw rights have been revoked.")
            if $tcli;
    }

    return 1;
}

# -----------------------------------------------------
# Promote / demote officers (leader only)
# -----------------------------------------------------
sub _gb_cmd_promote {
    my ($client, $bank, $role, $entity_list, @args) = @_;

    if ($role ne 'leader') {
        $client->Message(13, "Only the guild leader can promote guild-bank officers.");
        return 0;
    }

    my ($name) = @args;
    if (!$name) {
        $client->Message(13, "Usage: ?guildbank promote <playername>");
        return 0;
    }

    my ($uname, $tcli) = _gb_resolve_guild_member($client, $entity_list, $name);
    unless ($uname) {
        $client->Message(13, "Player '$name' must be in your guild.");
        return 0;
    }

    $bank->{officers}{$uname} = 1;

    $client->Message(15, "$uname is now a guild-bank officer.");
    $tcli->Message(15, "You have been promoted to guild-bank officer.")
        if $tcli;

    return 1;
}

sub _gb_cmd_demote {
    my ($client, $bank, $role, $entity_list, @args) = @_;

    if ($role ne 'leader') {
        $client->Message(13, "Only the guild leader can demote guild-bank officers.");
        return 0;
    }

    my ($name) = @args;
    if (!$name) {
        $client->Message(13, "Usage: ?guildbank demote <playername>");
        return 0;
    }

    my ($uname, $tcli) = _gb_resolve_guild_member($client, $entity_list, $name);
    unless ($uname) {
        $client->Message(13, "Player '$name' must be in your guild.");
        return 0;
    }

    delete $bank->{officers}{$uname};

    $client->Message(15, "$uname is no longer a guild-bank officer.");
    $tcli->Message(15, "You have been demoted from guild-bank officer.")
        if $tcli;

    return 1;
}

# -----------------------------------------------------
# Withdraw item
# -----------------------------------------------------
sub _gb_cmd_withdraw_item {
    my ($client, $bank, $role, @args) = @_;

    my ($itemid, $arg2) = @args;
    if (!$itemid || $itemid !~ /^\d+$/) {
        $client->Message(13, "Usage: ?guildbank withdraw <itemid> [amount_or_charges]");
        return 0;
    }

    my ($stacksize, $maxcharges) = _gb_item_stackinfo($itemid);
    my $items = $bank->{items} || {};
    my $rec   = $items->{$itemid};

    if (!$rec) {
        $client->Message(13, "The guild bank does not have that item.");
        return 0;
    }

    # Ensure entries structure exists (upgrade old data if necessary)
    if (!exists $rec->{entries}) {
        my $count = $rec->{count} || 0;
        $rec->{name}    ||= _gb_item_name($itemid);
        $rec->{entries} ||= {};
        if ($count > 0) {
            $rec->{entries}{0} = { count => $count, charges => 0 };
        }
        delete $rec->{count};
    }

    my $entries = $rec->{entries} || {};

    # Check permission
    unless (_gb_can_withdraw_item($client, $bank, $role, $itemid)) {
        $client->Message(13, "You are not authorized to withdraw that item from the guild bank.");
        return 0;
    }

    my $iname = $rec->{name} || _gb_item_name($itemid);

    if ($stacksize && $stacksize > 1) {
        # Stackable item: arg2 is amount to withdraw (default 1)
        my $amount = $arg2 || 1;
        my $e      = $entries->{0} || {};
        my $avail  = $e->{count} || 0;

        if ($avail < $amount) {
            $client->Message(13, "The guild bank does not have enough of that item.");
            return 0;
        }

        $e->{count} -= $amount;
        if ($e->{count} <= 0) {
            delete $entries->{0};
        }
        if (!keys %$entries) {
            delete $items->{$itemid};
        }

        quest::summonitem($itemid, $amount);

        $client->Message(15, "You withdraw $amount x $iname (ID $itemid) from the guild bank.");
        _gb_log($bank, $client, 'withdraw_item', {
            item_id   => $itemid,
            item_name => $iname,
            amount    => $amount,
        });

        _gb_maybe_consume_grant($client, $bank, $role, $itemid);
        return 1;
    }
    else {
        # Non-stack item: arg2 is charges bucket; default 0
        my $charges = defined $arg2 ? int($arg2) : 0;
        my $e       = $entries->{$charges};

        if (!$e || ($e->{count} || 0) < 1) {
            $client->Message(13, "The guild bank does not have that item with those charges.");
            return 0;
        }

        $e->{count} -= 1;
        if ($e->{count} <= 0) {
            delete $entries->{$charges};
        }
        if (!keys %$entries) {
            delete $items->{$itemid};
        }

        # For charged items, charges > 0 → pass that to summonitem
        if ($charges > 0) {
            quest::summonitem($itemid, $charges);
        } else {
            quest::summonitem($itemid);
        }

        $client->Message(
            15,
            "You withdraw 1 x $iname (ID $itemid, Charges: $charges) from the guild bank."
        );
        _gb_log($bank, $client, 'withdraw_item', {
            item_id   => $itemid,
            item_name => $iname,
            amount    => 1,
        });

        _gb_maybe_consume_grant($client, $bank, $role, $itemid);
        return 1;
    }
}

# -----------------------------------------------------
# Withdraw platinum (ALL)
# -----------------------------------------------------
sub _gb_cmd_withdraw_pp {
    my ($client, $bank, $role) = @_;

    # Only leader/officer can pull PP
    if ($role eq 'member' || $role eq 'none') {
        $client->Message(13, "Only guild-bank officers or guild leaders can withdraw platinum.");
        return 0;
    }

    my $pp = $bank->{pp} || 0;
    if ($pp <= 0) {
        $client->Message(13, "There is no platinum in the guild bank.");
        return 0;
    }

    quest::givecash(0, 0, 0, $pp);
    $bank->{pp} = 0;

    $client->Message(15, "You withdraw $pp platinum from the guild bank.");

    _gb_log($bank, $client, 'withdraw_pp', { pp => $pp });

    return 1;
}

# -----------------------------------------------------
# Find client by name, ensure same guild
# -----------------------------------------------------
# Resolve a guild member by name:
# - Checks same-zone client first
# - Falls back to DB (character_data + guild_members) so offline / other-zone still works
# Returns: (UPPER_NAME, $client_or_undef) or () on failure
sub _gb_resolve_guild_member {
    my ($client, $entity_list, $name) = @_;
    return unless $client;
    return unless defined $name;

    my $gid = $client->GuildID();
    return unless $gid;  # caller must be in a guild

    # normalize name a bit
    $name =~ s/^\s+|\s+$//g;
    return unless length $name;

    # 1) Try live client in THIS zone
    my $tcli = $entity_list->GetClientByName($name);
    if ($tcli && $tcli->GuildID() && $tcli->GuildID() == $gid) {
        my $canon = $tcli->GetCleanName();
        my $uname = uc $canon;
        return ($uname, $tcli);
    }

    # 2) Fallback to DB lookup (offline or other zone)
    my $qname = $name;
    $qname =~ s/[^A-Za-z0-9_'\-]//g;

    my $dbh = plugin::LoadMysql();
    return unless $dbh;

    # character_data.id <-> guild_members.char_id, guild_members.guild_id = ?
    my $sql = q{
        SELECT c.name
        FROM character_data AS c
        JOIN guild_members AS gm ON gm.char_id = c.id
        WHERE c.name = ? AND gm.guild_id = ?
        LIMIT 1
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute($qname, $gid);
    my ($db_name) = $sth->fetchrow_array();
    $sth->finish();

    return unless $db_name;  # not found or not in this guild

    my $uname = uc $db_name;
    return ($uname, undef);  # no live client handle, but we have canonical name
}

1;

