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

# Sonnet 5.5 reads at 0.05x of $2
near ($ledger->cost ($USAGE, 'claude-sonnet-5-5'),
      (2_000 * 2 + 1_000 * 2 * 1.25 + 10_000 * 0.10 + 500 * 10) / 1e6,
      'sonnet 5.5 cost, cache read at 0.05x');

# Haiku 5.5: $0.10 in, $0.50 out, $0.01 cache read, for a prompt up to 100,000 tokens
near ($ledger->cost ($USAGE, 'claude-haiku-5-5'),
      (2_000 * 0.10 + 1_000 * 0.10 * 1.25 + 10_000 * 0.01 + 500 * 0.50) / 1e6,
      'haiku 5.5 cost');

# over 100,000 tokens of prompt -- cache reads counted -- every token at the higher prices
near ($ledger->cost ({ %$USAGE, cache_read_input_tokens => 97_001 }, 'claude-haiku-5-5'),
      (2_000 * 0.50 + 1_000 * 0.50 * 1.25 + 97_001 * 0.05 + 500 * 2.50) / 1e6,
      'haiku 5.5 over 100,000 tokens of prompt, cache reads included');
near ($ledger->cost ({ %$USAGE, cache_read_input_tokens => 97_000 }, 'claude-haiku-5-5'),
      (2_000 * 0.10 + 1_000 * 0.10 * 1.25 + 97_000 * 0.01 + 500 * 0.50) / 1e6,
      'haiku 5.5 at exactly 100,000 tokens of prompt: the lower prices');

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
