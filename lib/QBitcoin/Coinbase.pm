package QBitcoin::Coinbase;
use warnings;
use strict;

use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::ORM qw(:types dbh for_log DEBUG_ORM);
use QBitcoin::Crypto qw(hash256);
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
    my $script = QBitcoin::OpenScript->store($self->open_script);
    my $sql = "REPLACE INTO `" . TABLE . "` (btc_block_height, btc_tx_num, btc_out_num, btc_tx_hash, merkle_path, value, open_script, tx_out) VALUES (?,?,?,?,?,?,?,NULL)";
    DEBUG_ORM && Debugf("dbi [%s] values [%u,%u,%s,%s,%lu,%u]", $sql, $self->btc_block_height, $self->btc_tx_num, $self->btc_out_num, for_log($self->btc_tx_hash), for_log($self->merkle_path), $self->value, $script->id);
    my $res = dbh->do($sql, undef, $self->btc_block_height, $self->btc_tx_num, $self->btc_out_num, $self->btc_tx_hash, $self->merkle_path, $self->value, $script->id);
    $res == 1
        or die "Can't store coinbase " . $self->btc_tx_num . ":" . $self->btc_out_num . ": " . (dbh->errstr // "no error") . "\n";
}

sub store_published {
    my $self = shift;
    my ($tx) = @_;

    my $sql = "UPDATE `" . TABLE . "` SET tx_out = ?, WHERE btc_tx_hash = ? AND btc_out_num = ?";
    DEBUG_ORM && Debugf("dbi [%s] values [%u,%s,%s,%u]", $sql, $tx->id, for_log($self->btc_tx_hash), $self->btc_out_num);
    my $res = dbh->do($sql, undef, $tx->id, $self->btc_tx_hash, $self->btc_out_num);
    $res == 1
        or die "Can't store coinbase " . for_log($self->btc_tx_hash) . ":" . $self->btc_out_num . " as processed: " . (dbh->errstr // "no error") . "\n";
}

sub get_new {
    my $class = shift;

    my ($matched_block) = Bitcoin::Block->find(
        time    => { '<' => time() - COINBASE_CONFIRM_TIME },
        -sortby => 'height DESC',
        -limit  => 1,
    );
    return () unless $matched_block;
    my @coinbase = $class->find(
        tx_out           => undef,
        btc_block_height => { '<=' => $matched_block->height - COINBASE_CONFIRM_BLOCKS },
    );
    return @coinbase;
}

# Coinbase can be included to only one transaction (unlike txo), so we do not need to build separate singleton cache for coinbase
# save them just as links from related transactions
sub load_stored_coinbase {
    my $class = shift;
    my ($tx_id, $tx_hash) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT btc_block_height, btc_tx_num, btc_out_num, btc_tx_hash, merkle_path, value, s.data as open_script";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN " . QBitcoin::OpenScript->TABLE . " s ON (t.open_script = s.id)";
    $sql .= " WHERE tx_out = ?";
    my $sth = dbh->prepare($sql);
    DEBUG_ORM && Debugf("sql: [%s] values [%u]", $sql, $tx_id);
    $sth->execute($tx_id);
    my $coinbase;
    if (my $hash = $sth->fetchrow_hashref()) {
        $hash->{tx_hash} = $tx_hash;
        $coinbase = $class->new($hash);
    }
    return $coinbase;
}

sub validate {
    my $self = shift;
    # TODO: check if the coinbase is correct using merkle tree and bitcoin blockchain
}

sub serialize {
    my $self = shift;
    # value and open_script is matched transaction output and can be fetched from btc_tx_data and btc_out_num
    return {
        btc_block_hash => unpack("H*", $self->btc_block_hash),
        btc_tx_num     => $self->btc_tx_num,
        btc_out_num    => $self->btc_out_num,
        btc_tx_data    => unpack("H*", $self->btc_tx_data),
        merkle_path    => unpack("H*", $self->merkle_path),
    };
}

sub btc_block_hash {
    my $self = shift;
    if (!defined $self->{btc_block_hash}) {
        my ($btc_block) = QBitcoin::Block->find(height => $self->btc_block_height);
        $self->{btc_block_hash} = $btc_block->hash;
        $self->{btc_block_time} = $btc_block->time;
    }
    return $self->{btc_block_hash};
}

sub btc_block_time {
    my $self = shift;
    if (!defined $self->{btc_block_hash}) {
        my ($btc_block) = QBitcoin::Block->find(height => $self->btc_block_height);
        $self->{btc_block_hash} = $btc_block->hash;
        $self->{btc_block_time} = $btc_block->time;
    }
    return $self->{btc_block_time};
}

sub deserialize {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    # TODO: create value and open_scipt by serialized raw data
    return $class->new(%$args, btx_tx_hash => hash256($args->{btc_tx_data}));
}

1;
