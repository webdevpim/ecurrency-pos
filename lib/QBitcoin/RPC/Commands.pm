package QBitcoin::RPC::Commands;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::ORM qw(dbh);
use QBitcoin::Block;
use QBitcoin::Coinbase;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced btc_synced);
use Bitcoin::Block;

use constant {
    FALSE => \0,
    TRUE  => \1,
};

my %PARAMS;
my %HELP;

sub params { $PARAMS{$_[1]} }
sub help   { $HELP{$_[1]}   }

$PARAMS{ping} = "";
$HELP{ping} = qq(
Check that the node alive and responsible.

Result:
null    (json null)

Examples:
> qbitcoin-cli ping
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "ping", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_ping {
    my $self = shift;
    $self->response_ok;
}

$PARAMS{getblockchaininfo} = "";
$HELP{getblockchaininfo} = qq(
Returns an object containing various state info regarding blockchain processing.

Result:
{                                         (json object)
  "chain" : "str",                        (string) current network name (main, test, regtest)
  "blocks" : n,                           (numeric) the height of the most-work fully-validated chain. The genesis block has height 0
  "bestblockhash" : "str",                (string) the hash of the currently best block
  "weight" : n,                           (numeric) the current weight
  "mediantime" : n,                       (numeric) median time for the current best block
  "initialblockdownload" : true|false,    (boolean) (debug information) estimate of whether this node is in Initial Block Download mode
  "total_coins" : n,                      (numeric) total number of generated (upgraded) coins
  "btc_headers" : n,                      (numeric) number of processed btc block headers
  "btc_scanned" : n,                      (numeric) number of scanned btc blocks
  "btc_synced" : true|false,              (bookean) is btc blockchain fully synced or is in initial block download mode
}

Examples:
> qbitcoin-cli getblockchaininfo
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockchaininfo", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_getblockchaininfo {
    my $self = shift;
    my $best_block;
    if (defined(my $height = QBitcoin::Block->blockchain_height)) {
        $best_block = QBitcoin::Block->best_block($height);
    }
    my $response = {
        chain                => "main",
        blocks               => $best_block ? $best_block->height+0   : -1,
        bestblockhash        => $best_block ? unpack("H*", $best_block->hash) : undef,
        weight               => $best_block ? $best_block->weight+0   : -1,
        initialblockdownload => blockchain_synced() ? FALSE : TRUE,
        # size_on_disk         => # TODO
    };
    if (UPGRADE_POW) {
        my ($btc_block) = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 1);
        my $btc_scanned;
        if ($btc_block) {
            if ($btc_block->scanned) {
                $btc_scanned = $btc_block;
            }
            else {
                ($btc_scanned) = Bitcoin::Block->find(scanned => 1, -sortby => 'height DESC', -limit => 1);
            }
        }
        $response->{btc_synced}  = btc_synced() ? TRUE : FALSE,
        $response->{btc_headers} = $btc_block   ? $btc_block->height+0   : 0,
        $response->{btc_scanned} = $btc_scanned ? $btc_scanned->height+0 : 0,
        my ($coinbase) = dbh->selectrow_array("SELECT SUM(value) FROM `" . QBitcoin::Coinbase->TABLE . "` WHERE tx_out IS NOT NULL");
        $response->{total_coins} = $coinbase ? $coinbase / DENOMINATOR : 0;
    }
    return $self->response_ok($response);
}

$PARAMS{getbestblockhash} = "";
$HELP{getbestblockhash} = qq(
Returns the hash of the best (tip) block in the most-weight fully-validated chain.

Result:
"hex"    (string) the block hash, hex-encoded

Examples:
> qbitcoin-cli getbestblockhash
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getbestblockhash", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_getbestblockhash {
    my $self = shift;
    my $best_block;
    if (defined(my $height = QBitcoin::Block->blockchain_height)) {
        $best_block = QBitcoin::Block->best_block($height);
    }
    return $self->response_ok($best_block ? unpack("H*", $best_block->hash) : undef);
}

$PARAMS{help} = "command?";
$HELP{help} = q(
List all commands, or get help for a specified command.

Arguments:
1. command    (string, optional, default=all commands) The command to get help on

Result:
"str"    (string) The help text
);
sub cmd_help {
    my $self = shift;
    if (my $cmd = $self->args->[0]) {
        if (defined $self->params($cmd)) {
            return $self->response_ok($self->brief($cmd) . "\n" . ($HELP{$cmd} // ""));
        }
        else {
            return $self->response_ok("help: unknown command: $cmd");
        }
    }
    my $help = "";
    foreach my $cmd (sort keys %PARAMS) {
        $help .= $self->brief($cmd) . "\n";
    }
    return $self->response_ok($help);
}

$PARAMS{getblockheader} = "blockhash";
$HELP{getblockheader} = qq(
Returns an Object with information about blockheader <hash>.

Arguments:
1. blockhash    (string, required) The block hash

Result:
{                                 (json object)
  "hash" : "hex",                 (string) the block hash (same as provided)
  "confirmations" : n,            (numeric) The number of confirmations, or -1 if the block is not on the main chain
  "height" : n,                   (numeric) The block height or index
  "merkleroot" : "hex",           (string) The merkle root
  "time" : xxx,                   (numeric) The block time expressed in UNIX epoch time
  "nTx" : n,                      (numeric) The number of transactions in the block
  "previousblockhash" : "hex",    (string) The hash of the previous block
  "nextblockhash" : "hex"         (string) The hash of the next block
}

Examples:
> qbitcoin-cli getblockheader "00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockheader", "params": ["00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_getblockheader {
    my $self = shift;
    my $hash = pack("H*", $self->args->[0]);
    my $best_height = QBitcoin::Block->blockchain_height;
    my $block = QBitcoin::Block->find(hash => $hash);
    if (!$block) {
        for (my $height = QBitcoin::Block->min_incore_height; $height <= $best_height; $height++) {
            last if $block = QBitcoin::Block->block_pool($height, $hash);
        }
        $block
            or $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "Block not found");
    }
    my $best_block = QBitcoin::Block->best_block($best_height);
    my $next_block = QBitcoin::Block->best_block($block->height + 1) // QBitcoin::Block->find(height => $block->height + 1);

    return $self->response_ok({
        hash              => unpack("H*", $block->hash),
        height            => $block->height,
        time              => time_by_height($block->height),
        confirmations     => $best_height - $block->height + 1,
        nTx               => scalar(@{$block->transactions}),
        previousblockhash => unpack("H*", $block->prev_hash),
        nextblockhash     => $next_block ? unpack("H*", $next_block->hash) : undef,
        merkleroot        => unpack("H*", $block->merkle_root),
        weight            => $block->weight,
        confirm_weight    => $best_block->weight - $block->weight,
    });
}

$PARAMS{getblockcount} = "";
$HELP{getblockcount} = qq(
Returns the height of the most-work fully-validated chain.
The genesis block has height 0.

Result:
n    (numeric) The current block count

Examples:
> qbitcoin-cli getblockcount
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockcount", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_getblockcount {
    my $self = shift;
    return $self->response_ok(QBitcoin::Block->blockchain_height);
}

1;
