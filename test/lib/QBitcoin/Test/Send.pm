package QBitcoin::Test::Send;
use warnings;
use strict;

use Exporter qw(import);
our @EXPORT_OK = qw(
    send_block
    send_tx
    $connection
    $last_tx
);

use QBitcoin::Const;
use QBitcoin::Connection;
use QBitcoin::Peer;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => IPV6_V4_PREFIX . pack("C4", split(/\./, "127.0.0.1")));
our $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);
our $last_tx;

sub send_block {
    my ($height, $hash, $prev_hash, $weight, @tx) = @_;
    my $block = QBitcoin::Block->new(
        time         => GENESIS_TIME + $height * BLOCK_INTERVAL * FORCE_BLOCKS,
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => \@tx,
        weight       => $weight,
    );
    $block->add_tx($_) foreach @tx;
    $block->merkle_root = $block->calculate_merkle_root();
    my $block_data = $block->serialize;
    block_hash($block->hash);
    $connection->protocol->command("block");
    $connection->protocol->cmd_block($block_data);
}

sub send_tx {
    my ($fee, $prev_tx, $script) = @_;
    my $tx = make_tx(@_ > 1 ? $prev_tx : $last_tx, $fee, $script);
    $connection->protocol->command("tx");
    $connection->protocol->cmd_tx($tx->serialize . "\x00"x16);
    $last_tx = $tx;
    return $tx;
}

1;
