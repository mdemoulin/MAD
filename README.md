# MAD

My own Perl modules, under the `MAD::` namespace.  So far, a small client for
the [Anthropic Messages API](https://docs.anthropic.com/) and a ledger for
what calling it costs.  Perl has no official Anthropic SDK, so these speak
the API directly over `HTTP::Tiny`.

| Module | What it does |
|---|---|
| `MAD::Anthropic` | One request per call: a system prompt (optionally cached) and a user message in, an answer decoded from JSON against your schema out.  Handles server-side model fallback, refusals (an error) and `max_tokens` (a warning), and turns HTTP failures into one readable line. |
| `MAD::Anthropic::Ledger` | Prices a response's token usage per model, including cache writes and reads, which bill at their own rates.  Appends each call to a tab-separated ledger, and totals or summarises it. |

They were split out of `shiftreport.pl`, a tool that turns a day's entry in a
work wiki into a shift report, so that the next tool to call the API does
not start from scratch.

## Using them

    use Const::Fast;
    use MAD::Anthropic;
    use MAD::Anthropic::Ledger;

    const my $CONF_FILE => "$ENV{HOME}/.config/myapp.conf";   # api_key = ...
    const my $LEDGER    => "$ENV{HOME}/.local/state/myapp-spend.tsv";

    my $ai = MAD::Anthropic->new (
            model     => 'claude-opus-5-5',
            fallbacks => $MAD::Anthropic::FALLBACK_DEFAULT,
            conf_file => $CONF_FILE,
            );

    my ($data, $answer) = $ai->structured (
            system       => $prompt,
            cache_system => true,
            user         => $text,
            schema       => { type => 'json_schema', schema => \%schema },
            );

    my $ledger = MAD::Anthropic::Ledger->new (path => $LEDGER);
    print $ledger->record ($answer->{usage}, $answer->{model}, 'a tag for this call');
    print $ledger->report ();

The API key comes from the constructor's `api_key`, then `ANTHROPIC_API_KEY`,
then an `api_key = ...` line in `conf_file`.

The ledger is append-only TSV, one line per call:

    stamp  tag  model  input  cache_write  cache_read  output  dollars

Prices are hard-coded per model and dated in `Ledger.pm`; a model with no
price is still recorded, with its cost left blank rather than guessed.

## Requirements

Perl 5.40 or later, and from CPAN: `Object::Pad` 0.825 or later,
`Const::Fast` and `true`.  `HTTP::Tiny` and `JSON::PP` are core.

## Installing and testing

The modules sit at the top of the repository (`Anthropic.pm`,
`Anthropic/Ledger.pm`), so the checkout itself is the `MAD/` directory.
Copy or link it onto `@INC` as `MAD`.  To run the tests from inside it:

    prove -I.. t/

The tests use a stand-in for `HTTP::Tiny` and never call the API.

## License

GPL version 3 or later; see [COPYING](COPYING).
