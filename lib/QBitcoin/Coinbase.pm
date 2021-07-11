package QBitcoin::Coinbase;
use warnings;
use strict;

use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::Log;
use QBitcoin::ORM qw(:types dbh for_log DEBUG_ORM);

use constant TABLE => 'coinbase';

use constant FIELDS => {
    btc_block_height => NUMERIC,
    btc_tx_num       => NUMERIC,
    btc_out_num      => NUMERIC,
    btc_tx_hash      => BINARY,
    merkle_path      => BINARY,
    value            => NUMERIC,
    open_script      => NUMERIC,
    tx_out           => NUMERIC,
    close_script     => BINARY,
};

mk_accessors(keys %{&FIELDS});

sub store {
    my $self = shift;
    my $script = QBitcoin::OpenScript->store($self->open_script);
    my $sql = "REPLACE INTO `" . TABLE . "` (btc_block_height, btc_tx_num, btc_out_num, btc_tx_hash, merkle_path, value, open_script, tx_out, close_script) VALUES (?,?,?,?,?,?,?,NULL,NULL)";
    DEBUG_ORM && Debugf("dbi [%s] values [%u,%u,%s,%s,%lu,%u]", $sql, $self->btc_block_height, $self->btc_tx_num, $self->btc_out_num, for_log($self->btc_tx_hash), for_log($self->merkle_path), $self->value, $script->id);
    my $res = dbh->do($sql, undef, $self->btc_block_height, $self->btc_tx_num, $self->btc_out_num, $self->btc_tx_hash, $self->merkle_path, $self->value, $script->id);
    $res == 1
        or die "Can't store coinbase " . $self->btc_tx_num . ":" . $self->btc_out_num . ": " . (dbh->errstr // "no error") . "\n";
}

1;
