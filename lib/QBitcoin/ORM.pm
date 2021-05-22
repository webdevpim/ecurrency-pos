package QBitcoin::ORM;
use warnings;
use strict;

use DBI;
use JSON::XS;
use QBitcoin::Config;
use QBitcoin::Log;

use constant DB_NAME => 'qbitcoin';

use constant DB_TYPES => {
    NUMERIC   => 1,
    STRING    => 2,
    TIMESTAMP => 3,
    BINARY    => 4,
};
use constant DB_TYPES;

use constant DEBUG_ORM => 1;

use parent 'Exporter';
our @EXPORT_OK = qw(open_db find create replace update lock db_start IGNORE $DBH DEBUG_ORM);
push @EXPORT_OK, keys %{&DB_TYPES};
our %EXPORT_TAGS = ( types => [ keys %{&DB_TYPES} ] );

use constant DB_OPTS => {
    PrintError => 0,
    AutoCommit => 1,
    RaiseError => 1,
};

use constant KEY_RE => qr/^[a-z][a-z0-9_]*\z/;

use constant IGNORE => \undef; # { key => IGNORE } may be used to override default check for "key" column

our $DBH; # controlled by QBitcoin::ORM::Transaction

sub open_db {
    my ($transaction) = @_;
    return $DBH if $DBH; # for transaction
    my $dsn = $config->{"dsn"} // "DBI:mysql:" . DB_NAME . ";mysql_read_default_file=$ENV{HOME}/my.cnf:localhost";
    my $login = $config->{"db.login"};
    my $password = $config->{"db.password"};
    my $db_opts = DB_OPTS;
    $db_opts->{AutoCommit} = 0 if $transaction;
    my $method = $transaction ? "connect" : "connect_cached";
    return DBI->$method($dsn, $login, $password, $db_opts);
}

sub find {
    my $class = shift;
    my $args = ref $_[0] ? $_[0] : { @_ };

    my $dbh = open_db();
    my $table = $class->TABLE
        or die "No TABLE defined in $class\n";
    my $sql = "SELECT " .
        join(', ', map { $class->FIELDS->{$_} == TIMESTAMP ? "UNIX_TIMESTAMP($_) AS $_" : $_ } keys %{$class->FIELDS}) .
        " FROM $table";
    my @values;
    my $condition = '';
    my $sortby;
    my $limit;
    foreach my $key (keys %$args) {
        if ($key eq '-sortby') {
            $sortby = $args->{$key};
            next;
        }
        if ($key eq '-limit') {
            $limit = $args->{$key};
            next;
        }
        $key =~ KEY_RE
            or die "Incorrect search key [$key]";
        my $value = $args->{$key};
        my $type = $class->FIELDS->{$key}
            or die "Unknown search key [$key] for " . $class->TABLE . "\n";
        $condition .= " AND" if $condition;
        if (ref $value eq 'ARRAY') {
            # "IN()" is sql syntax error, "IN(NULL)" matches nothing
            $condition .= " $key IN (" . (@$value ? join(',', ('?')x@$value) : "NULL") . ")";
            push @values, @$value;
        }
        elsif (ref $value eq 'HASH') {
            my $first = 1;
            foreach my $op (keys %$value) {
                $condition .= " AND" unless $first;
                my $v = $value->{$op};
                if (ref $v eq 'SCALAR') {
                    $condition .= "$key $op $$v ";
                }
                elsif (ref $v eq 'ARRAY') { # key => { not => [ 'value1', 'value2 ] }
                    $condition .= " $key $op IN (" . (@$value ? join(',', ('?')x@$value) : "NULL") . ")";
                    push @values, @$value;
                }
                elsif (ref $v) {
                    die "Incorrect search value type " . ref($v) . " key $key\n";
                }
                else {
                    $condition .= " $key $op ?";
                    push @values, $v;
                }
                $first = 0;
            }
        }
        elsif (ref $value eq 'SCALAR') {
            $condition .= " $key = $$value" if defined $$value; # \undef is IGNORE
        }
        elsif (ref $value) {
            die "Incorrect search value type " . ref($value) . " key $key\n";
        }
        elsif (defined $value) {
            if ($type == TIMESTAMP) {
                $condition .= " $key = FROM_UNIXTIME(?)";
                push @values, $value;
            }
            if ($type == BINARY) {
                # Is it needed?
                $condition .= " $key = UNHEX(?)";
                push @values, unpack("H*", $value);
            }
            else {
                $condition .= " $key = ?";
                push @values, $value;
            }
        }
        else {
            $condition .= " $key IS NULL";
        }
    }
    $sql .= " WHERE$condition"  if $condition;
    $sql .= " ORDER BY $sortby" if $sortby;
    $limit = 1 unless wantarray;
    $sql .= " LIMIT $limit" if $limit;
    DEBUG_ORM && Debugf("sql: [%s], values: [%s]", $sql, join(',', map { $_ // "undef" } @values));
    my $sth = $dbh->prepare($sql);
    $sth->execute(@values);
    my @result;
    while (my $res = $sth->fetchrow_hashref()) {
        DEBUG_ORM && Debugf("orm: found %s", encode_json($res));
        my $item = $class->new($res);
        $item->on_load if $class->can('on_load');
        push @result, $item;
    }
    DEBUG_ORM && Debugf("orm: found %u entries, errstr [%s]", scalar(@result), $dbh->errstr // '');
    return wantarray ? @result : $result[0];
}

sub create {
    my $class = shift;
    my $args = ref $_[0] ? $_[0] : { @_ };

    my $dbh = open_db();
    my $table = $class->TABLE
        or die "No TABLE defined in $class\n";
    my $sql = "INSERT INTO $table SET ";
    my @values;
    foreach my $key (keys %$args) {
        $key =~ KEY_RE
            or die "Incorrect key [$key]";
        $sql .= ", " if @values;
        $sql .= "$key = ";
        $sql .= $class->FIELDS->{$key} == TIMESTAMP ? "FROM_UNIXTIME(?)" : "?";
        push @values, $args->{$key};
    }
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', map { $_ // "undef" } @values));
    $dbh->do($sql, undef, @values);
    my $self = $class->new($args);
    if ($class->FIELDS->{id}) {
        my ($id) = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");
        $self->{id} = $id;
        DEBUG_ORM && Debugf("orm: last_insert_id: %u", $id);
    }
    return $self;
}

sub replace {
    my $self = shift;

    my $dbh = open_db();
    my $class = ref($self);
    my $table = $class->TABLE
        or die "No TABLE defined in $class\n";
    my $sql = "REPLACE $table SET ";
    my @values;
    foreach my $key (keys %{$class->FIELDS}) {
        $key =~ KEY_RE
            or die "Incorrect key [$key]";
        $sql .= ", " if @values;
        $sql .= "$key = ";
        my $type = $class->FIELDS->{$key}
            or die "Unknown key [$key] for $table\n";
        if ($type == TIMESTAMP) {
            $sql .= "FROM_UNIXTIME(?)";
            push(@values, $self->$key);
        }
        elsif ($type == BINARY) {
            $sql .= "UNHEX(?)";
            push(@values, unpack("H*", $self->$key));
        }
        else {
            $sql .= "?";
            push(@values, $self->$key);
        }
    }
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', map { $_ // "undef" } @values));
    $dbh->do($sql, undef, @values);
    if ($class->FIELDS->{id}) {
        my ($id) = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");
        $self->{id} = $id;
        DEBUG_ORM && Debugf("orm: last_insert_id: %u", $id);
    }
    return $self;
}

sub update {
    my $self = shift;
    my $args = ref $_[0] ? $_[0] : { @_ };

    return unless %$args;
    my $dbh = open_db();
    my $table = $self->TABLE
        or die "No TABLE defined in " . ref($self) . "\n";
    my $sql = "UPDATE $table SET ";
    my @values;
    my $count;
    foreach my $key (keys %$args) {
        $key =~ KEY_RE
            or die "Incorrect key [$key]";
        $sql .= ", " if $count++;
        my $value = $args->{$key};
        if (ref $value eq "SCALAR") {
            $sql .= "$key = $$value";
        }
        else {
            $sql .= $self->FIELDS->{$key} == TIMESTAMP ? "$key = FROM_UNIXTIME(?)" : "$key = ?";
            push @values, $args->{$key};
        }
    }
    my @pk_values;
    if ($self->can('PRIMARY_KEY')) {
        $sql .= " WHERE " . join(" AND ", map { "$_ = ?" } $self->PRIMARY_KEY);
        @pk_values = map { $self->$_ } $self->PRIMARY_KEY;
    }
    else {
        $sql .= " WHERE id = ?";
        @pk_values = ($self->id);
    }
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', map { $_ // "undef" } @values, @pk_values));
    $dbh->do($sql, undef, @values, @pk_values);
}

1;
