package QBitcoin::Transaction;
use warnings;
use strict;

use JSON::XS;
use List::Util qw(sum0);
use Digest::SHA qw(sha256);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::ORM qw(find :types);
use QBitcoin::TXO;

use constant FIELDS => {
    id           => NUMERIC, # db primary key for reference links
    hash         => BINARY,
    block_height => NUMERIC,
    fee          => NUMERIC,
    size         => NUMERIC,
};

use constant ATTR => qw(
    confirmed
    coins_upgraded
);

mk_accessors(keys %{&FIELDS}, ATTR);

my %TRANSACTION;

my $JSON = JSON::XS->new;

sub get_by_hash {
    my $class = shift;
    my ($tx_hash) = @_;

    return $TRANSACTION{$tx_hash} // $class->find(hash => $tx_hash);
}

sub get {
    my $class = shift;
    my ($tx_hash) = @_;

    return $TRANSACTION{$tx_hash};
}

# We never drop existing transaction b/c it's possible its txo already spend by another one
# This method calls when the transaction stored in the database and is not needed in memory anymore
# TXO (input and output) will free from %TXO hash by DESTROY() method, they have weaken reference for this
sub free {
    my $self = shift;
    delete $TRANSACTION{$self->hash};
}

sub store {
    my $self = shift;
    my ($height) = @_;
    local $self->{block_height} = $height;
    # we are in sql transaction
    $self->replace();
    my $class = ref $self;
    foreach my $in (@{$self->in}) {
        my $txo = QBitcoin::TXO->get($in);
        $txo->store_spend($self),
    }
    foreach my $num (0 .. @{$self->out}-1) {
        my $txo = $self->out->[$num];
        $txo->store($self);
    }
    # TODO: store tx data (smartcontract)
}

sub hash_out {
    my $arg = shift;
    my $hash = ref($arg) ? $arg->hash : $arg;
    # TODO: return full hash
    return unpack("H*", substr($hash, 0, 4));
}

sub serialize {
    my $self = shift;
    # TODO: pack as binary data
    return $JSON->encode({
        in  => [ map { serialize_input($_) } @{$self->in}  ],
        out => [ map { $_->serialize       } @{$self->out} ],
    }) . "\n";
}

sub serialize_input {
    my $in = shift;
    return {
        tx_out       => $in->{txo}->tx_in,
        num          => $in->{txo}->num,
        close_script => $in->{close_script},
    };
}

sub deserialize {
    my $class = shift;
    my ($tx_data) = @_;
    my $decoded = eval { $JSON->decode($tx_data) };
    if (!$decoded) {
        Warningf("Incorrect transaction data: %s", $@);
        return undef;
    }
    my $hash = $class->calculate_hash($tx_data);
    my $out  = create_outputs($decoded->{out}, $hash);
    my $in   = load_inputs($decoded->{in}, $hash);
    my $self = $class->new(
        in   => $in,
        out  => $out,
        hash => $hash,
        size => length($tx_data),
    );
    if ($class->calculate_hash($self->serialize) ne $hash) {
        Warningf("Incorrect serialized transaction has different hash");
        return undef;
    }
    $self->validate() == 0
        or return undef;

    $self->fee = sum0(map { $_->value } @$out) - sum0(map { $_->{txo}->value } @$in) + ($self->coins_upgraded // 0);
    QBitcoin::TXO->set_all($self->hash, $out);

    return $self;
}

sub create_outputs {
    my ($out, $hash) = @_;
    my @txo;
    foreach my $num (0 .. $#$out) {
        my $txo = QBitcoin::TXO->new({
            tx_in       => $hash,
            num         => $num,
            value       => $out->[$num]->{value},
            open_script => $out->[$num]->{open_script},
        });
        push @txo, $txo;
    }
    return \@txo;
}

sub load_inputs {
    my ($inputs, $hash) = @_;

    # tx inputs are not sorted in the database, so sort them here for get deterministic transaction hash
    my @loaded_inputs;
    my @need_load_txo;
    foreach my $in (@$inputs) {
        if (my $txo = QBitcoin::TXO->get($in)) {
            push @loaded_inputs, {
                txo          => $txo,
                close_script => $in->{close_script},
            };
        }
        else {
            push @need_load_txo, $in;
        }
    }

    if (@need_load_txo) {
        QBitcoin::TXO->load(@need_load_txo);
        foreach my $in (@need_load_txo) {
            if (my $txo = QBitcoin::TXO->get($in)) {
                push @loaded_inputs, {
                    txo          => $txo,
                    close_script => $in->{close_script},
                };
            }
            else {
                Warningf("input %s:%u not found in transaction %s",
                    hash_out($in->{tx_out}), $in->{num}, hash_out($hash));
                return undef;
            }
        }
    }
    return [ sort { _cmp_inputs($a, $b) } @loaded_inputs ];
}

sub _cmp_inputs {
    my ($in1, $in2) = @_;
    return $in1->{txo}->tx_in cmp $in2->{txo}->tx_out || $in1->{txo}->num <=> $in2->{txo}->num;
}

sub calculate_hash {
    my $self = shift;
    my ($tx_data) = @_;
    return sha256($tx_data);
}

sub validate_coinbase {
    my $self = shift;
    if (@{$self->out} != 1) {
        Warningf("Incorrect transaction %s", $self->hash_out);
        return -1;
    }
    # TODO: Get and validate information about btc upgrade from $self->data
    my $coins = $self->out->[0]->value;
    Infof("Coinbase transaction %s, upgraded %u coins", $self->hash_out, $coins);
    $self->upgraded_coins = $coins;
    return 0;
}

sub validate {
    my $self = shift;
    # Transaction must contains at least one input (even coinbase!) and at least one output (can't spend all inputs as fee)
    if (!@{$self->in}) {
        return $self->validate_coinbase;
    }
    if (!@{$self->out}) {
        Warningf("No outputs in transaction");
        return -1;
    }
    foreach my $out (@{$self->out}) {
        if ($out->value < 0 && $out->value > MAX_VALUE) {
            Warningf("Incorrect output value in transaction");
            return -1;
        }
    }
    foreach my $in (@{$self->in}) {
        # TODO: check $in->{close_script} matches $in->{txo}->open_script
    }
    return 0;
}

sub receive {
    my $self = shift;
    # TODO: Check that transaction is signed correctly
    $TRANSACTION{$self->hash} = $self;
    return 0;
}

sub on_load {
    my $self = shift;
    $self->confirmed = 1;
    $TRANSACTION{$self->hash} = $self;
    # Load TXO for inputs and outputs
    my @outputs = QBitcoin::TXO->load_outputs($self);
    my @inputs;
    foreach my $txo (QBitcoin::TXO->load_inputs($self)) {
        push @inputs, {
            txo          => $txo,
            close_script => $txo->close_script,
        };
        $txo->close_script = undef;
    }
    $self->inputs  = [ sort { _cmp_inputs($a, $b) } @inputs ];
    $self->outputs = \@outputs;
    return $self;
}

1;
