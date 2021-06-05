package QBitcoin::Crypto;
use warnings;
use strict;

use Exporter qw(import);

our @EXPORT_OK = qw(check_sig hash160 checksum32 pubkey_by_privkey signature pk_serialize pk_import signature);

use Digest::SHA qw(sha256);
use Crypt::Digest::RIPEMD160 qw(ripemd160);
use Crypt::PK::ECC;

use constant CURVE => 'secp256k1';

sub check_sig {
    my ($data, $signature, $pubkey) = @_;
    my $pub = Crypt::PK::ECC->import_key_raw($pubkey, CURVE);
    return $pub->verify_message($signature, $data);
}

sub hash160 {
    my ($pubkey) = @_;
    return ripemd160(sha256($pubkey));
}

sub checksum32 {
    my ($str) = @_;
    return substr(sha256(sha256($str)), 0, 4);
}

sub pk_serialize {
    my ($pk) = @_;
    return $pk->export_key_raw('private');
}

sub pk_import {
    my ($pk) = @_;
    return Crypt::PK::ECC->import_key_raw($pk, CURVE);
}

sub pubkey_by_privkey {
    my ($pk) = @_;
    return $pk->export_key_raw('public_compressed');
}

sub signature {
    my ($data, $pk) = @_;
    return $pk->sign_message($data);
}

1;
