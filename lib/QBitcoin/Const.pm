package QBitcoin::Const;
use warnings;
use strict;

use QBitcoin::Script::OpCodes qw(OP_RETURN);

use constant GENESIS_BLOCK_HASH => "1234";
use constant QBT_SCRIPT_START   => OP_RETURN . "QBTC";

use constant QBITCOIN_CONST => {
    VERSION                 => "0.1",
    BLOCK_INTERVAL          => 10, # sec
    GENESIS_TIME            => 1630659500,
    INCORE_LEVELS           => 6,
    MIN_FEE                 => 0.00000001, # 1 satoshi
    MAX_VALUE               => 21000000 * 100000000, # 21M
    DENOMINATOR             => 100000000,
    COMPACT_MEMORY          => 1,
    MAX_COMMAND_LENGTH      => 256,
    READ_BUFFER_SIZE        => 16*1024*1024, # Must be more than MAX_BLOCK_SIZE
    WRITE_BUFFER_SIZE       => 16*1024*1024, # Must be more than MAX_BLOCK_SIZE
    SERVICE_NAME            => "qbitcoin",
    SELECT_TIMEOUT          => 10, # sec
    RPC_TIMEOUT             => 4,  # sec
    PEER_RECV_TIMEOUT       => 60, # sec, ping period and timeout for waiting for pong
    PORT                    => 9555,
    BIND_ADDR               => '*',
    RPC_PORT                => 9556, # JSON RPC API
    RPC_ADDR                => '127.0.0.1',
    LISTEN_QUEUE            => 5,
    PEER_RECONNECT_TIME     => 10,
    GENESIS_HASH            => pack('H*', GENESIS_BLOCK_HASH),
    GENESIS_HASH_HEX        => GENESIS_BLOCK_HASH,
    MAX_BLOCK_SIZE          => 8*1024*1024,
    MAX_TX_IN_BLOCK         => 65535,
    BLOCK_HEADER_SIZE       => 200, # TODO: calculate precise value
    MAX_TX_SIZE             => 2*1024*1024,
    MAX_PENDING_BLOCKS      => 128,
    MAX_PENDING_TX          => 128,
    MAX_EMPTY_TX_IN_BLOCK   => 1,
    UPGRADE_POW             => 1,
    COINBASE_CONFIRM_TIME   => 2*3600, # 2 hours
    COINBASE_CONFIRM_BLOCKS => 6,
    COINBASE_WEIGHT_TIME    => 365*24*3600, # 1 year
    BTC_TESTNET             => 1,
    QBT_SCRIPT_START        => QBT_SCRIPT_START,
    QBT_SCRIPT_START_LEN    => length(QBT_SCRIPT_START),
    CONFIG_DIR              => "/etc",
    CONFIG_NAME             => "qbitcoin.conf",
};

use constant STATE_CONST => {
    STATE_CONNECTED    => 'connected',
    STATE_CONNECTING   => 'connecting',
    STATE_DISCONNECTED => 'disconnected',
};

use constant DIR_CONST => {
    DIR_IN  => 'in',
    DIR_OUT => 'out',
};

use constant QBITCOIN_CONST;
use constant STATE_CONST;
use constant DIR_CONST;

sub time_by_height {
    my ($height) = @_;

    return GENESIS_TIME + $height * BLOCK_INTERVAL;
}

sub height_by_time {
    my ($time) = @_;

    return int(($time - GENESIS_TIME) / BLOCK_INTERVAL);
}

use Exporter qw(import);
our @EXPORT = ( keys %{&QBITCOIN_CONST}, keys %{&STATE_CONST}, keys %{&DIR_CONST} );
push @EXPORT, qw(time_by_height height_by_time);

1;
