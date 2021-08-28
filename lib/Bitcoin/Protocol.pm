package Bitcoin::Protocol;
use warnings;
use strict;
use feature 'state';

use parent 'QBitcoin::Protocol::Common';
use QBitcoin::Const qw(GENESIS_TIME BTC_TESTNET QBT_SCRIPT_START QBT_SCRIPT_START_LEN);
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Produce;
use QBitcoin::Coinbase;
use QBitcoin::ORM::Transaction;
use QBitcoin::ProtocolState qw(btc_synced);
use Bitcoin::Serialized;
use Bitcoin::Block;
use Bitcoin::Transaction;

use Role::Tiny::With;
with 'Bitcoin::Protocol::ProcessBlock';

use constant {
    PROTOCOL_VERSION  => 70011,
    #PROTOCOL_FEATURES => 0x409,
    PROTOCOL_FEATURES => 0x1,
    PORT_P2P          => BTC_TESTNET ? 18333 : 8333,
    # https://en.bitcoin.it/wiki/Protocol_documentation#Message_structure
    MAGIC             => pack("V", BTC_TESTNET ? 0x0709110B : 0xD9B4BEF9),
#    BTC_GENESIS       => scalar reverse pack("H*",
#        BTC_TESTNET ?
#            "000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943" :
#            "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"),
};

use constant {
    MSG_TX    => 1,
    MSG_BLOCK => 2,
};

use constant {
    REJECT_INVALID => 1,
};

sub startup {
    my $self = shift;
    my $nonce = pack("vvvv", int(rand(0x10000)), int(rand(0x10000)), int(rand(0x10000)), int(rand(0x10000)));
    my ($last_block) = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 1);
    my $height = $last_block ? $last_block->height : -1;
    $self->have_block0(1) if $last_block;
    my $version = pack("VQ<Q<a26a26a8Cl<C", PROTOCOL_VERSION, PROTOCOL_FEATURES, time(),
        $self->pack_my_address, $self->pack_address, $nonce, 0, $height, 0);
    $self->send_message("version", $version);
    $self->syncing(1);
    return 0;
}

sub pack_my_address {
    my $self = shift;
    return pack("Q<a16n", PROTOCOL_FEATURES, $self->my_addr, $self->my_port);
}

sub pack_address {
    my $self = shift;
    return pack("Q<a16n", PROTOCOL_FEATURES, "\x00"x10 . "\xff\xff" . $self->addr, $self->port);
}

sub abort {
    my $self = shift;
    my ($reason) = @_;
    $self->send_message("reject", varstr($self->command) . pack("C", REJECT_INVALID) . varstr($reason // "general_error"));
}

sub request_btc_blocks {
    my $self = shift;
    my @blocks = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 10);
    my @locators = map { $_->hash } @blocks;
    if (@locators == 0) {
        if ($self->can('BTC_GENESIS')) {
            Debugf("Request genesis block");
            $self->send_message("getdata", pack("CVa32", 1, MSG_BLOCK, $self->BTC_GENESIS));
            return;
        }
        @locators = "\x00" x 32;
    }
    elsif ($blocks[-1]->height > 0) {
        my $step = 4;
        my $height = $blocks[-1]->height - $step;
        my @height;
        while ($height > 0) {
            push @height, $height;
            $step *= 2;
            $step = 100000 if $step > 100000;
            $height -= $step;
        };
        push @height, 0;
        push @locators, map { $_->hash } Bitcoin::Block->find(-sortby => 'height DESC', height => \@height);
    }
    $self->send_message("getheaders", pack("V", PROTOCOL_VERSION) . varint(scalar(@locators)) . join("", @locators) . "\x00" x 32);
}

sub cmd_version {
    my $self = shift;
    my ($data) = @_;

    my ($version, $features, $time, $pack_address) = unpack("VQ<Q<a26", $data);
    Infof("Remote version %u, features 0x%x", $version, $features);
    $self->send_message("verack", "");
    $self->greeted = 1;
    $self->request_btc_blocks();
    return 0;
}

sub cmd_verack {
    my $self = shift;
    return 0;
}

sub cmd_inv {
    my $self = shift;
    my ($payload) = @_;
    if (length($payload) == 0) {
        Errf("Incorrect params from peer %s cmd %s data length %u", $self->ip, $self->command, length($payload));
        $self->abort("incorrect_params");
        return -1;
    }
    my $data = Bitcoin::Serialized->new($payload);
    my $num = $data->get_varint();
    if ($data->length != 36*$num) {
        Errf("Incorrect params from peer %s cmd %s data length %u, expected %u", $self->ip, $self->command, $data->length, 36*$num);
        $self->abort("incorrect_params");
        return -1;
    }
    for (my $i = 0; $i < $num; $i++) {
        my ($type, $hash) = unpack("Va32", $data->get(36));
        if ($type == MSG_TX) {
            # We do not need mempool transactions
            next;
        }
        if ($type == MSG_BLOCK) {
            if (!Bitcoin::Block->find(hash => $hash)) {
                Debugf("Request block %s", unpack("H*", scalar reverse $hash));
                $self->send_message("getdata", pack("CVa32", 1, MSG_BLOCK, $hash));
            }
        }
        else {
            Debugf("Ignore inv type %u from peer %s", $type, $self->ip);
        }
    }
    return 0;
}

sub cmd_headers {
    my $self = shift;
    my ($payload) = @_;
    if (length($payload) == 0) {
        Errf("Incorrect params from peer %s cmd %s data length %u", $self->ip, $self->command, length($payload));
        $self->abort("incorrect_params");
        return -1;
    }
    my $data = Bitcoin::Serialized->new($payload);
    my $num = $data->get_varint();
    if ($data->length != $num*81) {
        Errf("Incorrect params from peer %s cmd %s data length %u expected %u", $self->ip, $self->command, $data->length, $num*81);
        $self->abort("incorrect_params");
        return -1;
    }
    my $known_block;
    my $new_block;
    my $orphan_block;
    for (my $i = 0; $i < $num; $i++) {
        my $block = Bitcoin::Block->deserialize($data);
        if (!$block || !$block->validate) {
            $self->abort("bad_block_header");
            return -1;
        }
        Debugf("Received btc block header: %s, prev_hash %s", $block->hash_hex, $block->prev_hash_hex);
        my $existing = Bitcoin::Block->find(hash => $block->hash);
        if ($existing) {
            $known_block = $existing;
        }
        else {
            my $db_transaction = QBitcoin::ORM::Transaction->new;
            if ($self->process_btc_block($block)) {
                $new_block = $block;
                $block->scanned = $block->time >= GENESIS_TIME ? 0 : 1;
                $block->create();
                $self->have_block0(1);
                $db_transaction->commit;
            }
            else {
                $orphan_block //= $block;
                $db_transaction->rollback;
            }
        }
        my $tx_num = $data->get_varint(); # always 0
    }
    if ($orphan_block) {
        if ($self->have_block0) {
            $self->request_btc_blocks();
        }
        else {
            # Is it genesis block? Request it
            Debugf("Request genesis block %s", $orphan_block->prev_hash_hex);
            $self->send_message("getdata",
                pack("CVa32", 1, MSG_BLOCK, $self->can('BTC_GENESIS') ? $self->BTC_GENESIS : $orphan_block->prev_hash));
        }
    }
    elsif ($new_block) {
        $self->request_btc_blocks();
    }
    elsif ($known_block && $num == 2000) {
        # All received block are known for us. Was it deep rollback?
        my $start_height = $known_block->height;
        my @blocks = Bitcoin::Block->find(height => [ map { $start_height + $_*1900 } 1 .. 250 ], -sortby => "height DESC");
        $self->send_message("getheaders", pack("V", PROTOCOL_VERSION) .
            varint(scalar(@blocks + 1)) . join("", map { $_->hash } @blocks) . $known_block->hash . "\x00" x 32);
    }
    else {
        $self->request_transactions();
    }
    return 0;
}

sub request_transactions {
    my $self = shift;

    my ($block) = Bitcoin::Block->find(scanned => 0, -sortby => 'height ASC', -limit => 1);
    if ($block) {
        Debugf("Request block data: %s", $block->hash_hex);
        $self->send_message("getdata", pack("CVa32", 1, MSG_BLOCK, $block->hash));
        return 1;
    }
    else {
        if ($self->syncing) {
            Infof("BTC syncing done");
            $self->syncing(0);
            btc_synced(1);
        }
        return 0;
    }
}

sub cmd_getdata {
    my $self = shift;
    # We're slave node, ignore any data requests
    return 0;
}

sub cmd_notfound {
    my $self = shift;
    # do nothing
    return 0;
}

sub cmd_block {
    my $self = shift;
    my ($payload) = @_;

    my $block_data = Bitcoin::Serialized->new($payload);
    my $block = Bitcoin::Block->deserialize($block_data);
    if (!$block || !$block->validate) {
        $self->abort("bad_block_data");
        return -1;
    }

    Debugf("Received block: %s, prev_hash %s", $block->hash_hex, $block->prev_hash_hex);

    if (my $existing = Bitcoin::Block->find(hash => $block->hash)) {
        if ($existing->scanned) {
            Debugf("Received already scanned block %s, ignored", $block->hash_hex);
            return 0;
        }
        $block->height = $existing->height;
    }
    else {
        my $db_transaction = QBitcoin::ORM::Transaction->new;
        if (!$self->process_btc_block($block)) {
            $db_transaction->rollback;
            return 0;
        }
        $block->scanned = $block->time >= GENESIS_TIME ? 0 : 1;
        $block->create();
        $db_transaction->commit;
        $self->have_block0(1);
    }

    if (!$block->scanned) {
        if ($self->process_transactions($block, $block_data)) {
            $self->abort("bad_block_data");
            return -1;
        }
    }

    if ($block->height) {
        $self->request_transactions();
    }
    else {
        $self->request_btc_blocks();
    }

    return 0;
}

sub add_coinbase($$$) {
    my ($block, $tx_num, $out_num) = @_;
    my $tx = $block->transactions->[$tx_num];
    my $out = $tx->out->[$out_num];
    if ($out->{value} == 0) {
        Warningf("Ignore coinbase block %s tx %s with zero amount", $block->hash_hex, $tx->hash_str);
        return;
    }
    Infof("Add coinbase: block %s tx %s value %lu", $block->hash_hex, $tx->hash_str, $out->{value});
    my $coinbase = QBitcoin::Coinbase->new(
        btc_block_height => $block->height,
        btc_block_hash   => $block->hash,
        btc_tx_num       => $tx_num,
        btc_out_num      => $out_num,
        btc_tx_hash      => $tx->hash,
        btc_tx_data      => $tx->data,
        merkle_path      => $block->merkle_path($tx_num),
        value            => $out->{value},
        open_script      => substr($out->{open_script}, QBT_SCRIPT_START_LEN),
    );
    $coinbase->store();
}

sub process_transactions {
    my $self = shift;
    my ($block, $tx_data) = @_;

    my $tx_num = $tx_data->get_varint();
    my @transactions;
    for (my $i = 0; $i < $tx_num; $i++) {
        my $tx = Bitcoin::Transaction->deserialize($tx_data);
        Debugf("process transaction: %s", $tx->hash_hex);
        push @transactions, $tx;
    }
    $block->transactions = \@transactions;
    if ($block->merkle_root ne $block->calculate_merkle_root) {
        Errf("Incorrect merkle root for block %s: %s != %s", $block->hash_hex,
            unpack("H*", $block->merkle_root), unpack("H*", $block->calculate_merkle_root));
        return -1;
    }
    for (my $i = 0; $i < $tx_num; $i++) {
        my $tx = $block->transactions->[$i];
        for (my $num = 0; $num < @{$tx->out}; $num++) {
            if ($config->{produce}) {
                # replace open_script to upgrade
                QBitcoin::Produce->produce_coinbase($tx, $num);
            }
            my $out = $tx->out->[$num];
            if (substr($out->{open_script}, 0, QBT_SCRIPT_START_LEN) eq QBT_SCRIPT_START) {
                add_coinbase($block, $i, $num);
            }
        }
    }
    $block->update(scanned => 1);
    return undef;
}

sub cmd_mempool {
    my $self = shift;
    # Slave node, do not announce anything
    Debugf("Ignore mempool request");
    return 0;
}

sub cmd_tx {
    my $self = shift;
    # We do not need mempool transactions
    Debugf("Ignore received tx");
    return 0;
}

sub cmd_ping {
    my $self = shift;
    my ($data) = @_;
    $self->send_message("pong", $data);
    return 0;
}

sub cmd_pong {
    my $self = shift;
    my ($data) = @_;
    $self->ping_sent = undef;
    return 0;
}

sub cmd_reject {
    my $self = shift;
    Warningf("Peer %s reject our request", $self->ip);
    return 0;
}

sub cmd_alert {
    my $self = shift;
    my ($data) = @_;
    Warningf("Peer %s sends alert: %s", $self->ip, unpack("H*", $data));
    return 0;
}

sub cmd_addr {
    my $self = shift;
    return 0;
}

sub cmd_getheaders {
    my $self = shift;
    return 0;
}

sub cmd_sendheaders {
    my $self = shift;
    return 0;
}

sub cmd_sendcmpct {
    my $self = shift;
    return 0;
}

sub cmd_feefilter {
    my $self = shift;
    return 0;
}

1;
