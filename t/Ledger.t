#!/opt/perl/bin/perl
# t/Ledger.t

use v5.40;
use utf8;

use Test::More;

use Const::Fast;
use File::Temp qw{tempdir};

use MAD::Anthropic::Ledger;

const   my  $DIR                        => tempdir (CLEANUP => 1);
const   my  $USAGE                      => { input_tokens                => 2_000,
                                             cache_creation_input_tokens => 1_000,
                                             cache_read_input_tokens     => 10_000,
                                             output_tokens               => 500 };

sub near ($got, $want, $name) {
    ok (defined $got && abs ($got - $want) < 1e-9, $name) or diag ('got ' . ($got // 'undef') . ", want $want");
    }

my  $ledger                             = MAD::Anthropic::Ledger->new (path => "$DIR/sub/spend.tsv");

# Opus 5.5: $4 in, $20 out, $0.20 cache read; five-minute writes at 1.25x
near ($ledger->cost ($USAGE, 'claude-opus-5-5'),
      (2_000 * 4 + 1_000 * 4 * 1.25 + 10_000 * 0.20 + 500 * 20) / 1e6,
      'opus 5.5 cost, cache read at its own price');

# Opus 5 reads at 0.1x of $5
near ($ledger->cost ($USAGE, 'claude-opus-5'),
      (2_000 * 5 + 1_000 * 5 * 1.25 + 10_000 * 0.50 + 500 * 25) / 1e6,
      'opus 5 cost');

# one-hour writes bill at 2x
near ($ledger->cost ({ %$USAGE, cache_creation => { ephemeral_1h_input_tokens => 400 } }, 'claude-opus-5-5'),
      (2_000 * 4 + 600 * 4 * 1.25 + 400 * 4 * 2 + 10_000 * 0.20 + 500 * 20) / 1e6,
      'one-hour cache writes at 2x');

is ($ledger->cost ($USAGE, 'claude-imaginary-9'), undef, 'unknown model: cost undef, not guessed');

is ($ledger->report (), "nothing spent yet\n", 'report with no ledger');
is_deeply ([ $ledger->total () ], [ 0, 0 ], 'total with no ledger');

my  $line                               = $ledger->record ($USAGE, 'claude-opus-5-5', '20261012');
ok (-f "$DIR/sub/spend.tsv", 'record makes the directory and the ledger');
like ($line, qr{\Athis run: \$0\.0250 \(13,000 in, 500 out, 10,000 cached\)}, 'record line');
like ($line, qr{1 run to date: \$0\.03}, 'running total');

$ledger->record ({ input_tokens => 1, output_tokens => 1 }, 'claude-imaginary-9', 'x');
my  ($total, $runs)                     = $ledger->total ();
is ($runs, 2, 'two runs');
near ($total, 0.025, 'blank cost counts as nothing');

like ($ledger->report (), qr{\A2 runs, \$0\.03 total\n.*claude-imaginary-9 .*claude-opus-5-5 }s, 'report by model');

is (MAD::Anthropic::Ledger::commify (1234567), '1,234,567', 'commify');

done_testing ();
