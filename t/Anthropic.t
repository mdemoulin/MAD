#!/opt/perl/bin/perl
# t/Anthropic.t

use v5.40;
use utf8;

package FakeUA {
    # Stands in for HTTP::Tiny: keeps every request, answers from a queue.
    sub new ($class, @responses) { return bless { sent => [], queue => [@responses] }, $class }
    sub post ($self, $url, $opt) {
        push $self->{sent}->@*, { url => $url, $opt->%* };
        return shift $self->{queue}->@*;
        }
    sub last_body ($self)    { return JSON::PP->new->utf8->core_bools->decode ($self->{sent}[-1]{content}) }
    sub last_headers ($self) { return $self->{sent}[-1]{headers} }
    }

package main;

use Test::More;

use Const::Fast;
use JSON::PP;

use MAD::Anthropic;

const   my  $KEY                        => 'sk-test';
const   my  $SCHEMA                     => { type => 'json_schema',
                                             schema => { type => 'object', additionalProperties => false } };

sub ok_response (%answer) {
    return { success => true, status => 200,
             content => JSON::PP->new->utf8->encode ({
                 model       => 'claude-opus-5-5',
                 stop_reason => 'end_turn',
                 content     => [ { type => 'thinking', thinking => q{} },
                                  { type => 'text', text => '{"summary":"ok"}' } ],
                 usage       => { input_tokens => 10, output_tokens => 5 },
                 %answer,
                 }) };
    }

sub client ($ua, %arg) {
    return MAD::Anthropic->new (api_key => $KEY, ua => $ua, %arg);
    }

# --- structured: request shape and the decoded answer
{
    my  $ua                             = FakeUA->new (ok_response ());
    my  ($data, $answer)                = client ($ua)->structured (
                                            system => 'be brief', cache_system => true,
                                            user => 'hello', schema => $SCHEMA);
    is_deeply ($data, { summary => 'ok' }, 'structured decodes the text block, skipping thinking');
    is ($answer->{model}, 'claude-opus-5-5', 'response comes back for usage and model');

    my  $body                           = $ua->last_body ();
    is ($body->{model}, $MAD::Anthropic::DEFAULT_MODEL, 'default model filled in');
    is ($body->{max_tokens}, $MAD::Anthropic::DEFAULT_MAX_TOKENS, 'default max_tokens filled in');
    is_deeply ($body->{system}[0]{cache_control}, { type => 'ephemeral' }, 'cache_system marks the system block');
    is_deeply ($body->{output_config}{format}, $SCHEMA, 'schema goes in output_config.format');
    ok (!exists $body->{fallbacks}, 'no fallbacks unless asked for');

    my  $h                              = $ua->last_headers ();
    is ($h->{'x-api-key'}, $KEY, 'api key header');
    is ($h->{'anthropic-version'}, $MAD::Anthropic::API_VERSION, 'version header');
    ok (!exists $h->{'anthropic-beta'}, 'no beta header without fallbacks');
}

# --- the encoding is canonical: prompt caching is a byte-prefix match
{
    my  $ua                             = FakeUA->new (ok_response ());
    client ($ua)->request ({ zeta => 1, alpha => 2, messages => [ { role => 'user', content => 'x' } ] });
    my  $sent                           = $ua->{sent}[-1]{content};
    is ($sent, JSON::PP->new->utf8->canonical->encode (JSON::PP->new->utf8->decode ($sent)),
        'request body is canonically encoded');
}

# --- fallbacks pick their beta header; effort merges into output_config
{
    my  $ua                             = FakeUA->new (ok_response (), ok_response ());
    client ($ua, fallbacks => $MAD::Anthropic::FALLBACK_DEFAULT, effort => 'high')
            ->structured (system => 's', user => 'u', schema => $SCHEMA);
    is ($ua->last_body ()->{fallbacks}, 'default', "fallbacks => 'default' sent");
    is ($ua->last_headers ()->{'anthropic-beta'}, $MAD::Anthropic::FALLBACK_BETA_DEFAULT, 'default-form beta header');
    is ($ua->last_body ()->{output_config}{effort}, 'high', 'effort sent');
    is_deeply ($ua->last_body ()->{output_config}{format}, $SCHEMA, 'effort did not clobber the format');

    client ($ua, fallbacks => [ 'claude-opus-5' ])->request ({ messages => [] });
    is ($ua->last_headers ()->{'anthropic-beta'}, $MAD::Anthropic::FALLBACK_BETA_LIST, 'list-form beta header');

    eval { client ($ua, fallbacks => 'sometimes') };
    like ($@, qr{fallbacks must be}, 'a bad fallbacks value is refused at construction');
}

# --- refusal and truncation
{
    my  $ua                             = FakeUA->new (ok_response (
                                            stop_reason  => 'refusal', content => [],
                                            stop_details => { type => 'refusal', explanation => 'nope' }));
    eval { client ($ua)->request ({ messages => [] }) };
    is ($@, "the model declined this request: nope\n", 'refusal dies with the explanation');

    $ua                                 = FakeUA->new (ok_response (stop_reason => 'max_tokens'));
    my  @warned;
    local $SIG{__WARN__}                = sub { push @warned, @_ };
    client ($ua)->request ({ messages => [] });
    like ($warned[0] // q{}, qr{hit max_tokens}, 'max_tokens warns');
}

# --- error mapping
{
    my  %case                           = (
            599 => qr{\Anetwork error},
            401 => qr{\Athe API rejected the key \(401\): bad key},
            429 => qr{\Arate limited \(429\); retry after 7s},
            400 => qr{\Athe API rejected the request \(400\)},
            529 => qr{\Athe API is having trouble \(529\)},
            404 => qr{\AAPI request failed \(404\)},
            );
    for my $status (sort keys %case) {
        my  $ua                         = FakeUA->new ({
                                            success => false, status => $status,
                                            headers => { 'retry-after' => 7 },
                                            content => '{"error":{"message":"bad key"}}' });
        eval { client ($ua)->request ({ messages => [] }) };
        like ($@, $case{$status}, "status $status");
    }
}

# --- the key comes from the environment when not passed
{
    local $ENV{ANTHROPIC_API_KEY}       = 'sk-env';
    my  $ua                             = FakeUA->new (ok_response ());
    MAD::Anthropic->new (ua => $ua)->request ({ messages => [] });
    is ($ua->last_headers ()->{'x-api-key'}, 'sk-env', 'key from ANTHROPIC_API_KEY');
}

done_testing ();
