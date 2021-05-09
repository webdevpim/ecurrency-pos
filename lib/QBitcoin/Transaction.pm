package QBitcoin::Transaction;
use warnings;
use strict;

use JSON::XS;
use Digest::SHA qw(sha256);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::ORM qw(find :types);
use QBitcoin::TXO;

use constant FIELDS => {
    id           => NUMERIC, # db primary key for reference links
    hash         => BINARY,
    block_height => NUMERIC,
};

my %TRANSACTION;

my $JSON = JSON::XS->new;

sub get_by_hash {
    my $class = shift;
    my ($tx_hash) = @_;

    return $TRANSACTION{$tx_hash} // $class->find(hash => $tx_hash);
}

sub free {
    my $self = shift;
    delete $TRANSACTION{$self->hash};
    foreach my $in (@{$self->in}) {
        QBitcoin::TXO->free($in);
    }
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
        $txo->store_spend($self->id),
    }
    foreach my $num (0 .. @{$self->out}-1) {
        my $txo = $self->out->[$num];
        $txo->store($self->id);
    }
    # TODO: store tx data (smartcontract)
}

sub serialize {
    my $self = shift;
    # TODO: pack as binary data
    my $out = $self->{out} // QBitcoin::TXO->get_all($self->hash);
    return $JSON->encode({
        in  => [ sort { $a->{tx_in} cmp $b->{tx_in} || $a->{num} <=> $b->{num} }
            map +{ tx_in => unpack("H*", $_->{tx_in}), num => $_->{num}, close_script => $_->{close_script} }, @{$self->in} ],
        out => [ map +{ value => $_->value, open_script => $_->open_script }, @$out ],
    }) . "\n";
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
    my @out;
    foreach my $num (0 .. @{$decoded->{out}}-1) {
        my $out = $decoded->{out}->[$num];
        my $txo = QBitcoin::TXO->new({
            tx_in       => $hash,
            num         => $num,
            value       => $out->{value},
            open_script => $out->{open_script},
        });
        push @out, $txo;
    }
    my $self = $class->new({
        in   => $decoded->{in},
        out  => \@out,
        hash => $hash,
    });
    if ($class->calculate_hash($self->serialize) ne $hash) {
        Warningf("Incorrect serialized transaction has different hash");
        return undef;
    }
    $self->validate() == 0
        or return undef;

    QBitcoin::TXO->set_all($self->hash, \@out);
    return $self;
}

sub calculate_hash {
    my $self = shift;
    my ($tx_data) = @_;
    return sha256($tx_data);
}

sub validate {
    my $self = shift;
    # Transaction must contains at least one input (even coinbase!) and at least one output (can't spend all inputs as fee)
    if (!@{$self->in}) {
        Warningf("No inputs in transaction");
        return -1;
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
    return 0;
}

sub receive {
    my $self = shift;
    # TODO: Check that transaction is signed correctly
    $TRANSACTION{$self->hash} = $self;
    return 0;
}

1;
