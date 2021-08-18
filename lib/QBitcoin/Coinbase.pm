package QBitcoin::Coinbase;
use warnings;
use strict;

use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::ORM qw(:types dbh find for_log DEBUG_ORM);
use QBitcoin::Crypto qw(hash256);
use QBitcoin::ProtocolState qw(btc_synced);
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
    open_script      => NUMERIC,
    tx_out           => NUMERIC,
};

mk_accessors(keys %{&FIELDS});
mk_accessors(qw(tx_hash));

sub store {
    my $self = shift;
    my $class = ref $self;
    my ($coinbase) = $class->find(
        btc_block_height => $self->btc_block_height,
        btc_tx_num       => $self->btc_tx_num,
        btc_out_num      => $self->btc_out_num,
    );
    return if $coinbase;
    my $script = QBitcoin::OpenScript->store($self->open_script);
    my $sql = "INSERT INTO `" . TABLE . "` (btc_block_height, btc_tx_num, btc_out_num, btc_tx_hash, btc_tx_data, merkle_path, value, open_script, tx_out) VALUES (?,?,?,?,?,?,?,?,NULL)";
    DEBUG_ORM && Debugf("dbi [%s] values [%u,%u,%u,%s,%s,%s,%lu,%u]", $sql, $self->btc_block_height, $self->btc_tx_num, $self->btc_out_num, for_log($self->btc_tx_hash), for_log($self->btc_tx_data), for_log($self->merkle_path), $self->value, $script->id);
    my $res = dbh->do($sql, undef, $self->btc_block_height, $self->btc_tx_num, $self->btc_out_num, $self->btc_tx_hash, $self->btc_tx_data, $self->merkle_path, $self->value, $script->id);
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
    my ($height) = @_;

    my $time = time_by_height($height);
    my ($matched_block) = Bitcoin::Block->find(
        time    => { '<' => $time - COINBASE_CONFIRM_TIME },
        -sortby => 'height DESC',
        -limit  => 1,
    );
    return () unless $matched_block;
    my $max_height = $matched_block->height - COINBASE_CONFIRM_BLOCKS;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT btc_block_height, btc_tx_num, btc_out_num, btc_tx_hash, btc_tx_data, merkle_path, value, s.data as open_script";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::OpenScript->TABLE . "` AS s ON (t.open_script = s.id)";
    $sql .= " WHERE tx_out IS NULL AND btc_block_height <= ?";
    my $sth = dbh->prepare($sql);
    DEBUG_ORM && Debugf("sql: [%s] values [%u]", $sql, $max_height);
    $sth->execute($max_height);
    my @coinbase;
    while (my $hash = $sth->fetchrow_hashref()) {
        push @coinbase, $class->new($hash);
    }
    return @coinbase;
}

# Coinbase can be included in only one transaction (unlike txo), so we do not need to build separate singleton cache for coinbase
# save them just as links from related transactions
sub load_stored_coinbase {
    my $class = shift;
    my ($tx_id, $tx_hash) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT btc_block_height, btc_tx_num, btc_out_num, btc_tx_hash, btc_tx_data, merkle_path, value, s.data as open_script";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::OpenScript->TABLE . "` AS s ON (t.open_script = s.id)";
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
    return 0;
}

sub serialize {
    my $self = shift;
    # value and open_script is matched transaction output and can be fetched from btc_tx_data and btc_out_num
    return {
        btc_block_hash => unpack("H*", $self->btc_block_hash),
        btc_tx_num     => $self->btc_tx_num+0,
        btc_out_num    => $self->btc_out_num+0,
        btc_tx_data    => unpack("H*", $self->btc_tx_data),
        merkle_path    => unpack("H*", $self->merkle_path),
    };
}

sub deserialize {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    # TODO: validate $args
    my $btc_block_hash = pack("H*", $args->{btc_block_hash});
    my ($btc_block) = Bitcoin::Block->find(hash => $btc_block_hash);
    if (!$btc_block) {
        # unset btc_synced() if last btc block older than COINBASE_CONFIRM_TIME
        # otherwise assume this is not correct coinbase
        ($btc_block) = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 1);
        if (!$btc_block || $btc_block->time < time() - COINBASE_CONFIRM_TIME) {
            # TODO: request btc blocks
            btc_synced(0);
            # TODO: set this tx as pending
            Warningf("BTC blockchain not synced, can't validate coinbase");
            return undef;
        }
        Warningf("Incorrect coinbase transaction based on unexistent btc block %s", unpack("H*", $btc_block_hash));
        return undef;
    }
    my $btc_tx_data = pack("H*", $args->{btc_tx_data});
    my $btc_tx_hash = hash256($btc_tx_data);
    my $merkle_path = pack("H*", $args->{merkle_path});
    # Check merkle path (but ignore mismatch for produced upgrades)
    if (!$btc_block->check_merkle_path($btc_tx_hash, $args->{btc_tx_num}, $merkle_path)) {
        Warningf("Merkle path check failed for btc upgrade transaction %s in block %s",
            unpack("H*", scalar reverse $btc_tx_hash), $btc_block->hash_hex);
        return undef;
    }
    # Deserialize btc transaction for get upgrade data (value, open_script)
    my $transaction = Bitcoin::Transaction->deserialize(Bitcoin::Serialized->new($btc_tx_data));
    if (!$transaction) {
        Warningf("Incorrect btc upgrade transaction data %s", unpack("H*", scalar reverse $btc_tx_hash));
        return undef;
    }
    my $out = $transaction->out->[$args->{btc_out_num}];
    if (!$out) {
        Warningf("Incorrect btc upgrade transaction data %s, no output %u", $transaction->hash_str, $args->{btc_out_num});
        return undef;
    }
    if (substr($out->{open_script}, 0, QBT_SCRIPT_START_LEN) ne QBT_SCRIPT_START) {
        Warningf("Incorrect btc upgrade transaction %s output open_script", $transaction->hash_str);
        return undef unless $config->{fake_coinbase};
    }
    return $class->new({
        btc_block_height => $btc_block->height,
        btc_block_hash   => $btc_block_hash,
        btc_tx_num       => $args->{btc_tx_num},
        btc_out_num      => $args->{btc_out_num},
        btc_tx_data      => $btc_tx_data,
        btc_tx_hash      => $btc_tx_hash,
        merkle_path      => $merkle_path,
        value            => $out->{value},
        open_script      => substr($out->{open_script}, QBT_SCRIPT_START_LEN),
    });
}

sub btc_block_hash {
    my $self = shift;
    if (!defined $self->{btc_block_hash}) {
        my ($btc_block) = Bitcoin::Block->find(height => $self->btc_block_height);
        $self->{btc_block_hash} = $btc_block->hash;
    }
    return $self->{btc_block_hash};
}

sub btc_confirm_time {
    my $self = shift;
    if (!defined $self->{btc_confirm_time}) {
        my ($btc_block) = Bitcoin::Block->find(height => $self->btc_block_height + COINBASE_CONFIRM_BLOCKS);
        return undef unless $btc_block;
        $self->{btc_confirm_time} = $btc_block->time;
    }
    return $self->{btc_confirm_time};
}

sub min_tx_time {
    my $self = shift;
    return COINBASE_CONFIRM_TIME + ($self->btc_confirm_time // return undef);
}

1;
