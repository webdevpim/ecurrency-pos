package QBitcoin::Config;
use warnings;
use strict;

use Hash::MultiValue;
use QBitcoin::Const;

use Exporter qw(import);

our @EXPORT = qw($config);
our @EXPORT_OK = qw(read_config);

our $config = Hash::MultiValue->new();

# Simple "key = value" lines
# No includes, no variable substitutions, no multiline values, even no \" escaping
# Support multivalue
sub read_config {
    my ($conffile) = @_;

    if (!defined $conffile) {
        $conffile = CONFIG_DIR . "/" . CONFIG_NAME;
        -f $conffile or return; # No config file is OK if it's not explicitly specified in options
    }
    else {
        $conffile = CONFIG_DIR . "/$conffile" if ref($conffile) eq "" && index($conffile, '/') == -1;
    }

    open(my $conf_fh, '<', $conffile)
        or die "Can't open config file $conffile: $!\n";
    my $linenum = 0;
    while (my $line = <$conf_fh>) {
        $linenum++;
        chomp($line);
        my $orig_line = $line;
        # Do we need to process quotes here? There are no comments in line 'key = "part1 # part2"'
        # If implement, take care about greedy matching: 'key = value # comment # also comment'
        $line =~ s/(?:^|\s+)#.*//; # remove comments, "# blah-blah" after space or from line begin
        next if $line =~ /^\s*$/;  # skip empty lines
        my ($key, $value) = $line =~ /^([a-z][-_0-9a-z.:]*)\s*=\s*(.*\S)\s*$/i
            or die "Incorrect config line $linenum:\n$orig_line\n";
        $value = $1 if $value =~ /^"(.*)"$/ || $value =~ /^'(.*)'$/;
        $config->add($key => $value);
    }
    close($conf_fh);
}

1;
