package QBitcoin::RPC;
use warnings;
use strict;

use JSON::XS;
use Time::HiRes;
use HTTP::Request;
use HTTP::Response;
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::Peers;

use Role::Tiny::With;
with 'QBitcoin::RPC::Commands';

# Error codes: https://github.com/bitcoin/bitcoin/blob/v0.21.1/src/rpc/protocol.h#L23-L87
use constant {
    ERR_INVALID_REQUEST => -32600,
    ERR_UNKNOWN_METHOD  => -32601,
    ERR_INVALID_PARAMS  => -32602,
    ERR_INTERNAL_ERROR  => -32603,
    ERR_PARSE_ERROR     => -32700,

    ERR_MISC            => -1,
};

use constant ATTR => qw(
    ip
    host
    port
    addr
    recvbuf
    sendbuf
    socket
    socket_fileno
    command
    state
    update_time
);

mk_accessors(ATTR);

my $JSON = JSON::XS->new;

sub direction() { DIR_IN }
sub type()      { "RPC"  }
sub startup()   {}

sub new {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    my $self = bless $args, $class;
    $self->sendbuf = "";
    $self->recvbuf = "";
    $self->socket_fileno = fileno($self->socket) if $self->socket;
    $self->update_time = time();
    return $self;
}

sub disconnect {
    my $self = shift;
    if ($self->socket) {
        shutdown($self->socket, 2);
        close($self->socket);
        $self->socket = undef;
        $self->socket_fileno = undef;
    }
    Debugf("Disconnected RPC API client %s", $self->ip);
    QBitcoin::Peers->del_peer($self);
    return 0;
}

sub timeout {
    my $self = shift;
    my $timeout = RPC_TIMEOUT + $self->update_time - time();
    if ($timeout < 0) {
        $self->disconnect;
        $timeout = 0;
    }
    return $timeout;
}

sub receive {
    my $self = shift;
    $self->update_time = time();
    $self->recvbuf =~ /\n\r?\n/s
        or return 0;
    my $http_request = HTTP::Request->parse($self->recvbuf);
    my $length = $http_request->headers->content_length;
    return 0 if defined($length) && length($http_request->content) < $length;
    $self->process_rpc($http_request);
}

sub send {
    my $self = shift;
    my ($data) = @_;

    if ($self->sendbuf eq '' && $self->socket) {
        my $n = syswrite($self->socket, $data);
        if (!defined($n)) {
            Errf("Error write to socket: %s", $!);
            return -1;
        }
        elsif ($n > 0) {
            if ($n < length($data)) {
                substr($data, 0, $n, "");
            }
            else {
                $self->disconnect();
                return 0;
            }
        }
        $self->sendbuf = $data;
    }
    else {
        $self->sendbuf .= $data;
    }
    return 0;
}

sub return_error {
    my $self = shift;
    my ($message, $code) = @_;
    my $http_code = $code == ERR_INTERNAL_ERROR ? 500 : ERR_UNKNOWN_METHOD ? 404 : 400;
    return $self->http_response($http_code, $message, { error => { code => $code, message => $message }, result => undef });
}

sub response_ok {
    my $self = shift;
    my ($result) = @_; # optional, undef by default
    return $self->http_response(200, "OK", { result => $result, error => undef });
}

sub http_response {
    my $self = shift;
    my ($code, $message, $content) = @_;
    my $body = $JSON->encode($content);
    my $headers = HTTP::Headers->new(
        Content_Type   => 'application/json',
        Content_Length => length($body),
        Connection     => 'close',
    );
    my $response = HTTP::Response->new($code, $message, $headers, $body);
    $response->protocol("HTTP/1.1");
    $self->send($response->as_string);
}

sub process_rpc {
    my $self = shift;
    my ($http_request) = @_;
    if (lc($http_request->headers->content_type) ne "application/json") {
        Warningf("Incorrect content-type: [%s]", $http_request->headers->content_type // "");
        return $self->return_error("Incorrect content-type", ERR_INVALID_REQUEST);
    }
    my $body = eval { $JSON->decode($http_request->decoded_content) };
    if (!$body) {
        Warningf("Can't decode json request: [%s]", $http_request->decoded_content // "");
        return $self->return_error("Incorrect request body", ERR_INVALID_REQUEST);
    }
    # {"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}';
    if (!$body->{jsonrpc} || !$body->{method} || !$body->{params} ||
        ref($body->{method}) || ref($body->{params}) ne 'ARRAY') {
        Warningf("Incorrect rpc request: [%s]", $http_request->decoded_content);
        return $self->return_error("Incorrect request", ERR_INVALID_REQUEST);
    }
    my $func = "cmd_" . $body->{method};
    if (!$self->can($func)) {
        Warningf("Incorrect rpc method [%s]", $body->{method});
        return $self->return_error("Unknown method", ERR_UNKNOWN_METHOD);
    }
    Debugf("RPC request %s from %s", $body->{method}, $self->ip);
    return $self->$func(@{$self->{params}});
}

1;
