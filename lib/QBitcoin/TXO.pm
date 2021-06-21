package QBitcoin::TXO;
use warnings;
use strict;

use Scalar::Util qw(weaken refaddr);
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ORM qw(:types dbh find DEBUG_ORM);
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
    open_script  => NUMERIC,
};

use constant TABLE => "txo";
use constant TRANSACTION_TABLE => "transaction";

mk_accessors(keys %{&FIELDS});

# hash by tx and out-num
my %TXO;

sub key {
    my $self = shift;
    return $self->tx_in . $self->num;
}

sub save {
    my $self = shift;
    my $key = $self->key;
    if ($TXO{$key}) {
        Errf("Attempt to override already loaded txo %s:%u", $self->tx_in_str, $self->num);
        die "Attempt to override already loaded txo " . $self->tx_in_str. ":" . $self->num . "\n";
    }
    $TXO{$key} = $self;
    # Keep the txo in the %TXO hash until at least one reference (input or output) exists
    weaken($TXO{$key});
    return $self;
}

sub save_all {
    my $class = shift;
    my ($tx_hash, $out) = @_;
    my $num = 0;
    foreach (@$out) {
        $_->tx_in = $tx_hash;
        $_->num   = $num++;
        $_->save;
    }
}

sub get {
    my $class = shift;
    my ($in) = @_;
    return $TXO{$in->{tx_out} . $in->{num}};
}

# Create new transaction output, it cannot be already cached
sub new_txo {
    my $class = shift;
    my $hash = @_ == 1 ? $_[0] : { @_ };
    return bless $hash, $class;
}

# Create TXO by load from the database, use cached if any but do not store in cache if not
# b/c we want to ignore already loaded (and used in some transaction) txo in produce new transaction
sub new {
    my $class = shift;
    my $hash = @_ == 1 ? $_[0] : { @_ };
    return $class->get({ tx_out => $hash->{tx_in}, num => $hash->{num} })
        // $class->new_txo($hash);
}

# Create TXO, use cached if any and save in cache otherwise
sub new_saved {
    my $class = shift;
    my $hash = @_ == 1 ? $_[0] : { @_ };
    if (my $self = $class->get({ tx_out => $hash->{tx_in}, num => $hash->{num} })) {
        return $self;
    }
    else {
        my $self = $class->new_txo($hash);
        $self->save;
        return $self;
    }
}

# For new transaction load list of its input txo
sub load {
    my $class = shift;
    my (@in) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, tx_out.hash AS tx_out, close_script, s.data as open_script";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN " . QBitcoin::OpenScript->TABLE . " s ON (t.open_script = s.id)";
    $sql .= " JOIN `" . TRANSACTION_TABLE . "` AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " LEFT JOIN `" . TRANSACTION_TABLE . "` AS tx_out ON (tx_out.id = t.tx_out)";
    $sql .= " WHERE " . join(" OR ", ("(tx_in.hash = ? AND num = ?)")x@in);
    DEBUG_ORM && Debugf("sql: [%s] values [%s]", $sql, join(',', map { "X'" . unpack("H*", $_->{tx_out}) . "'", $_->{num} } @in));
    my $sth = dbh->prepare($sql);
    $sth->execute(map { $_->{tx_out}, $_->{num} } @in);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        my $txo = $class->new_saved($hash);
        push @txo, $txo;
    }
    return @txo;
}

sub is_cached {
    my $self = shift;
    if ($self->tx_in) {
        my $key = $self->key;
        if ($TXO{$key} && refaddr($self) == refaddr($TXO{$key})) {
            return 1;
        }
    }
    return 0;
}

sub DESTROY {
    my $self = shift;
    # Compare pointers to avoid removing from the cache by destroy unlinked object
    if ($self->tx_in) {
        my $key = $self->key;
        my $cached = $TXO{$self->tx_in};
        if ($TXO{$key} && refaddr($self) == refaddr($TXO{$key})) {
            delete $TXO{$key};
        }
    }
}

sub store {
    my $self = shift;
    my ($tx) = @_;
    my $script = QBitcoin::OpenScript->store($self->open_script);
    my $sql = "REPLACE INTO `" . TABLE . "` (value, num, tx_in, open_script, tx_out, close_script) VALUES (?,?,?,?,NULL,NULL)";
    DEBUG_ORM && Debugf("dbi [%s] values [%u,%u,%u,%u]", $sql, $self->value, $self->num, $tx->id, $script->id);
    my $res = dbh->do($sql, undef, $self->value, $self->num, $tx->id, $script->id);
    $res == 1
        or die "Can't store txo " . $self->tx_in_str . ":" . $self->num . ": " . (dbh->errstr // "no error") . "\n";
}

sub store_spend {
    my $self = shift;
    my ($tx) = @_;
    my $sql = "UPDATE `" . TABLE . "` AS t JOIN `" . TRANSACTION_TABLE . "` AS tx_in ON (t.tx_in = tx_in.id)";
    $sql .= " SET tx_out = ?, close_script = ? WHERE tx_in.hash = ? AND num = ?";
    DEBUG_ORM && Debugf("dbi [%s] values [%u,X'%s',X'%s',%u]", $sql, $tx->id, unpack("H*", $self->close_script), unpack("H*", $self->tx_in), $self->num);
    my $res = dbh->do($sql, undef, $tx->id, $self->close_script, $self->tx_in, $self->num);
    $res == 1
        or die "Can't store txo " . $self->tx_in_str . ":" . $self->num . " as spend: " . (dbh->errstr // "no error") . "\n";
}

# Load all inputs for stored transaction after load from database
sub load_stored_inputs {
    my $class = shift;
    my ($tx_id, $tx_hash) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, close_script, s.data as open_script";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::OpenScript->TABLE . "` s ON (t.open_script = s.id)";
    $sql .= " JOIN `" . TRANSACTION_TABLE . "` AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " WHERE tx_out = ?";
    my $sth = dbh->prepare($sql);
    DEBUG_ORM && Debugf("sql: [%s] values [%u]", $sql, $tx_id);
    $sth->execute($tx_id);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        $hash->{tx_out} = $tx_hash;
        my $txo = $class->new_saved($hash);
        $txo->tx_out && $txo->tx_out eq $tx_hash
            or die sprintf("Cached txo %s:%u has no tx_out %s\n", $txo->tx_in_str, $txo->num, unpack("H*", substr($tx_hash, 0, 4)));
        push @txo, $txo;
    }
    return @txo;
}

# Load all outputs for stored transaction after load from database
sub load_stored_outputs {
    my $class = shift;
    my ($tx_id, $tx_hash) = @_;
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_out.hash AS tx_out, close_script, s.data as open_script";
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN " . QBitcoin::OpenScript->TABLE . " s ON (t.open_script = s.id)";
    $sql .= " LEFT JOIN `" . TRANSACTION_TABLE . "` AS tx_out ON (tx_out.id = t.tx_out)";
    $sql .= " WHERE tx_in = ?";
    my $sth = dbh->prepare($sql);
    DEBUG_ORM && Debugf("sql: [%s] values [%u]", $sql, $tx_id);
    $sth->execute($tx_id);
    my @txo;
    while (my $hash = $sth->fetchrow_hashref()) {
        $hash->{tx_in} = $tx_hash;
        my $txo = $class->new_saved($hash);
        push @txo, $txo;
    }
    return @txo;
}

# Called from find() just before create new object
# Used for load my UTXO on startup and for "produce" random transaction, so optimization is not a point here
sub pre_load {
    my $class = shift;
    my ($attr) = @_;
    # load tx_in, tx_out as hashes; open_script as data instead of id
    # TODO: move this to QBitcoin::ORM
    my $sql = "SELECT value, num, tx_in.hash AS tx_in, s.data as open_script";
    $sql .= ", tx_out.hash AS tx_out" if $attr->{tx_out};
    $sql .= " FROM `" . $class->TABLE . "` AS t JOIN `" . QBitcoin::OpenScript->TABLE . "` s ON (t.open_script = s.id)";
    $sql .= " JOIN `" . TRANSACTION_TABLE . "` AS tx_in ON (tx_in.id = t.tx_in)";
    $sql .= " LEFT JOIN `" . TRANSACTION_TABLE . "` AS tx_out ON (tx_out.id = t.tx_out)" if $attr->{tx_out};
    $sql .= " WHERE tx_in.id = ? AND num = ?";
    DEBUG_ORM && Debugf("sql: [%s] values [%u,%u]", $sql, $attr->{tx_in}, $attr->{num});
    my $hash = dbh->selectrow_hashref($sql, undef, $attr->{tx_in}, $attr->{num});
    if ($hash) {
        $attr->{tx_in}       = $hash->{tx_in};
        $attr->{tx_out}      = $hash->{tx_out} if $attr->{tx_out};
        $attr->{open_script} = $hash->{open_script};
    }
    return $attr;
}

# $self->{spent} is not complete list of spent transactions for the txo; here are only in-memory transactions (mempool dependency)
sub spent_add {
    my $self = shift;
    my ($tx) = @_;
    $self->{spent} //= {}; # I am suspicious of autovivification
    $self->{spent}->{$tx->hash} = $tx;
}

sub spent_del {
    my $self = shift;
    my ($tx) = @_;
    delete $self->{spent}->{$tx->hash};
}

sub spent_list {
    my $self = shift;
    return $self->{spent} ? values %{$self->{spent}} : ();
}

sub check_script {
    my $self = shift;
    my ($close_script, $sign_data) = @_;
    return QBitcoin::OpenScript->check_input($self->open_script, $close_script, $sign_data);
}

sub tx_in_str {
    my $self = shift;
    return unpack("H*", substr($self->tx_in, 0, 4));
}

sub tx_out_str {
    my $self = shift;
    return unpack("H*", substr($self->tx_out, 0, 4));
}

1;
