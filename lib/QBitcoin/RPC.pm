package QBitcoin::RPC;
use warnings;
use strict;

use JSON::XS;
use Time::HiRes;
use Scalar::Util qw(weaken);
use HTTP::Request;
use HTTP::Response;
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::Block;

use Role::Tiny::With;
with 'QBitcoin::RPC::Validate';
with 'QBitcoin::RPC::Commands';

use constant ATTR => qw(
    ip
    host
    port
    addr
    command
    state
    update_time
    connection
    id
);

mk_accessors(ATTR);
mk_accessors(qw( cmd args ));

my $JSON = JSON::XS->new;

sub direction() { DIR_IN }
sub type_id()   { PROTOCOL_RPC }
sub startup()   {}
sub type        { PROTOCOL2NAME->{shift->type_id} }

sub new {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    weaken($args->{connection}) if $args->{connection};
    $args->{update_time} //= time();
    $args->{id} = $args->{connection}->addr . pack("v", $args->{connection}->port);
    return bless $args, $class;
}

sub timeout {
    my $self = shift;
    my $timeout = RPC_TIMEOUT + $self->update_time - time();
    if ($timeout < 0) {
        Infof("RPC client timeout");
        $self->connection->disconnect;
        $timeout = 0;
    }
    return $timeout;
}

sub receive {
    my $self = shift;
    $self->update_time = time();
    $self->connection->recvbuf =~ /\n\r?\n/s
        or return 0;
    my $http_request = HTTP::Request->parse($self->connection->recvbuf);
    my $length = $http_request->headers->content_length;
    return 0 if defined($length) && length($http_request->content) < $length;
    $self->connection->recvbuf = "";
    my $res = eval { $self->process_rpc($http_request) };
    if ($@) {
        Errf("process_rpc exception: %s", "$@");
        $self->response_error("Internal error", ERR_INTERNAL_ERROR);
        return -1;
    }
    return $res;
}

sub send {
    my $self = shift;
    my ($data) = @_;

    $data =~ s/\n/\r\n/gs; # Warning: this includes http body and affects content-length, it does not matter for single-line json
    if ($self->connection->sendbuf eq '' && $self->connection->socket) {
        my $n = syswrite($self->connection->socket, $data);
        if (!defined($n)) {
            Errf("Error write to socket: %s", $!);
            return -1;
        }
        elsif ($n > 0) {
            if ($n < length($data)) {
                substr($data, 0, $n, "");
            }
            else {
                $self->connection->disconnect();
                return 0;
            }
        }
        $self->connection->sendbuf = $data;
    }
    else {
        $self->connection->sendbuf .= $data;
    }
    return 0;
}

sub response_error {
    my $self = shift;
    my ($message, $code, $result) = @_;
    my $http_code = $code == ERR_INTERNAL_ERROR ? 500 : ERR_UNKNOWN_METHOD ? 404 : 400;
    return $self->http_response($http_code, $message, { error => { code => $code, message => $message }, result => $result });
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
        #Connection     => 'close',
    );
    my $response = HTTP::Response->new($code, $message, $headers, $body);
    $response->protocol("HTTP/1.1");
    return $self->send($response->as_string);
}

sub process_rpc {
    my $self = shift;
    my ($http_request) = @_;
    if ($http_request->headers->content_type && lc($http_request->headers->content_type) ne "application/json") {
        Warningf("Incorrect content-type: [%s]", $http_request->headers->content_type // "");
        return $self->response_error("Incorrect content-type", ERR_INVALID_REQUEST);
    }
    my $body = eval { $JSON->decode($http_request->decoded_content) };
    if (!$body) {
        Warningf("Can't decode json request: [%s]", $http_request->decoded_content // "");
        return $self->response_error("Incorrect request body", ERR_INVALID_REQUEST);
    }
    # {"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}';
    if (ref($body) eq "ARRAY") {
        $body = $body->[0]; # Some explorers send such requests
    }
    if (ref($body) ne "HASH") {
        Warningf("Incorrect json request, not hashref: [%s]", $http_request->decoded_content);
        return $self->response_error("Incorrect request body", ERR_INVALID_REQUEST);
    }
    if (!$body->{method} || !$body->{params} ||
        ref($body->{method}) || ref($body->{params}) ne 'ARRAY') {
        Warningf("Incorrect rpc request: [%s]", $http_request->decoded_content);
        return $self->response_error("Incorrect request", ERR_INVALID_REQUEST);
    }
    my $func = "cmd_" . $body->{method};
    if (!$self->can($func)) {
        Warningf("Incorrect rpc method [%s]", $body->{method});
        return $self->response_error("Unknown method", ERR_UNKNOWN_METHOD);
    }
    Debugf("RPC request %s from %s:%u", $body->{method}, $self->connection->ip, $self->connection->port);
    $self->args = $body->{params};
    $self->cmd  = $body->{method};
    $self->validate_args == 0
        or return -1;
    return $self->$func(@{$self->{params}});
}

sub validate_args {
    my $self = shift;
    if (defined(my $spec = $self->params($self->cmd))) {
        if ($self->validate($spec) != 0) {
            return -1;
        }
    }
    else {
        Warningf("No params specification for RPC command [%s]", $self->cmd);
    }
    return 0;
}

# Called from $tx->process_pending() for transactions received by "sendrawtransaction"
sub process_tx {
    my $self = shift;
    my ($tx) = @_;

    $tx->receive() == 0
        or return -1;
    if (defined(my $height = QBitcoin::Block->recv_pending_tx($tx))) {
        return -1 if $height == -1;
        # $self->request_new_block($height+1);
    }
    if ($tx->fee >= 0) {
        # announce to other peers
        $tx->announce();
    }
    elsif (!$tx->in_blocks && !$tx->block_height) {
        Debugf("Ignore stake transactions %s not related to any known block", $tx->hash_str);
        $tx->drop();
    }
    return 0;
}

sub get_block_by_hash {
    my $self = shift;
    my ($hash) = @_;

    my $block = QBitcoin::Block->find(hash => $hash);
    if (!$block) {
        my $best_height = QBitcoin::Block->blockchain_height;
        for (my $height = QBitcoin::Block->min_incore_height; $height <= $best_height; $height++) {
            last if $block = QBitcoin::Block->block_pool($height, $hash);
        }
    }
    return $block;
}

1;
