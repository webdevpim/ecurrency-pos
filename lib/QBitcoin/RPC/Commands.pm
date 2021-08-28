package QBitcoin::RPC::Commands;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Const;
use QBitcoin::Block;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced btc_synced);
use Bitcoin::Block;

use constant {
    FALSE => \0,
    TRUE  => \1,
};

sub cmd_ping {
    my $self = shift;
    my @params = @_;
    $self->response_ok;
}

sub cmd_getblockchaininfo {
    my $self = shift;
    my @params = @_;
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
        # total_coins          => # TODO
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
    }
    $self->response_ok($response);
}

1;
