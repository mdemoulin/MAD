# MAD::Anthropic::Ledger
# What Anthropic API calls cost: price one response's usage, append it to a
# TSV ledger, and total or summarise the ledger.
#
# The ledger is append-only TSV: two runs at once cannot corrupt it the way
# a read-modify-write of a JSON total could, and awk can total it.
#   stamp  tag  model  input  cache_write  cache_read  output  dollars

use v5.40;
use utf8;

use Object::Pad 0.825;
package MAD::Anthropic::Ledger v0.1.0;
class MAD::Anthropic::Ledger
        :strict(params);

use Carp;
use Const::Fast;
use English;
use File::Basename;
use File::Path;
use POSIX qw{strftime};
use true;

# Dollars per million tokens, from the pricing page, checked 2026-10-12.
# Cache reads are priced per model, not as a fixed fraction of input: they
# are 0.1x on most models but 0.05x on Opus 5.5 and 0.025x on Fable 5.1.
# A model not in here still runs; its tokens are recorded and its cost is
# left blank rather than guessed.
const   our %PRICE                      => (
        'claude-fable-5-1'              => { in => 10.00, out => 50.00, cache_read => 0.25 },
        'claude-fable-5'                => { in => 10.00, out => 50.00, cache_read => 1.00 },
        'claude-opus-5-5'               => { in =>  4.00, out => 20.00, cache_read => 0.20 },
        'claude-opus-5'                 => { in =>  5.00, out => 25.00, cache_read => 0.50 },
        'claude-opus-4-8'               => { in =>  5.00, out => 25.00, cache_read => 0.50 },
        'claude-sonnet-5-5'             => { in =>  2.00, out => 10.00, cache_read => 0.20 },
        'claude-sonnet-5'               => { in =>  2.00, out => 10.00, cache_read => 0.20 },
        'claude-haiku-4-5'              => { in =>  1.00, out =>  5.00, cache_read => 0.10 },
        );

# Cache writes bill above the input rate: 1.25x for the five-minute TTL,
# 2x for the one-hour TTL.
const   our $CACHE_WRITE_5M_RATE        => 1.25;
const   our $CACHE_WRITE_1H_RATE        => 2.00;

const   my  $FIELDS                     => 8;

# ---------------------------------------------------------------
# class framework
field $path
        :reader(get_path)
        :param;
field $prices
        :param                          = \%PRICE;

# ---------------------------------------------------------------
# cost - dollars for one response's usage, or undef for a model we have no
#   price for. Cache writes and reads cannot just be added to input_tokens.
method cost ($usage, $for_model) {
    return undef if !exists $prices->{$for_model};                              ## no critic (ProhibitExplicitReturnUndef)
    my  $price                          = $prices->{$for_model};
    my  ($in, $write, $read, $out)      = token_counts ($usage);

    # usage.cache_creation splits the writes by TTL when the API sends it;
    # without it, every write is taken to be a five-minute one
    # (exists, not //, so a read-only usage hash does not die on a missing key)
    my  $split                          = exists $usage->{cache_creation} ? $usage->{cache_creation} : {};
    my  $write_1h                       = (exists $split->{ephemeral_1h_input_tokens}
                                            ? $split->{ephemeral_1h_input_tokens} : 0) // 0;
    my  $write_5m                       = $write - $write_1h;

    return (
            $in       * $price->{in}
            + $write_5m * $price->{in} * $CACHE_WRITE_5M_RATE
            + $write_1h * $price->{in} * $CACHE_WRITE_1H_RATE
            + $read     * $price->{cache_read}
            + $out      * $price->{out}
            ) / 1_000_000;
    }

# record - append one response to the ledger; returns the line to show the
#   user: what this run cost, and the running total.
#   $tag is whatever identifies the run to the caller (shiftreport.pl uses
#   the entry's date).
method record ($usage, $for_model, $tag = q{}) {
    my  ($in, $write, $read, $out)      = token_counts ($usage);
    my  $cost                           = $self->cost ($usage, $for_model);

    my  $dir                            = dirname ($path);
    File::Path::make_path ($dir) if !-d $dir;

    # A ledger we cannot write is worth a warning, not a lost answer.
    if (open my $fh, '>>:encoding(UTF-8)', $path) {
        say {$fh} join "\t", strftime ('%Y-%m-%dT%H:%M:%S', localtime), $tag, $for_model,
                              $in, $write, $read, $out,
                              defined $cost ? sprintf '%.6f', $cost : q{};
        close $fh;
        }
    else {
        carp "cannot write $path: $OS_ERROR";
        }

    my  $line                           = sprintf 'this run: %s (%s in, %s out',
                                            defined $cost ? sprintf ('$%.4f', $cost)
                                                          : 'cost unknown for ' . $for_model,
                                            commify ($in + $write + $read), commify ($out);
    $line                              .= sprintf ', %s cached', commify ($read) if $read;
    $line                              .= ')';

    my  ($total, $runs)                 = $self->total ();
    $line .= sprintf "\n%s %s to date: \$%.2f\n",
                commify ($runs), ($runs == 1 ? 'run' : 'runs'), $total
        if $runs;
    return "$line\n";
    }

# total - (dollars, runs) over the whole ledger
method total () {
    my  ($total, $runs)                 = (0, 0);
    for my $row ($self->_rows ()) {
        $runs++;
        $total                         += $row->[7] if length $row->[7];
        }
    return ($total, $runs);
    }

# report - the total, the date range, and a line per model
method report () {
    my  @rows                           = $self->_rows ();
    return "nothing spent yet\n" if !@rows;

    my  (%by_model, $total);
    for my $row (@rows) {
        my  $cost                       = length $row->[7] ? $row->[7] : 0;
        $total                         += $cost;
        $by_model{$row->[2]}{runs}++;
        $by_model{$row->[2]}{cost}     += $cost;
        }

    my  $runs                           = @rows;
    my  $out                            = sprintf "%s %s, \$%.2f total\n",
                                            commify ($runs),
                                            ($runs == 1 ? 'run' : 'runs'),
                                            $total;
    $out                               .= "  $rows[0][0] .. $rows[-1][0]\n\n";
    for my $m (sort keys %by_model) {
        $out                           .= sprintf "  %-22s %6s %-4s \$%8.4f\n",
                                            $m,
                                            commify ($by_model{$m}{runs}),
                                            ($by_model{$m}{runs} == 1 ? 'run' : 'runs'),
                                            $by_model{$m}{cost};
        }
    $out                               .= sprintf "\n  average per run: \$%.4f\n", $total / $runs;
    return $out;
    }

# _rows - the ledger's well-formed lines, split into fields; none if there
#   is no ledger yet
method _rows () {
    open my $fh, '<:encoding(UTF-8)', $path or return;
    my  @rows;
    while (my $line = <$fh>) {
        chomp $line;
        my  @field                      = split m{\t}xms, $line, -1;
        push @rows, \@field if @field >= $FIELDS;
        }
    close $fh;
    return @rows;
    }

# ---------------------------------------------------------------
# token_counts - (input, cache write, cache read, output) from a usage block
sub token_counts ($usage) {
    return map { (exists $usage->{$_} ? $usage->{$_} : 0) // 0 }
            qw{input_tokens cache_creation_input_tokens cache_read_input_tokens output_tokens};
    }

# commify - 1234567 -> 1,234,567
sub commify ($n) {
    my  $s                              = reverse "$n";
    $s                                  =~ s{(\d{3}) (?=\d)}{$1,}gxms;
    return scalar reverse $s;
    }

__END__

=encoding utf8

=head1 NAME

MAD::Anthropic::Ledger - price Anthropic API usage and keep a spend ledger

=head1 SYNOPSIS

    use Const::Fast;
    use MAD::Anthropic::Ledger;

    const my $LEDGER => "$ENV{HOME}/.local/state/shiftreport-spend.tsv";

    my $ledger = MAD::Anthropic::Ledger->new (path => $LEDGER);
    print $ledger->record ($answer->{usage}, $answer->{model}, $date);
    print $ledger->report ();

=cut
