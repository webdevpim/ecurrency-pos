package Bitcoin::Protocol;
use warnings;
use strict;
use feature 'state';

use parent 'QBitcoin::Protocol::Common';
use QBitcoin::Const qw(GENESIS_TIME);
use QBitcoin::Log;
use Bitcoin::Block;

use constant TESTNET => 1;

use constant {
    PROTOCOL_VERSION  => 70011,
    #PROTOCOL_FEATURES => 0x409,
    PROTOCOL_FEATURES => 0x1,
    PORT_P2P          => TESTNET ? 18333 : 8333,
    # https://en.bitcoin.it/wiki/Protocol_documentation#Message_structure
    MAGIC             => pack("V", TESTNET ? 0x0709110B : 0xD9B4BEF9),
#    BTC_GENESIS       => scalar reverse pack("H*",
#        TESTNET ?
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

my $HAVE_BLOCK0;

sub varint {
    my ($num) = @_;
    return $num < 0xFD ? pack("C", $num) :
        $num < 0xFFFF ? pack("Cv", 0xFD, $num) :
        $num < 0xFFFFFFFF ? pack("CV", 0xFE, $num) :
        pack("CQ<", 0xFF, $num);
}

# modify param, remove length from data
sub get_varint {
    my $first = unpack("C", substr($_[0], 0, 1, ""));
    my ($data) = @_;
    # We do not check if $data has enough data, but if not we will fail on next step, get items
    return $first < 0xFD ? $first :
        $first == 0xFD ? unpack("v", substr($_[0], 0, 2, "")) :
        $first == 0xFE ? unpack("V", substr($_[0], 0, 4, "")) :
        unpack("Q<", substr($_[0], 0, 8, ""));
}

sub varstr {
    my ($str) = @_;
    return varint(length($str)) . $str;
}

sub startup {
    my $self = shift;
    my $nonce = pack("vvvv", int(rand(0x10000)), int(rand(0x10000)), int(rand(0x10000)), int(rand(0x10000)));
    my ($last_block) = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 1);
    my $height = $last_block ? $last_block->height : -1;
    $HAVE_BLOCK0 = 1 if $last_block;
    my $version = pack("VQ<Q<a26a26a8Cl<C", PROTOCOL_VERSION, PROTOCOL_FEATURES, time(),
        $self->pack_my_address, $self->pack_address, $nonce, 0, $height, 0);
    $self->send_message("version", $version);
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

sub request_blocks {
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
    $self->request_blocks();
    return 0;
}

sub cmd_verack {
    my $self = shift;
    return 0;
}

sub cmd_inv {
    my $self = shift;
    my ($data) = @_;
    if (length($data) == 0) {
        Errf("Incorrect params from peer %s cmd %s data length %u", $self->ip, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my $num = get_varint($data);
    if (length($data) != 36*$num) {
        Errf("Incorrect params from peer %s cmd %s data length %u, expected %u", $self->ip, $self->command, length($data), 36*$num);
        $self->abort("incorrect_params");
        return -1;
    }
    for (my $i = 0; $i < $num; $i++) {
        my $inv = substr($data, $i*36, 36);
        my ($type, $hash) = unpack("Va32", $inv);
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
    my ($data) = @_;
    if (length($data) == 0) {
        Errf("Incorrect params from peer %s cmd %s data length %u", $self->ip, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my $num = get_varint($data);
    if (length($data) != $num*81) {
        Errf("Incorrect params from peer %s cmd %s data length %u expected %u", $self->ip, $self->command, length($data), $num*81);
        $self->abort("incorrect_params");
        return -1;
    }
    my $known_block;
    my $new_block;
    my $orphan_block;
    for (my $i = 0; $i < $num; $i++) {
        my $header = substr($data, $i*81, 81);
        my $block = Bitcoin::Block->deserialize($header);
        Debugf("Received block header: %s, prev_hash %s",
            unpack("H*", scalar reverse $block->hash), unpack("H*", scalar reverse $block->prev_hash));
        my $exising = Bitcoin::Block->find(hash => $block->hash);
        if ($exising) {
            $known_block = $exising;
        }
        else {
            if ($self->process_block($block)) {
                $new_block = $block;
                $block->scanned = $block->time >= GENESIS_TIME ? 0 : 1;
                $block->create();
                $HAVE_BLOCK0 = 1;
            }
            else {
                $orphan_block //= $block;
            }
        }
    }
    if ($known_block) {
        # All received block are known for us. Was it deep rollback?
        my $start_height = $known_block->height;
        my @blocks = Bitcoin::Block->find(height => [ map { $start_height + $_*1900 } 1 .. 250 ], -sortby => "height DESC");
        $self->send_message("getheaders",
            varint(scalar(@blocks + 1)) . join("", map { $_->hash } @blocks) . $known_block->hash . "\x00" x 32);
    }
    elsif ($new_block) {
        $self->request_blocks();
    }
    elsif ($orphan_block) {
        if ($HAVE_BLOCK0) {
            $self->request_blocks();
        }
        else {
            # Is it genesis block? Request it
            Debugf("Request genesis block %s", unpack("H*", scalar reverse $orphan_block->prev_hash));
            $self->send_message("getdata",
                pack("CVa32", 1, MSG_BLOCK, $self->can('BTC_GENESIS') ? $self->BTC_GENESIS : $orphan_block->prev_hash));
        }
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
        Debugf("Request block data: %s", unpack("H*", scalar reverse $block->hash));
        $self->send_message("getdata", pack("CVa32", 1, MSG_BLOCK, $block->hash));
        return 1;
    }
    else {
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

sub process_block {
    my $self = shift;
    my ($block) = @_;

    state $LAST_BLOCK;
    if ($block->prev_hash eq "\x00" x 32) {
        $block->height = 0;
    }
    else {
        my $existing;
        $existing = $LAST_BLOCK if $LAST_BLOCK && $LAST_BLOCK->hash eq $block->prev_hash;
        $existing //= Bitcoin::Block->find(hash => $block->prev_hash);
        if ($existing) {
            $block->height = $existing->height+1;
            my $revert_height;
            foreach my $revert_block (Bitcoin::Block->find(height => { '>=' => $block->height }, -sortby => 'height DESC')) {
                if (!$revert_height) {
                    $revert_height = $revert_block->height;
                    Noticef("Revert blockchain height %u-%u", $block->height, $revert_height);
                }
                $revert_block->delete();
            }
        }
        else {
            Warningf("Received orphan block %s, prev hash %s", $block->hash_str, unpack("H*", scalar reverse $block->prev_hash));
            if ($HAVE_BLOCK0) {
                # TODO: do not request block if syncing()
                $self->request_blocks();
            }
            return undef;
        }
    }
    $LAST_BLOCK = $block;
    return $block;
}

sub cmd_block {
    my $self = shift;
    my ($block_data) = @_;
    my $block = Bitcoin::Block->deserialize($block_data);
    if (!$block) {
        $self->abort("bad_block_data");
        return -1;
    }

    Debugf("Received block: %s, prev_hash %s",
        unpack("H*", scalar reverse $block->hash), unpack("H*", scalar reverse $block->prev_hash));

    if (my $existing = Bitcoin::Block->find(hash => $block->hash)) {
        if ($existing->scanned) {
            Debugf("Received already scanned block %s, ignored", $block->hash_str);
            return 0;
        }
        $block->height = $existing->height;
    }
    else {
        $self->process_block($block)
            or return 0;
        $block->scanned = $block->time >= GENESIS_TIME ? 0 : 1;
        $block->create();
        $HAVE_BLOCK0 = 1;
    }

    if (!$block->scanned) {
        $self->process_transactions($block, substr($block_data, 80));
    }

    if ($block->height) {
        $self->request_transactions();
    }
    else {
        $self->request_blocks();
    }

    return 0;
}

sub process_transactions {
    my $self = shift;
    my ($block, $tx_data) = @_;

    my $tx_num = get_varint($tx_data);
    for (my $i = 0; $i < $tx_num; $i++) {
        # TODO
        #$block->process_serialized_tx($tx_data);
    }
    $block->update(scanned => 1);
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
