package QBitcoin::Crypto;
use warnings;
use strict;

use Exporter qw(import);

our @EXPORT_OK = qw(
    check_sig
    hash160
    hash256
    ripemd160
    sha256
    sha1
    checksum32
    pubkey_by_privkey
    signature
    pk_serialize
    pk_import
);

use Digest::SHA qw(sha1 sha256);
use Crypt::Digest::RIPEMD160 qw(ripemd160);
use Crypt::PK::ECC;

use constant CURVE => 'secp256k1';

sub check_sig {
    my ($data, $signature, $pubkey) = @_;
    my $pub = Crypt::PK::ECC->new;
    $pub->import_key_raw($pubkey, CURVE);
    return $pub->verify_hash($signature, hash256($data));
}

sub hash160 {
    my ($pubkey) = @_;
    return ripemd160(sha256($pubkey));
}

sub hash256 {
    my ($data) = @_;
    return sha256(sha256($data));
}

sub checksum32 {
    my ($str) = @_;
    return substr(hash256($str), 0, 4);
}

sub pk_serialize {
    my ($pk) = @_;
    return $pk->export_key_raw('private');
}

sub pk_import {
    my ($private_key) = @_;
    my $pk = Crypt::PK::ECC->new;
    $pk->import_key_raw($private_key, CURVE);
    return $pk;
}

sub pubkey_by_privkey {
    my ($pk) = @_;
    return $pk->export_key_raw('public_compressed');
}

sub signature {
    my ($data, $pk) = @_;
    return $pk->sign_hash(hash256($data));
}

1;
