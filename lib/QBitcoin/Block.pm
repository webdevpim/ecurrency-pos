package QBitcoin::Block;
use warnings;
use strict;

use QBitcoin::ORM qw(:types);
use QBitcoin::Accessors qw(mk_accessors new);

use Role::Tiny::With;
with 'QBitcoin::Block::Receive';
with 'QBitcoin::Block::Validate';
with 'QBitcoin::Block::Serialize';
with 'QBitcoin::Block::Stored';
with 'QBitcoin::Block::Generate';

use constant PRIMARY_KEY => 'height';

use constant FIELDS => {
    height    => NUMERIC,
    hash      => BINARY,
    prev_hash => BINARY,
    weight    => NUMERIC,
};

use constant ATTR => qw(
    linked
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
    # TODO: calculate by the first transaction
    my $self = shift;
    return $self->{self_weight} //= $self->prev_block ? $self->weight - $self->prev_block->weight : $self->weight;
}

1;
