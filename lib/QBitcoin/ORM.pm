package QBitcoin::ORM;
use warnings;
use strict;

use DBI;
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

use parent 'Exporter';
our @EXPORT_OK = qw(open_db find create replace update lock db_start IGNORE);
push @EXPORT_OK, keys %{&DB_TYPES};
our %EXPORT_TAGS = ( types => [ keys %{&DB_TYPES} ] );

use constant DB_OPTS => {
    PrintError => 0,
    AutoCommit => 1,
    RaiseError => 1,
};

use constant KEY_RE => qr/^[a-z][a-z0-9_]*\z/;

use constant IGNORE => \undef; # { key => IGNORE } may be used to override default check for "key" column

sub open_db {
    my $dsn = $config->{"dsn"} // "DBI:mysql:" . DB_NAME . ";mysql_read_default_file=$ENV{HOME}/my.cnf:localhost";
    my $login = $config->{"db.login"};
    my $password = $config->{"db.password"};
    return DBI->connect_cached($dsn, undef, undef, DB_OPTS);
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
        $condition .= "AND " if $condition;
        if (ref $value eq 'ARRAY') {
            # "IN()" is sql syntax error, "IN(NULL)" matches nothing
            $condition .= "$key IN (" . (@$value ? join(',', ('?')x@$value) : "NULL") . ")";
            push @values, @$value;
        }
        elsif (ref $value eq 'HASH') {
            my $first = 1;
            foreach my $op (keys %$value) {
                $condition .= "AND " unless $first;
                my $v = $value->{$op};
                if (ref $v eq 'SCALAR') {
                    $condition .= "$key $op $$v";
                }
                if (ref $v eq 'ARRAY') { # key => { not => [ 'value1', 'value2 ] }
                    $condition .= "$key $op IN (" . (@$value ? join(',', ('?')x@$value) : "NULL") . ")";
                    push @values, @$value;
                }
                else {
                    $condition .= "$key $op ?";
                    push @values, $v;
                }
                $first = 0;
            }
        }
        elsif (ref $value eq 'SCALAR') {
            $condition .= "$key = $$value" if defined $$value; # \undef is IGNORE
        }
        elsif (defined $args->{$key}) {
            $condition .= "$key = ?";
            push @values, $value;
        }
        else {
            $condition .= "$key IS NULL";
        }
    }
    $sql .= " WHERE $condition" if $condition;
    $sql .= " ORDER BY $sortby" if $sortby;
    $limit = 1 unless wantarray;
    $sql .= " LIMIT $limit" if $limit;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@values);
    my @result;
    while (my $res = $sth->fetchrow_hashref()) {
        push @result, $class->new($res);
    }
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
    $dbh->do($sql, undef, @values);
    my $self = $class->new($args);
    if ($class->FIELDS->{id}) {
        my ($id) = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");
        $self->{id} = $id;
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
        $sql .= $class->FIELDS->{$key} == TIMESTAMP ? "FROM_UNIXTIME(?)" : "?";
        push @values, $self->$key;
    }
    $dbh->do($sql, undef, @values);
    if ($class->FIELDS->{id}) {
        my ($id) = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");
        $self->{id} = $id;
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
    $sql .= " WHERE id = ?";
    $dbh->do($sql, undef, @values, $self->id);
}

# Lock until end of $dbh connection
sub lock {
    my $class = shift;

    my $dbh = open_db();
    my $table = $class->TABLE;
    $dbh->do("SELECT GET_LOCK(?, ?)", undef, $table, 0)
        or die "Cannot lock $table";
    return $dbh;
}

sub db_start {
    my $self = shift;

    # TODO
    return undef;
}

1;
