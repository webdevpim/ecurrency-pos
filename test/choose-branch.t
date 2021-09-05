#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;
use Test::MockModule;
use JSON::XS;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Protocol;
use QBitcoin::Block;
use Bitcoin::Serialized;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

sub mock_block_serialize {
    my $self = shift;
    varstr(encode_json({
        height       => $self->height+0,
        weight       => $self->weight+0,
        hash         => $self->hash,
        prev_hash    => $self->prev_hash,
        transactions => $self->tx_hashes,
        merkle_root  => $self->merkle_root,
    }));
}

sub mock_block_deserialize {
    my $class = shift;
    my ($data) = @_;
    $class->new(decode_json($data->get_string));
}

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('self_weight', \&mock_self_weight);
$block_module->mock('find', sub {});
$block_module->mock('serialize', \&mock_block_serialize);
$block_module->mock('deserialize', \&mock_block_deserialize);
my $block_hash;
$block_module->mock('calculate_hash', sub { $block_hash });

sub mock_self_weight {
    my $self = shift;
    return $self->{self_weight} //=
        $self->prev_block ? $self->weight - $self->prev_block->weight : $self->weight;
}

# parent process accept and check results; child execute subchilds and wait them
pipe my $rh, my $wh;
my $base_pid = fork();
close($base_pid ? $wh : $rh);

# height, hash, prev_hash, weight [, self_weight]
send_blocks([
    [ 0, "a1", undef, 100 ],
    [ 1, "a2", "a1",  200 ],
    [ 2, "a3", "a2",  300 ],
], [ 2, "a3", 300 ]);

send_blocks([
    [ 0, "a1", undef, 100 ],
    [ 1, "a2", "a1",  200 ],
    [ 2, "b3", "b2",  300 ],
], [ 1, "a2", 200 ]);

send_blocks([
    [ 0, "a1", undef, 100 ],
    [ 1, "a2", "a1",  200 ],
    [ 2, "b3", "b2",  300, 150 ],
    [ 1, "b2", "a1",  150 ],
], [ 2, "b3", 300 ]);

send_blocks([
    [ 0, "a1", undef, 100 ],
    [ 1, "a2", "a1",  200 ],
    [ 2, "a3", "a2",  300 ],
    [ 1, "b2", "a1",  210 ],
    [ 2, "b3", "b2",  290 ],
], [ 2, "a3", 300 ]);

send_blocks([
    [ 0, "a1", undef, 100 ],
    [ 1, "b2", "a1",  210 ],
    [ 2, "b3", "b2",  290 ],
    [ 2, "a3", "a2",  300, 100 ],
    [ 1, "a2", "a1",  200 ],
], [ 2, "a3", 300 ]);

sub send_blocks {
    my ($blocks, $expect) = @_;

    # Create new blockchain from scratch for each send_blocks() call
    if ($base_pid) {
        my $res = <$rh>;
        chomp($res);
        my ($height, $hash, $weight) = split(/\s+/, $res);
        state $n=1;
        subtest "branch " . $n++ => sub {
            is($height, $expect->[0], "height");
            is($hash,   $expect->[1], "hash");
            is($weight, $expect->[2], "weight");
        };
        return;
    }
    my $pid = fork();
    if ($pid) {
        waitpid($pid, 0);
        die if $?;
    }
    elsif (defined($pid)) {
        # child
        my $peer = QBitcoin::Protocol->new(state => STATE_CONNECTED);
        foreach my $block_data (@$blocks) {
            my $block = QBitcoin::Block->new(
                height       => $block_data->[0],
                hash         => $block_data->[1],
                prev_hash    => $block_data->[2],
                weight       => $block_data->[3],
                self_weight  => $block_data->[4],
                merkle_root  => ZERO_HASH,
                transactions => [],
            );
            $peer->has_weight = $block->weight;
            my $block_data = $block->serialize;
            $block_hash = $block->hash;
            $peer->cmd_block($block_data);
        }
        my $height = QBitcoin::Block->blockchain_height;
        my $weight = QBitcoin::Block->best_weight;
        my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
        my $hash   = $block ? $block->hash : undef;
        print $wh join(' ', $height // "", $hash // "", $weight // "") . "\n";
        exit(0);
    }
    else {
        die "Can't fork: $!\n";
    }
}

if ($base_pid) {
    waitpid($base_pid, 0);
    die if $?;
    done_testing();
}
