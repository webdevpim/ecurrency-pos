package QBitcoin::TXO;
use warnings;
use strict;

use Scalar::Util qw(weaken);
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ORM qw(:types open_db find);
use QBitcoin::OpenScript;

use Role::Tiny::With;
with 'QBitcoin::TXO::My';

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

mk_accessors(keys %{&FIELDS});

# hash by tx and out-num
my %TXO;

sub new {
    my $class = shift;
    my $hash = @_ == 1 ? $_[0] : { @_ };
    my $self;
    if ($hash->{tx_in}) {
        if (!($self = $TXO{$hash->{tx_in}}->[$hash->{num}])) {
            $self = bless $hash, $class;
            if ($self->is_my) {
                $self->add_my_txo();
            }
        }
    }
    else {
        $self = bless $hash, $class;
    }
    return $self;
}

sub save {
    my $self = shift;
    if (!defined $TXO{$self->tx_in}->[$self->num]) {
        $TXO{$self->tx_in}->[$self->num] = $self;
        # Keep the txo in the %TXO hash until at least one reference (input or output) exists
        weaken($TXO{$self->tx_in}->[$self->num]);
    }
}

sub save_all {
    my $class = shift;
    my ($tx_hash, $out) = @_;
    $TXO{$tx_hash} = $out;
}

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

# For new transaction load list of its input txo
sub load {
    my $class = shift;
    my (@in) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, tx_out.hash AS tx_out, close_script, s.data as open_script";
    $sql .= " FROM " . $class->TABLE . " AS t JOIN " . QBitcoin::OpenScript->TABLE . " s ON (t.open_script = s.id)";
    $sql .= " JOIN " . TRANSACTION_TABLE . " AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " LEFT JOIN " . TRANSACTION_TABLE . " AS tx_out ON (tx_out.id = t.tx_out)";
    $sql .= " WHERE " . join(" OR ", ("(tx_in.hash = ? AND num = ?)")x@in);
    my $sth = open_db->prepare($sql);
    $sth->execute(map { $_->{tx_out}, $_->{num} } @in);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        my $txo = $class->new($hash);
        $txo->save;
        push @txo, $txo;
    }
    return @txo;
}

sub DESTROY {
    my $self = shift;
    if ($self->tx_in) {
        delete $TXO{$self->tx_in}->[$self->num];
        delete $TXO{$self->tx_in} unless @{$TXO{$self->tx_in}};
    }
}

sub store {
    my $self = shift;
    my ($tx) = @_;
    my $script = QBitcoin::OpenScript->store($self->open_script);
    my $sql = "REPLACE " . TABLE;
    $sql .= " SET value = ?, num = ?, tx_in = ?, open_script = ?, tx_out = NULL, close_script = NULL";
    open_db->do($sql, undef, $self->value, $self->num, $tx->id, $script->id);
}

sub store_spend {
    my $self = shift;
    my ($tx) = @_;
    my $sql = "UPDATE " . TABLE . " AS t JOIN " . TRANSACTION_TABLE . " AS tx_in ON (t.tx_in = tx_in.hash)";
    $sql .= " SET tx_out = ?, close_script = ? WHERE tx_in.hash = ? AND num = ?";
    my $res = open_db->do($sql, undef, $tx->id, $self->close_script, $self->tx_in, $self->num);
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

# Load all inputs for stored transaction after load from database
sub load_inputs {
    my $class = shift;
    my ($tx) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, close_script, s.data as open_script";
    $sql .= " FROM " . $class->TABLE . " AS t JOIN " . QBitcoin::OpenScript->TABLE . " s ON (t.open_script = s.id)";
    $sql .= " JOIN " . TRANSACTION_TABLE . " AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " WHERE tx_out = ?";
    my $sth = open_db->prepare($sql);
    $sth->execute($tx->id);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        $hash->{tx_out} = $tx->hash;
        my $txo = $class->new($hash);
        $txo->save;
        push @txo, $txo;
    }
    return @txo;
}

# Load all outputs for stored transaction after load from database
sub load_outputs {
    my $class = shift;
    my ($tx) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_out.hash AS tx_out, close_script, s.data as open_script";
    $sql .= " FROM " . $class->TABLE . " AS t JOIN " . QBitcoin::OpenScript->TABLE . " s ON (t.open_script = s.id)";
    $sql .= " LEFT JOIN " . TRANSACTION_TABLE . " AS tx_out ON (tx_out.id = t.tx_out)";
    $sql .= " WHERE tx_out = ?";
    my $sth = open_db->prepare($sql);
    $sth->execute($tx->id);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        $hash->{tx_in} = $tx->hash;
        my $txo = $class->new($hash);
        $txo->save;
        push @txo, $txo;
    }
    return @txo;
}

# Called from find() after create new object
# Used for load my UTXO on startup and for "produce" random transaction, so optimization is not a point here
sub on_load {
    my $self = shift;
    # load tx_in, tx_out as hashes; open_script as data instead of id
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, s.data as open_script";
    $sql .= ", tx_out.hash AS tx_out" if $self->{tx_out};
    $sql .= " FROM " . $self->TABLE . " AS t JOIN " . QBitcoin::OpenScript->TABLE . " s ON (t.open_script = s.id)";
    $sql .= " JOIN " . TRANSACTION_TABLE . " AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " LEFT JOIN " . TRANSACTION_TABLE . " AS tx_out ON (tx_out.id = t.tx_out)" if $self->{tx_out};
    $sql .= " WHERE tx_in.id = ? AND num = ?";
    my $hash = open_db->selectrow_hashref($sql, undef, $self->{tx_in}, $self->{num});
    if ($hash) {
        $self->{tx_in}  = $hash->{tx_in};
        $self->{tx_out} = $hash->{tx_out} if $self->{tx_out};
        $self->{open_script} = $hash->{open_script};
    }
    return $self;
}

sub check_script {
    my $self = shift;
    my ($close_script) = @_;
    return QBitcoin::OpenScript->check_input($self->open_script, $close_script);
}

1;
