package QBitcoin::Transaction;
use warnings;
use strict;

use JSON::XS;
use Tie::IxHash;
use List::Util qw(sum0);
use Scalar::Util qw(refaddr);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ORM qw(find fetch create delete :types);
use QBitcoin::Crypto qw(hash256);
use QBitcoin::TXO;
use QBitcoin::Coinbase;
use QBitcoin::ConnectionList;
use Bitcoin::Serialized;

use Role::Tiny::With;
with 'QBitcoin::Transaction::Signature';

use constant FIELDS => {
    id           => NUMERIC, # db primary key for reference links
    hash         => BINARY,
    block_height => NUMERIC,
    fee          => NUMERIC,
    size         => NUMERIC,
};

use constant TABLE => 'transaction';

use constant ATTR => qw(
    received_time
    received_from
    in
    out
    up
    blocks
    block_sign_data
    rcvd
);

mk_accessors(keys %{&FIELDS}, ATTR);

my $JSON = JSON::XS->new->utf8(1)->convert_blessed(1)->canonical(1);

my %TRANSACTION;      # in-memory cache transaction objects by tx_hash
my %PENDING_INPUT_TX; # 2-level hash $pending_hash => $hash; value 1
my %PENDING_TX_INPUT; # 2-level hash $hash => $pending_hash; value - pointer to serialized transaction data
tie(%PENDING_TX_INPUT, 'Tie::IxHash'); # Ordered by age, to remove oldest

END {
    # Free all references to txo for graceful free %TXO hash
    undef %TRANSACTION;
};

sub get_by_hash { # cached or load from database
    my $class = shift;
    my ($tx_hash) = @_;

    return $class->get($tx_hash) // $class->find(hash => $tx_hash);
}

# return block_height or undef for unknown transaction, -1 for mempool (unconfirmed)
sub check_by_hash {
    my $class = shift;
    my ($tx_hash) = @_;

    my $block_height;
    if (my $tx = $class->get($tx_hash)) {
        $block_height = $tx->block_height // -1;
    }
    elsif (my ($tx_hash) = $class->fetch(hash => $tx_hash)) {
        $block_height = $tx_hash->{block_height};
    }
    else {
        return undef;
    }
    return $block_height || "0e0";
}

sub get { # only cached
    my $class = shift;
    my ($tx_hash) = @_;

    return $TRANSACTION{$tx_hash};
}

sub receive {
    my $self = shift;

    if ($TRANSACTION{$self->hash}) {
        die "receive already loaded transaction " . $self->hash_str . "\n";
    }

    foreach my $in (@{$self->in}) {
        $in->{txo}->spent_add($self);
        # Exclude from my utxo spent unconfirmed, do not use them for stake transactions
        $in->{txo}->del_my_utxo() if $self->fee >= 0 && $in->{txo}->is_my;
    }

    $TRANSACTION{$self->hash} = $self;
    if ($self->up) {
        # This transaction is already validated
        $self->up->store;
    }
    return 0;
}

sub process_pending {
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my $self = shift;
    my ($protocol) = @_;
    if (my $pending = delete $PENDING_INPUT_TX{$self->hash}) {
        foreach my $hash (keys %$pending) {
            my $tx_data_p = delete $PENDING_TX_INPUT{$hash}->{$self->hash};
            if (!%{$PENDING_TX_INPUT{$hash}}) {
                delete $PENDING_TX_INPUT{$hash};
                Debugf("Process transaction %s pending for %s", $self->hash_str($hash), $self->hash_str);
                my $class = ref $self;
                my $data = Bitcoin::Serialized->new($$tx_data_p);
                if (my $tx = $class->deserialize($data, $protocol)) {
                    $protocol->process_tx($tx);
                }
            }
        }
    }
}

sub add_to_block {
    my $self = shift;
    my ($block) = @_;
    $self->{blocks}->{$block->hash} = 1;
}

sub del_from_block {
    my $self = shift;
    my ($block) = @_;
    delete $self->{blocks}->{$block->hash};
    if (!%{$self->{blocks}}) {
        if (defined($self->block_height)) {
            # Confirmed, not mempool
            $self->free();
        }
        elsif ($self->fee < 0) {
            # Stake
            $self->free();
        }
    }
}

sub in_blocks {
    my $self = shift;
    return $self->{blocks} ? (keys %{$self->{blocks}}) : ();
}

sub mempool_list {
    my $class = shift;
    return grep { !defined($_->block_height) && $_->fee >= 0 } values %TRANSACTION;
}

# This method calls when the confirmed transaction stored into the database and is not needed in memory anymore
# TXO (input and output) will free from %TXO hash by DESTROY() method, they have weaken reference for this
sub free {
    my $self = shift;
    return if $self->in_blocks;
    if (defined($self->block_height) && !$self->id) {
        die "Attempt to free not stored transaction " . $self->hash_str . " confirmed in block " . $self->block_height . "\n";
    }
    foreach my $in (@{$self->in}) {
        $in->{txo}->spent_del($self);
    }
    delete $TRANSACTION{$self->hash};
}

# Drop the transaction from mempool and all dependent transactions if any
sub drop {
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my $self = shift;
    if (defined($self->block_height)) {
        Errf("Attempt to drop confirmed transaction %s, block height %u", $self->hash_str, $self->block_height);
        die "Can't drop confirmed transaction " . $self->hash_str . "\n";
    }
    if ($self->in_blocks) {
        Debugf("Transaction %s is in loaded unconfirmed blocks, do not drop", $self->hash_str);
        return;
    }
    Debugf("Drop transaction %s from mempool", $self->hash_str);
    foreach my $out (@{$self->out}) {
        $out->del_my_utxo if $out->is_my;
        foreach my $dep_tx ($out->spent_list) {
            Infof("Drop transaction %s dependent on %s", $dep_tx->hash_str, $self->hash_str);
            $dep_tx->drop;
        }
    }
    foreach my $in (@{$self->in}) {
        my $txo = $in->{txo};
        $txo->spent_del($self);
        if ($txo->is_my && !$txo->spent_list) {
            # add to my_utxo list only if it was confirmed in the best branch
            my $class = ref $self;
            my $tx_in = $class->get($txo->tx_in);
            if (!$tx_in || defined($tx_in->block_height)) {
                $txo->add_my_utxo;
            }
        }
    }
    delete $TRANSACTION{$self->hash};
}

sub store {
    my $self = shift;
    $self->is_cached or die "store not cached transaction " . $self->hash_str;
    # we are in sql transaction
    $self->create();
    foreach my $in (@{$self->in}) {
        my $txo = $in->{txo};
        $txo->store_spend($self),
    }
    foreach my $txo (@{$self->out}) {
        $txo->store($self);
    }
    if (my $coinbase = $self->up) {
        $coinbase->store_published($self);
    }
    # TODO: store tx data (smartcontract)
}

sub hash_str {
    my $arg = pop;
    my $hash = ref($arg) ? $arg->hash : $arg;
    return unpack("H*", substr($hash, 0, 4));
}

sub data { "" } # TODO

sub serialize {
    my $self = shift;

    my $data = varint(scalar @{$self->in});
    $data .= serialize_input($_) foreach @{$self->in};
    $data .= varint(scalar @{$self->out});
    $data .= serialize_output($_) foreach @{$self->out};
    if (!@{$self->in}) {
        $data .= UPGRADE_POW ? serialize_coinbase($self->up) : pack("Q<", $self->coins_created);
    }
    elsif (UPGRADE_POW ? $self->up : $self->coins_created) {
        die "Incorrect transaction (both input and coinbase), can't serialize " . $self->hash_str . "\n";
    }
    $data .= varstr($self->data);
    return $data;
}

sub sign_data {
    my $self = shift;

    my $data;
    if (!defined($data = $self->{sign_data})) {
        $data = varint(scalar @{$self->in});
        $data .= serialize_input_for_sign($_) foreach @{$self->in};
        $data .= varint(scalar @{$self->out});
        $data .= serialize_output($_) foreach @{$self->out};
        # We do not need to sign coinbase transactions
        $data .= varstr($self->data);
        $self->{sign_data} = $data;
    }
    if ($self->fee < 0) {
        # It's stake tx which signs block, add block info
        $data .= $self->block_sign_data;
    }
    return $data;
}

# For JSON RPC output
sub as_hashref {
    my $self = shift;
    return {
        hash => unpack("H*", $self->hash),
        fee  => $self->fee / DENOMINATOR,
        size => length($self->serialize),
        in   => [ map { input_as_hashref($_)  } @{$self->in}  ],
        out  => [ map { output_as_hashref($_) } @{$self->out} ],
        $self->up ? ( up => $self->up->as_hashref ) : (),
        !UPGRADE_POW && $self->coins_created ? ( coins_created => $self->coins_created / DENOMINATOR ) : (),
    };
}

sub input_as_hashref {
    my $in = shift;
    $in->{siglist} or die "Undefined siglist during input_as_hashref";
    return {
        tx_out        => unpack("H*", $in->{txo}->tx_in),
        num           => $in->{txo}->num+0,
        siglist       => [ map { unpack("H*", $_) } @{$in->{siglist}} ],
        redeem_script => unpack("H*", $in->{txo}->redeem_script // die "Undefined redeem_script during input_as_hashref"),
    };
}

sub serialize_siglist {
    my $siglist = shift;
    return varint(scalar @$siglist) . join("", map { varstr($_) } @$siglist);
}

sub serialize_input {
    my $in = shift;
    my $siglist = $in->{siglist} // die "Undefined siglist during serialize_input";
    my $redeem_script = $in->{txo}->redeem_script // die "Undefined redeem_script during serialize_input";
    return $in->{txo}->tx_in . varint($in->{txo}->num) . serialize_siglist($siglist) . varstr($redeem_script);
}

sub serialize_input_for_sign {
    my $in = shift;
    return $in->{txo}->tx_in . varint($in->{txo}->num);
}

sub deserialize_siglist {
    my $data = shift;
    my $num = $data->get_varint() // return undef;
    my @siglist = map { $data->get_string() // return undef } 1 .. $num;
    return \@siglist;
}

sub deserialize_input {
    my $data = shift;
    return {
        tx_out        => ( $data->get(32) // return undef ),
        num           => ( $data->get_varint() // return undef ),
        siglist       => ( deserialize_siglist($data) // return undef ),
        redeem_script => ( $data->get_string() // return undef ),
    };
}

sub serialize_output {
    my $out = shift;
    return pack("Q<", $out->value) . varstr($out->scripthash);
}

sub deserialize_output {
    my $data = shift;
    return {
        value      => unpack("Q<", $data->get(8) // return undef),
        scripthash => ( $data->get_string() // return undef ),
    };
}

sub output_as_hashref {
    my $out = shift;
    return {
        value      => $out->value / DENOMINATOR,
        scripthash => unpack("H*", $out->scripthash),
    };
}

sub serialize_coinbase {
    my $coinbase = shift;
    return $coinbase->serialize;
}

sub deserialize_coinbase {
    my $data = shift;
    return QBitcoin::Coinbase->deserialize($data);
}

sub deserialize {
    my $class = shift;
    my ($data, $protocol) = @_;
    my $start_index = $data->index;
    my @input  = map { deserialize_input($data)  // return undef } 1 .. ($data->get_varint // return undef);
    my @output = map { deserialize_output($data) // return undef } 1 .. ($data->get_varint // return undef);
    my $up;
    if (!@input) {
        $up = UPGRADE_POW ? (deserialize_coinbase($data) // return undef) : unpack("Q<", $data->get(8) // return undef);
    }
    my $tx_data = $data->get_string() // return undef;
    my $end_index = $data->index;
    $data->index = $start_index;
    my $tx_raw_data = $data->get($end_index - $start_index);
    my $hash = tx_data_hash($tx_raw_data);
    if ($PENDING_TX_INPUT{$hash}) {
        Debugf("Transaction %s already pending", $class->hash_str($hash));
        return "";
    }
    if ($class->check_by_hash($hash)) {
        Debugf("Transaction %s already known", $class->hash_str($hash));
        return "";
    }
    my ($in, $unknown) = $class->load_inputs(\@input, $hash, $protocol);
    if (!$in) {
        return undef;
    }
    if (@$unknown) {
        # put the transaction into separate "waiting" pull (limited size) and reprocess it by each received transaction
        foreach my $tx_in (@$unknown) {
            Debugf("Save transaction %s as pending for %s", $class->hash_str($hash), $class->hash_str($tx_in));
            $PENDING_INPUT_TX{$tx_in}->{$hash} = 1;
            $PENDING_TX_INPUT{$hash}->{$tx_in} = \$tx_raw_data;
        }
        if (keys %PENDING_TX_INPUT > MAX_PENDING_TX) {
            my ($oldest_hash) = keys %PENDING_TX_INPUT;
            foreach my $tx_in (keys %{$PENDING_TX_INPUT{$oldest_hash}}) {
                delete $PENDING_INPUT_TX{$tx_in}->{$oldest_hash};
            }
            Debugf("Drop transaction %s from pending pool", $class->hash_str($oldest_hash));
            delete $PENDING_TX_INPUT{$oldest_hash};
        }
        return ""; # Ignore transactions with unknown inputs
    }

    my $self = $class->new(
        in            => $in,
        out           => create_outputs(\@output, $hash),
        $up ? UPGRADE_POW ? ( up => $up ) : ( coins_created => $up ) : (),
        # data          => $tx_data, # TODO
        hash          => $hash,
        size          => $end_index - $start_index,
        received_time => time(),
    );

    $self->calculate_hash; # this is just for check that received data is equal to serialized created transaction
    if ($self->hash ne $hash) {
        Warningf("Incorrect serialized transaction has different hash: %s: %s", $self->hash_str, $self->hash_str($hash));
        return undef;
    }

    $self->fee = sum0(map { $_->{txo}->value } @$in) + $self->coins_created - sum0(map { $_->{value} } @output);

    return $self;
}

sub coins_created {
    my $self = shift;

    if (UPGRADE_POW) {
        return $self->up ? $self->up->value : 0;
    }
    else {
        return $self->{coins_created} // 0;
    }
}

sub create_outputs {
    my ($outputs, $hash) = @_;
    my @txo;
    foreach my $out (@$outputs) {
        my $txo = QBitcoin::TXO->new_txo({
            value      => $out->{value},
            scripthash => $out->{scripthash},
        });
        push @txo, $txo;
    }
    QBitcoin::TXO->save_all($hash, \@txo);
    return \@txo;
}

sub load_inputs {
    my $class = shift;
    my ($inputs, $hash, $protocol) = @_;

    my @loaded_inputs;
    my @need_load_txo;
    foreach my $in (@$inputs) {
        if (my $txo = QBitcoin::TXO->get($in)) {
            $txo->redeem_script = $in->{redeem_script};
            push @loaded_inputs, {
                txo     => $txo,
                siglist => $in->{siglist},
            };
        }
        else {
            push @need_load_txo, $in;
        }
    }

    my %unknown_inputs;
    if (@need_load_txo) {
        # var @txo here needed to prevent free txo objects as unused just after load
        my @txo = QBitcoin::TXO->load(@need_load_txo);
        foreach my $in (@need_load_txo) {
            if (my $txo = QBitcoin::TXO->get($in)) {
                $txo->redeem_script = $in->{redeem_script};
                push @loaded_inputs, {
                    txo     => $txo,
                    siglist => $in->{siglist},
                };
            }
            else {
                if ($class->check_by_hash($in->{tx_out})) {
                    Warningf("Transaction %s has no output %u for tx %s input",
                        $class->hash_str($in->{tx_out}), $in->{num}, $class->hash_str($hash));
                    return undef;
                }
                else {
                    Infof("input %s:%u not found in transaction %s",
                        $class->hash_str($in->{tx_out}), $in->{num}, $class->hash_str($hash));
                    if (!$unknown_inputs{$in->{tx_out}} && !$PENDING_TX_INPUT{$in->{tx_out}}) {
                        $protocol->request_tx($in->{tx_out}) if $protocol;
                    }
                    $unknown_inputs{$in->{tx_out}} = 1;
                }
            }
        }
    }
    return(\@loaded_inputs, [ keys %unknown_inputs ]);
}

sub _cmp_inputs {
    my ($in1, $in2) = @_;
    return $in1->{txo}->tx_in cmp $in2->{txo}->tx_in || $in1->{txo}->num <=> $in2->{txo}->num;
}

sub tx_data_hash {
    my ($tx_raw_data) = @_;
    return hash256($tx_raw_data);
}

sub calculate_hash {
    my $self = shift;
    my $tx_raw_data = $self->serialize;
    $self->size = length($tx_raw_data);
    $self->hash = tx_data_hash($tx_raw_data);
}

sub validate_coinbase {
    my $self = shift;
    if (@{$self->out} != 1) {
        Warningf("Incorrect coinbase transaction %s: %u outputs, must be 1", $self->hash_str, scalar @{$self->out});
        return -1;
    }
    # Each upgrade should correspond fixed and deterministic tx hash for qbitcoin
    if (!$self->up) {
        # We should add some code here for validate coinbase in case of not UPGRADE_POW (premined or centrilized emission)
        Warningf("Incorrect transaction %s, no coinbase information nor inputs", $self->hash_str);
        return -1;
    }
    $self->up->validate() == 0
        or return -1;
    # TODO: uncomment when $transaction->data will be implemented
    # if ($self->data ne '') {
    #     Warningf("Incorrect transaction %s, coinbase can't contain data", $self->hash_str);
    #     return -1;
    # }
    if ($self->up->scripthash ne $self->out->[0]->scripthash) {
        Warningf("Mismatch scripthash for coinbase transaction %s", $self->hash_str);
        return -1 unless $config->{fake_coinbase};
        $self->up->scripthash = $self->out->[0]->scripthash;
    }
    if ($self->out->[0]->value != coinbase_value($self->up->value)) {
        Warningf("Mismatch value for coinbase transaction %s", $self->hash_str);
        return -1;
    }
    return 0;
}

sub validate {
    my $self = shift;
    if (UPGRADE_POW) {
        if (!@{$self->in}) {
            return $self->validate_coinbase;
        }
        if ($self->coins_created) {
            Warningf("Mixed input and coinbase in the transaction %s", $self->hash_str);
            return -1;
        }
    }
    # Transaction must contains at least one output (can't spend all inputs as fee)
    if (!@{$self->out}) {
        Warningf("No outputs in transaction %s", $self->hash_str);
        return -1;
    }
    foreach my $out (@{$self->out}) {
        if ($out->value < 0 || $out->value > MAX_VALUE) {
            Warningf("Incorrect output value in transaction %s", $self->hash_str);
            return -1;
        }
    }
    my $class = ref $self;
    my @stored_in;
    my $input_value = 0;
    my %inputs;
    foreach my $in (map { $_->{txo} } @{$self->in}) {
        if ($inputs{$in->key}++) {
            Warningf("Input %s:%u included in transaction %s twice",
                $in->tx_in_str, $in->num, $self->hash_str);
            return -1;
        }
        $input_value += $in->value;
    }
    if ($input_value + $self->coins_created <= 0) {
        Warningf("Zero input in transaction %s", $self->hash_str);
        return -1;
    }
    if ($self->fee >= 0) {
        # Signcheck for stake transaction depends on block it relates to,
        # so skip this check while block_sign_data is not known, check from valid_for_block()
        $self->check_input_script == 0
            or return -1;
    }
    return 0;
}

sub valid_for_block {
    my $self = shift;
    my ($block) = @_;
    ($self->min_tx_time // return -1) <= time_by_height($block->height)
        or return -1;
    if ($self->fee < 0) {
        $self->block_sign_data = $block->sign_data;
        $self->check_input_script == 0
            or return -1;
    }
    return 0;
}

sub check_input_script {
    my $self = shift;
    foreach my $num (0 .. $#{$self->in}) {
        my $in = $self->in->[$num];
        if ($in->{txo}->check_script($in->{siglist}, $self, $num) != 0) {
            Warningf("Unmatched check script for input %s:%u in transaction %s",
                $in->{txo}->tx_in_str, $in->{txo}->num, $self->hash_str);
            return -1;
        }
    }
    return 0;
}

sub announce {
    my $self = shift;
    my ($received_from) = @_;
    foreach my $connection (QBitcoin::ConnectionList->connected(PROTOCOL_QBITCOIN)) {
        next if $received_from && $connection->peer->id eq $received_from->peer->id;
        next unless $connection->protocol->can("announce_tx");
        $connection->protocol->announce_tx($self);
    }
}

sub pre_load {
    my $class = shift;
    my ($attr) = @_;
    if (!$TRANSACTION{$attr->{hash}}) {
        # Load TXO for inputs and outputs
        my @outputs = QBitcoin::TXO->load_stored_outputs($attr->{id}, $attr->{hash});
        my @inputs;
        foreach my $txo (QBitcoin::TXO->load_stored_inputs($attr->{id}, $attr->{hash})) {
            push @inputs, {
                txo     => $txo,
                siglist => $txo->siglist,
            };
        }
        my $upgrade = QBitcoin::Coinbase->load_stored_coinbase($attr->{id}, $attr->{hash});
        $attr->{in}  = \@inputs;
        $attr->{out} = \@outputs;
        $attr->{up}  = $upgrade if $upgrade;
        $attr->{received_time} = time_by_height($attr->{block_height}); # for possible unconfirm the transaction
    }
    return $attr;
}

sub new {
    my $class = shift;
    my $attr = @_ == 1 ? $_[0] : { @_ };
    # tx inputs are not sorted in the database, so sort them here for get deterministic transaction hash
    $attr->{in} = [ sort { _cmp_inputs($a, $b) } @{$attr->{in}} ];
    my $self = bless $attr, $class;
    return $self;
}

sub on_load {
    my $self = shift;

    my $hash = $self->hash;
    if ($TRANSACTION{$hash}) {
        $self = $TRANSACTION{$hash};
    }
    else {
        if (!UPGRADE_POW && !@{$self->in}) {
            $self->{coins_created} = sum0(map { $_->value } @{$self->out}) - $self->fee;
        }
        $self->calculate_hash;
        if ($self->hash ne $hash) {
            die "Incorrect hash for loaded transaction " . $self->hash_str . " != " . $self->hash_str($hash) . "\n";
        }
        $TRANSACTION{$hash} = $self;

        foreach my $in (@{$self->in}) {
            $in->{txo}->spent_add($self);
        }
    }

    return $self;
}

sub unconfirm {
    my $self = shift;
    Debugf("unconfirm transaction %s (confirmed in block height %u)", $self->hash_str, $self->block_height);
    $self->is_cached or die "unconfirm not cached transaction " . $self->hash_str;
    $self->block_height = undef;
    foreach my $in (@{$self->in}) {
        my $txo = $in->{txo};
        $txo->tx_out = undef;
        $txo->siglist = undef;
        # Return to list of my utxo inputs from stake transaction, but do not use returned to mempool
        $txo->add_my_utxo() if $self->fee < 0 && $txo->is_my && !$txo->spent_list;
    }
    foreach my $txo (@{$self->out}) {
        $txo->del_my_utxo() if $txo->is_my;
    }
    if ($self->id) {
        # Transaction will be deleted by "foreign key (block_height) references block (height) on delete cascade" on replace block
        # $self->delete;
        $self->id = undef;
    }
}

sub is_cached {
    my $self = shift;

    return $TRANSACTION{$self->hash} && refaddr($TRANSACTION{$self->hash}) == refaddr($self);
}

sub stake_weight {
    my $self = shift;
    my ($block_height) = @_;
    my $weight = 0;
    if ($self->fee < 0) {
        my $class = ref $self;
        foreach my $in (map { $_->{txo} } @{$self->in}) {
            if (my $in_block_height = $class->check_by_hash($in->tx_in)) {
                if ($in_block_height < 0) {
                    Warningf("Can't get stake_weight for %s with unconfirmed input %s:%u",
                        $self->hash_str, $in->tx_in_str, $in->num);
                    return undef;
                }
                $weight += $in->value * ($block_height - $in_block_height);
            }
            else {
                # tx generated this txo should be loaded during tx validation
                Warningf("No input transaction %s for txo", $in->tx_in_str);
                return undef;
            }
        }
    }
    return int($weight / 0x1000); # prevent int64 overflow for total blockchain weight
}

sub coinbase_weight {
    my $self = shift;
    my ($block_height) = @_;
    my $weight = 0;
    if (my $coinbase = $self->up) {
        # Early confirmation should have more weight than later
        my $base_height = height_by_time($coinbase->btc_confirm_time);
        my $virtual_height = height_by_time($coinbase->btc_confirm_time - COINBASE_WEIGHT_TIME); # MB negative, it's ok
        $weight = $coinbase->value * ($base_height - $virtual_height);
        $weight *= ($base_height - $virtual_height) / ($block_height - $virtual_height);
    }
    return int($weight / 0x1000); # prevent int64 overflow for total blockchain weight
}

sub coinbase_value {
    my ($value) = @_;
    return int($value); # TODO: minus upgrade fee
}

# Create a transaction with already exising coinbase output
sub new_coinbase {
    my $class = shift;
    my ($coinbase) = @_;

    my $txo = QBitcoin::TXO->new_txo({
        value      => coinbase_value($coinbase->value),
        scripthash => $coinbase->scripthash,
    });
    my $self = $class->new(
        in            => [],
        out           => [ $txo ],
        up            => $coinbase,
        fee           => $coinbase->value - $txo->value,
        received_time => time(),
    );
    $self->calculate_hash;
    if (my $cached = $class->get($self->hash)) {
        Debugf("Coinbase transaction %s for btc %s:%u already in mempool",
            $self->hash_str, $class->hash_str($coinbase->btc_tx_hash), $coinbase->btc_out_num);
        $self = $cached;
    }
    else {
        QBitcoin::TXO->save_all($self->hash, $self->out);
        $self->receive(); # Add coinbase tx to mempool
        $coinbase->tx_hash = $self->hash;
        Infof("Generated new coinbase transaction %s for btc output %s:%u",
            $self->hash_str, $class->hash_str($coinbase->btc_tx_hash), $coinbase->btc_out_num);
    }
    return $self;
}

sub min_tx_time {
    my $self = shift;

    return $self->up ? $self->up->min_tx_time : 0;
}

1;
