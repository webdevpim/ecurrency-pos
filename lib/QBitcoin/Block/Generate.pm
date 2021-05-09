package QBitcoin::Block::Generate;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Const;
use QBitcoin::Log;

my $generated_height;

sub generate {
    my $class = shift;
    my ($height) = @_;
    my $prev_block;
    if ($height > 0) {
        $prev_block = $class->best_block($height-1);
    }

    # TODO: generate correct block from mempool
    my $self_weight = int(rand(100));
    my $generated = $class->new({
        height       => $height,
        weight       => $prev_block ? $prev_block->weight + $self_weight : $self_weight,
        self_weight  => $self_weight,
        prev_hash    => $prev_block ? $prev_block->hash : undef,
        transactions => [],
    });
    my $data = $generated->serialize;
    $generated->hash($generated->calculate_hash($data));
    $generated_height = $height;
    Infof("Generated block height %u weight %u", $height, $generated->weight);
    $generated->receive();
}

sub generated_height {
    my $class = shift;
    return $generated_height;
}

sub generate_new {
    my $class = shift;
    undef $generated_height;
}

1;
