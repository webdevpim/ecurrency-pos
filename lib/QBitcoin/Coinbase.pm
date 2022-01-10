package QBitcoin::Coinbase;
use warnings;
use strict;
use feature 'state';

use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::ORM qw(:types dbh find for_log DEBUG_ORM);
use QBitcoin::Crypto qw(hash256);
use QBitcoin::ProtocolState qw(btc_synced);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::RedeemScript;
use Bitcoin::Serialized;
use Bitcoin::Transaction;
use Bitcoin::Block;

use constant TABLE => 'coinbase';

use constant FIELDS => {
    btc_block_height => NUMERIC,
    btc_tx_num       => NUMERIC,
    btc_out_num      => NUMERIC,
    btc_tx_hash      => BINARY,
    btc_tx_data      => BINARY,
    merkle_path      => BINARY,
    value            => NUMERIC,
    scripthash       => NUMERIC,
    tx_out           => NUMERIC,
};

mk_accessors(keys %{&FIELDS});
mk_accessors(qw(tx_hash));

my %COINBASE; # just short-live cache for recently produced entries

sub store {
    my $self = shift;
    my $class = ref $self;
    my ($coinbase) = $class->find(
        btc_block_height => $self->btc_block_height,
        btc_tx_num       => $self->btc_tx_num,
        btc_out_num      => $self->btc_out_num,
    );
    return if $coinbase;
    my $scripthash = QBitcoin::RedeemScript->store($self->scripthash);
    my $sql = "INSERT INTO `" . TABLE . "` (btc_block_height, btc_tx_num, btc_out_num, btc_tx_hash, btc_tx_data, merkle_path, value, scripthash, tx_out) VALUES (?,?,?,?,?,?,?,?,NULL)";
    DEBUG_ORM && Debugf("dbi [%s] values [%u,%u,%u,%s,%s,%s,%lu,%u]", $sql, $self->btc_block_height, $self->btc_tx_num, $self->btc_out_num, for_log($self->btc_tx_hash), for_log($self->btc_tx_data), for_log($self->merkle_path), $self->value, $scripthash->id);
    my $res = dbh->do($sql, undef, $self->btc_block_height, $self->btc_tx_num, $self->btc_out_num, $self->btc_tx_hash, $self->btc_tx_data, $self->merkle_path, $self->value, $scripthash->id);
    $res == 1
        or die "Can't store coinbase " . $self->btc_tx_num . ":" . $self->btc_out_num . ": " . (dbh->errstr // "no error") . "\n";
}

sub store_published {
    my $self = shift;
    my ($tx) = @_;

    my $sql = "UPDATE `" . TABLE . "` SET tx_out = ? WHERE btc_tx_hash = ? AND btc_out_num = ? AND tx_out IS NULL";
    DEBUG_ORM && Debugf("dbi [%s] values [%u,%s,%u]", $sql, $tx->id, for_log($self->btc_tx_hash), $self->btc_out_num);
    my $res = dbh->do($sql, undef, $tx->id, $self->btc_tx_hash, $self->btc_out_num);
    $res == 1
        or die "Can't store coinbase " . for_log($self->btc_tx_hash) . ":" . $self->btc_out_num . " as processed: " . (dbh->errstr // "no error") . "\n";
}

sub get_new {
    my $class = shift;
    my ($time) = @_;

    # We often generate new block for the same timeslot. In this case we do not need find for new coinbase w/o generated transaction
    state $prev_time = -1;
    return () if $prev_time >= $time;
    $prev_time = $time;

    my ($matched_block) = Bitcoin::Block->find(
        time    => { '<' => $time - COINBASE_CONFIRM_TIME },
        -sortby => 'height DESC',
        -limit  => 1,
    );
    return () unless $matched_block;
    my $max_height = $matched_block->height - COINBASE_CONFIRM_BLOCKS;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT btc_block_height, btc_tx_num, btc_out_num, btc_tx_hash, btc_tx_data, merkle_path, value, s.hash as scripthash";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::RedeemScript->TABLE . "` AS s ON (t.scripthash = s.id)";
    $sql .= " WHERE tx_out IS NULL AND btc_block_height <= ?";
    my $sth = dbh->prepare($sql);
    DEBUG_ORM && Debugf("sql: [%s] values [%u]", $sql, $max_height);
    $sth->execute($max_height);
    my @coinbase;
    while (my $hash = $sth->fetchrow_hashref()) {
        my $key = $hash->{btc_tx_hash} . $hash->{btc_out_num};
        next if $COINBASE{$key}; # transaction for this coinbase already generated (but not stored yet)
        my $coinbase = $class->new($hash);
        $COINBASE{$key} = 1;
        push @coinbase, $coinbase;
    }
    DEBUG_ORM && Debugf("sql: found %u coinbase entries", scalar(@coinbase));
    return @coinbase;
}

sub DESTROY {
    my $self = shift;
    # weaken() only undefine value but do not delete it, so do it from the object destructor
    my $key = $self->{btc_tx_hash} . $self->{btc_out_num};
    delete $COINBASE{$key};
}

# Coinbase can be included in only one transaction (unlike txo), so we do not need to build separate singleton cache for coinbase
# save them just as links from related transactions
sub load_stored_coinbase {
    my $class = shift;
    my ($tx_id, $tx_hash) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT btc_block_height, btc_tx_num, btc_out_num, btc_tx_hash, btc_tx_data, merkle_path, value, s.hash as scripthash";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::RedeemScript->TABLE . "` AS s ON (t.scripthash = s.id)";
    $sql .= " WHERE tx_out = ?";
    my $sth = dbh->prepare($sql);
    DEBUG_ORM && Debugf("sql: [%s] values [%u]", $sql, $tx_id);
    $sth->execute($tx_id);
    my $coinbase;
    if (my $hash = $sth->fetchrow_hashref()) {
        DEBUG_ORM && Debug("orm found coinbase");
        $hash->{tx_hash} = $tx_hash;
        $coinbase = $class->new($hash);
    }
    return $coinbase;
}

sub validate {
    my $self = shift;
    my ($btc_block) = Bitcoin::Block->find(hash => $self->btc_block_hash);
    if (!$btc_block) {
        # unset btc_synced() if last btc block older than COINBASE_CONFIRM_TIME
        # otherwise assume this is not correct coinbase
        ($btc_block) = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 1);
        if (!$btc_block || $btc_block->time < time() - COINBASE_CONFIRM_TIME) {
            # TODO: request btc blocks
            btc_synced(0);
            # TODO: set this tx as pending
            Warningf("BTC blockchain not synced, can't validate coinbase");
            return -1;
        }
        Warningf("Incorrect coinbase transaction based on unexistent btc block %s", unpack("H*", $self->btc_block_hash));
        return -1;
    }
    # Check merkle path (but ignore mismatch for produced upgrades)
    if (!$btc_block->check_merkle_path($self->btc_tx_hash, $self->btc_tx_num, $self->merkle_path)) {
        Warningf("Merkle path check failed for btc upgrade transaction %s in block %s",
            unpack("H*", scalar reverse $self->btc_tx_hash), $btc_block->hash_hex);
        return -1;
    }
    $self->{btc_block_height} //= $btc_block->height;

    return 0;
}

sub as_hashref {
    my $self = shift;
    return {
        btc_block_hash => unpack("H*", $self->btc_block_hash),
        btc_tx_num     => $self->btc_tx_num+0,
        btc_out_num    => $self->btc_out_num+0,
        btc_tx_data    => unpack("H*", $self->btc_tx_data),
        merkle_path    => unpack("H*", $self->merkle_path),
        value          => $self->value / DENOMINATOR,
        scripthash     => unpack("H*", $self->scripthash),
    };
}

sub serialize {
    my $self = shift;
    # value and scripthash is matched transaction output and can be fetched from btc_tx_data and btc_out_num
    return $self->btc_block_hash .
        (varint($self->btc_tx_num)  // return undef) .
        (varint($self->btc_out_num) // return undef) .
        (varstr($self->btc_tx_data) // return undef) .
        (varstr($self->merkle_path) // return undef);
}

sub get_scripthash {
    my $class = shift;
    my ($tx, $out_num) = @_;
    my $out = $tx->out->[$out_num];
    if (substr($out->{open_script}, 0, QBT_SCRIPT_START_LEN) eq QBT_SCRIPT_START &&
        length($out->{open_script}) == QBT_SCRIPT_START_LEN + 20) {
        return substr($out->{open_script}, QBT_SCRIPT_START_LEN);
    }
    elsif ($out->{open_script} eq QBT_BURN_SCRIPT) {
        # OK, make scripthash by first input of this transaction
        my $in = $tx->in->[0]
            or return undef;
        my $input_script = $in->{script};
        if (my $witness = $tx->in->[0]->{witness}) {
            if ($input_script eq "" && @$witness == 2 && length($witness->[0]) <= 72 && length($witness->[1]) == 33) {
                # P2WPKH
                return hash160(script_by_pubkey($witness->[1]));
            }
            elsif (@$witness > 1) {
                # P2WSH?
                return hash160($witness->[-1]);
            }
            else {
                return undef;
            }
        }
        elsif ($input_script eq "") {
            return undef;
        }
        # Can we reliable get pubkey or scripthash by the bitcoin input script?
        # In particular, how can we distinguish "push <serialized-script>" for P2SH and "push <pubkeyhash>" for P2PKH without unlock-script?
        # Assume the <serialized-script> is longer than 33 bytes.
        # It's not fully reliable but if somebody tries to deceive this algorithm by creating unusually short script
        # then he will simple lost (burn) his money
        if ($input_script =~ /^([\x41-\x48])(??{ ".{" . ord($1) . "}" })\x21(.{33})\z/) {
            # it's P2PKH: push 72-bytes signature, push 33-bytes pubkey
            return hash160(script_by_pubkey($2));
        }
        elsif ($input_script =~ /^([\x41-\x48])((??{ ".{" . ord($1) . "}" }))\z/) {
            # it's P2PK, push only 72-bytes DER-encoded signature
            # TODO: fetch pubkey from it (?)
            my $signature = $2;
            return undef;
        }
        elsif (0) {
            # BTC and QBT scripts are not fully compatible
            # It should work correctly in most cases, but isn't it better deterministic "never" than "almost always"?
            # P2SH script may contains only pushes, and the last one contains the serialized script
            my $last_push_data;
            while ($input_script ne "") {
                my $first_byte = unpack("C", substr($input_script, 0, 1));
                if ($first_byte > 0 && $first_byte < 0x4c) {
                    $last_push_data = substr($input_script, 0, $first_byte+1, "");
                    substr($last_push_data, 0, 1, "");
                }
                elsif ($first_byte == OP_PUSHDATA1) {
                    my $bytes = unpack("C", substr($input_script, 1, 1));
                    $last_push_data = substr($input_script, 0, $bytes+2, "");
                    substr($last_push_data, 0, 2, "");
                    length($last_push_data) == $bytes or return undef;
                }
                elsif ($first_byte == OP_PUSHDATA2) {
                    my $bytes = unpack("v", substr($input_script, 1, 2));
                    $last_push_data = substr($input_script, 0, $bytes+3, "");
                    substr($last_push_data, 0, 3, "");
                    length($last_push_data) == $bytes or return undef;
                }
                else {
                    return undef;
                }
            }
            return hash160($last_push_data);
        }
    }
    return undef;
}

sub deserialize {
    my $class = shift;
    my ($data) = @_;
    my $btc_block_hash = $data->get(32)   // return undef;
    my $btc_tx_num  = $data->get_varint() // return undef;
    my $btc_out_num = $data->get_varint() // return undef;
    my $btc_tx_data = $data->get_string() // return undef;
    my $merkle_path = $data->get_string() // return undef;
    # Deserialize btc transaction for get upgrade data (value, scripthash)
    my $btc_tx_data_obj = Bitcoin::Serialized->new($btc_tx_data);
    my $transaction = Bitcoin::Transaction->deserialize($btc_tx_data_obj);
    if (!$transaction || $btc_tx_data_obj->length) {
        Warningf("Incorrect btc upgrade transaction data");
        return undef;
    }
    my $out = $transaction->out->[$btc_out_num];
    if (!$out) {
        Warningf("Incorrect btc upgrade transaction data %s, no output %u", $transaction->hash_str, $btc_out_num);
        return undef;
    }
    my $scripthash = $class->get_scripthash($transaction, $btc_out_num);
    if (!$scripthash) {
        Warningf("Incorrect btc upgrade transaction %s output open_script", $transaction->hash_str);
        return undef unless $config->{fake_coinbase};
        $scripthash = ZERO_HASH;
    }

    return $class->new({
        btc_block_hash => $btc_block_hash,
        btc_tx_num     => $btc_tx_num,
        btc_out_num    => $btc_out_num,
        btc_tx_data    => $btc_tx_data,
        btc_tx_hash    => $transaction->hash,
        merkle_path    => $merkle_path,
        value          => $out->{value},
        scripthash     => $scripthash,
    });
}

# for serialize loaded blocks
sub btc_block_hash {
    my $self = shift;
    if (!defined $self->{btc_block_hash}) {
        defined($self->{btc_block_height}) or die "BTC block unknown for coinbase\n";
        my ($btc_block) = Bitcoin::Block->find(height => $self->{btc_block_height});
        $self->{btc_block_hash} = $btc_block->hash if $btc_block;
    }
    return $self->{btc_block_hash};
}

sub btc_confirm_time {
    my $self = shift;
    if (!defined $self->{btc_confirm_time}) {
        Debugf("Get btc_confirm_time for coinbase %s:%u",
            unpack("H*", scalar reverse substr($self->btc_tx_hash, -4)), $self->btc_out_num);
        my ($btc_block) = Bitcoin::Block->find(height => $self->btc_block_height + COINBASE_CONFIRM_BLOCKS);
        return undef unless $btc_block;
        $self->{btc_confirm_time} = $btc_block->time;
    }
    return $self->{btc_confirm_time};
}

sub fee_dst {
    my $self = shift;
    my ($block_start) = @_;

    my $stake_tx;
    if ($block_start->time <= $self->btc_confirm_time - COINBASE_CONFIRM_TIME) {
        # If $block_start is old enough then find stake tx in the branch started from this block
        if (@{$block_start->transactions} && $block_start->transactions->[0]->fee < 0 && @{$block_start->transactions->[0]->in}) {
            $stake_tx = $block_start->transactions->[0];
        }
        my $block = $block_start;
        while ($block->next_block && $block->next_block->time <= $self->btc_confirm_time - COINBASE_CONFIRM_TIME) {
            $block = $block->next_block;
            if (@{$block->transactions} && $block->transactions->[0]->fee < 0 && @{$block->transactions->[0]->in}) {
                $stake_tx = $block->transactions->[0];
            }
        }
        if ($stake_tx) {
            return $stake_tx->out->[0]->scripthash;
        }
    }
    # Try to search dst stake tx within incore blocks
    my $block_class = ref $block_start;
    my $best_block = $block_class->best_block($block_class->max_db_height + 1);
    if ($best_block && $best_block->time <= $self->btc_confirm_time - COINBASE_CONFIRM_TIME && $best_block->height < $block_start->height) {
        if (@{$best_block->transactions} && $best_block->transactions->[0]->fee < 0 && @{$best_block->transactions->[0]->in}) {
            $stake_tx = $best_block->transactions->[0];
        }
        while ($best_block->next_block && $best_block->height < $block_start->height &&
               $best_block->next_block->time <= $self->btc_confirm_time - COINBASE_CONFIRM_TIME) {
            $best_block = $best_block->next_block;
            if (@{$best_block->transactions} && $best_block->transactions->[0]->fee < 0 && @{$best_block->transactions->[0]->in}) {
                $stake_tx = $best_block->transactions->[0];
            }
        }
        if ($stake_tx) {
            return $stake_tx->out->[0]->scripthash;
        }
    }

    # Not in the $block_start branch nor in core blocks, find in the database
    my $block_before = $block_class->find(
        time    => { '<=' => $self->btc_confirm_time - COINBASE_CONFIRM_TIME },
        height  => { '<=' => $block_start->height - 1 },
        -sortby => 'time DESC',
        -limit  => 1,
    )
        or return undef;
    for (my $max_height = $block_before->height + 1;; $max_height = $stake_tx->block_height) {
        $stake_tx = QBitcoin::Transaction->find(
            block_height => { '<' => $max_height },
            fee          => { '<' => 0 },
            -sortby      => 'block_height DESC, block_pos ASC',
            -limit       => 1,
        )
            or return undef; # If there are no suitable recipient for the fee then block validator will take the fee to itself
        # It's possible stake tx without input if the block contains only coinbase and zero-fee tx, ignore them
        if (@{$stake_tx->in}) {
            return $stake_tx->out->[0]->scripthash;
        }
    }
}

sub min_tx_time {
    my $self = shift;
    return COINBASE_CONFIRM_TIME + ($self->btc_confirm_time // return undef);
}

1;
