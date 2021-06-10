package QBitcoin::Block;
use warnings;
use strict;

use QBitcoin::ORM qw(:types);
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::Crypto qw(hash256);

use Role::Tiny::With;
with 'QBitcoin::Block::Receive';
with 'QBitcoin::Block::Validate';
with 'QBitcoin::Block::Serialize';
with 'QBitcoin::Block::Stored';

use constant PRIMARY_KEY => 'height';

use constant FIELDS => {
    height      => NUMERIC,
    hash        => BINARY,
    prev_hash   => BINARY,
    merkle_root => BINARY,
    weight      => NUMERIC,
};

use constant ATTR => qw(
    next_block
    received_from
    transactions
);

mk_accessors(keys %{&FIELDS});
mk_accessors(ATTR);

sub branch_weight {
    my $self = shift;
    while ($self->next_block) {
        $self = $self->next_block;
    }
    return $self->weight;
}

sub branch_height {
    my $self = shift;
    while ($self->next_block) {
        $self = $self->next_block;
    }
    return $self->height;
}

sub self_weight {
    my $self = shift;
    if (!defined $self->{self_weight}) {
        if (@{$self->transactions}) {
            if (defined(my $stake_weight = $self->transactions->[0]->stake_weight($self->height))) {
                $self->{self_weight} = $stake_weight + @{$self->transactions};
            }
            # otherwise we have unknown input in stake transaction; return undef and calculate next time
        }
        else {
            $self->{self_weight} = 0;
        }
    }
    return $self->{self_weight};
}

sub add_tx {
    my $self = shift;
    my ($tx) = @_;
    $self->{tx_by_hash} //= {};
    $self->{tx_by_hash}->{$tx->hash} = $tx;
    $tx->add_to_block($self);
    delete $self->{pending_tx}->{$tx->hash} if $self->pending_tx;
}

sub pending_tx {
    my $self = shift;
    my ($tx_hash) = @_;
    if ($tx_hash) {
        $self->{pending_tx}->{$tx_hash} = 1;
        return 1;
    }
    else {
        return $self->{pending_tx} && %{$self->{pending_tx}} ? [ keys %{$self->{pending_tx}} ] : undef;
    }
}

sub compact_tx {
    my $self = shift;
    $self->{transactions} //= [ map { $self->{tx_by_hash}->{$_} } @{$self->{tx_hashes}} ];
    delete $self->{tx_hashes};
    delete $self->{tx_by_hash};
}

sub free_tx {
    my $self = shift;
    # works for pending block too
    if ($self->transactions) {
        foreach my $tx (@{$self->transactions}) {
            $tx->del_from_block($self);
        }
    }
    elsif ($self->{tx_by_hash}) {
        foreach my $tx (values %{$self->{tx_by_hash}}) {
            $tx->del_from_block($self);
        }
    }
}

sub tx_hashes {
    my $self = shift;
    return $self->{tx_hashes} //
        [ map { $_->hash } @{$self->{transactions}} ];
}

sub hash_str {
    my $arg  = pop;
    my $hash = ref($arg) ? $arg->hash : $arg;
    return unpack("H*", substr($hash, 0, 4));
}

sub _merkle_hash {
    return hash256($_[0]);
}

sub _merkle_root {
    my $self = shift;
    my ($level, $start) = @_;
    my $cur_hash = $start < @{$self->transactions} ? $self->transactions->[$start]->hash : $self->transactions->[-1]->hash;
    my $level_size = 1;
    for (my $cur_level = 0; $cur_level < $level; $cur_level++) {
        my $next_hash = $start < @{$self->transactions} ? $self->_merkle_root($cur_level, $start + $level_size) : $cur_hash;
        $cur_hash = _merkle_hash($cur_hash . $next_hash);
    }
    return $cur_hash;
}

sub calculate_merkle_root {
    my $self = shift;
    @{$self->transactions}
        or return "\x00" x 8;
    my $level = 0;
    my $level_size = 1; # 2**$level
    my $cur_hash = $self->transactions->[0]->hash;
    while ($level_size  < @{$self->transactions}) {
        $cur_hash = _merkle_hash($cur_hash . $self->_merkle_root($level, $level_size));
        ++$level;
        $level_size *= 2;
    }
    return $cur_hash;
}

1;
