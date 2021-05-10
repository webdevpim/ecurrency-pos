package QBitcoin::TXO;
use warnings;
use strict;

use QBitcoin::ORM qw(:types);
use QBitcoin::OpenScript;

use constant PRIMARY_KEY => qw(tx_in num);
use constant FIELDS => {
    value        => NUMERIC,
    num          => NUMERIC,
    tx_in        => NUMERIC,
    tx_out       => NUMERIC,
    close_script => BINARY,
    open_script  => BINARY,
};

use constant TABLE => "txo";
use constant TRANSACTION_TABLE => "transaction";

# hash by tx and out-num
my %TXO;

sub get {
    my $class = shift;
    my ($in) = @_;
    return $TXO{$in->{tx_out}}->[$in->{num}];
}

sub get_all {
    my $class = shift;
    my ($tx_hash) = @_;
    return $TXO{$tx_hash};
}

sub set_all {
    my $class = shift;
    my ($tx_hash, $out) = @_;
    $TXO{$tx_hash} = $out;
}

sub load {
    my $class = shift;
    my (@in) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, tx_out.hash AS tx_out, close_script, s.data as open_script";
    $sql .= " FROM " . $class->TABLE . " AS t JOIN " . QBitcoin::OpenScript->TABLE . " s ON (t.open_script = s.id)";
    $sql .= " JOIN " . TRANSACTION_TABLE . " AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " LEFT JOIN " . TRANSACTION_TABLE . " AS tx_out ON (tx_out.id = t.tx_out)";
    $sql .= " WHERE " . join(" OR ", ("(tx_in.hash = ? AND num = ?)")x@in);
    my $sth = $class->dbh->prepare($sql);
    $sth->execute(map { $_->{tx_out}, $_->{num} } @in);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        my $txo = $class->new($hash);
        $TXO{$hash->{tx_in}}->[$hash->{num}] = $txo;
        # Keep the txo in the %TXO hash until at least one reference (input or output) exists
        weaken($TXO{$hash->{tx_in}}->[$hash->{num}]);
        push @txo, $txo;
    }
    return @txo;
}

sub DESTROY {
    my $self = shift;
    delete $TXO{$self->tx_out}->[$self->num];
    delete $TXO{$self->tx_out} unless @{$TXO{$self->tx_out}};
}

sub store {
    my $self = shift;
    my ($tx_id) = @_;
    my $script = QBitcoin::OpenScript->store($self->open_script);
    my $sql = "REPLACE " . TABLE;
    $sql .= " SET value = ?, num = ?, tx_in = ?, open_script = ? tx_out = NULL, close_script = NULL";
    $self->dbh->do($sql, undef, $self->value, $self->num, $tx_id, $script->id);
}

sub store_spend {
    my $self = shift;
    my ($tx_id) = @_;
    my $sql = "UPDATE " . TABLE . " AS t JOIN " . TRANSACTION_TABLE . " AS tx_in ON (t.tx_in = tx_in.hash)";
    $sql .= " SET tx_out = ?, close_script = ? WHERE tx_in.hash = ? AND num = ?";
    my $res = $self->dbh->do($sql, undef, $tx_id, $self->close_script, $self->tx_in, $self->num);
    $res == 1
        or die "Can't store txo " . hex($self->tx_in) . ":" . $self->num . " as spend";
}

sub serialize {
    my $self = shift;
    return {
        value       => $self->value,
        open_script => $self->open_script,
    };
}

1;
