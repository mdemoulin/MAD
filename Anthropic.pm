# MAD::Anthropic
# Client for the Anthropic Messages API: one request, structured output,
# prompt caching, refusal handling and server-side model fallback.
#
# Raw HTTP over HTTP::Tiny, because Perl has no official Anthropic SDK.
# Spend accounting is MAD::Anthropic::Ledger's job; this class returns the
# usage and the model that actually answered, and the caller records them.

use v5.40;
use utf8;

use Object::Pad 0.825;
package MAD::Anthropic v0.1.0;
class MAD::Anthropic
        :strict(params);

use Carp;
use Const::Fast;
use English;
use HTTP::Tiny;
use JSON::PP;
use true;

const   our $API_URL                    => 'https://api.anthropic.com/v1/messages';
const   our $API_VERSION                => '2023-06-01';
const   our $DEFAULT_MODEL              => 'claude-opus-5-5';
const   our $DEFAULT_MAX_TOKENS         => 16_000;
const   our $DEFAULT_TIMEOUT            => 180;

# fallbacks => 'default' routes a refusal by its category, so there is no
# model list to keep current; an arrayref of model ids is the older form, and
# each form has its own beta header.
const   our $FALLBACK_DEFAULT           => 'default';
const   our $FALLBACK_BETA_DEFAULT      => 'server-side-fallback-2026-07-01';
const   our $FALLBACK_BETA_LIST         => 'server-side-fallback-2026-06-01';

# ->canonical is not cosmetic: Perl randomises hash order per process, and
# prompt caching is a prefix BYTE match, so without it every run ships a
# differently-ordered system block, writes a new cache entry and never reads
# one.
const   my  $JSON_OUT                   => JSON::PP->new->utf8->canonical;
const   my  $JSON_IN                    => JSON::PP->new->utf8->core_bools;

# ---------------------------------------------------------------
# class framework
field $api_key
        :param                          = undef;
field $conf_file
        :reader(get_conf_file)
        :param                          = undef;
field $model
        :reader(get_model)
        :param                          = $DEFAULT_MODEL;
field $fallbacks
        :reader(get_fallbacks)
        :param                          = undef;
field $effort
        :reader(get_effort)
        :param                          = undef;
field $max_tokens
        :reader(get_max_tokens)
        :param                          = $DEFAULT_MAX_TOKENS;
field $timeout
        :reader(get_timeout)
        :param                          = $DEFAULT_TIMEOUT;
field $api_url
        :reader(get_api_url)
        :param                          = $API_URL;
field $ua
        :param                          = undef;

ADJUST {
    $ua                               //= HTTP::Tiny->new (timeout => $timeout);

    croak "fallbacks must be '$FALLBACK_DEFAULT' or an arrayref of model ids"
            if defined $fallbacks
            && ref $fallbacks ne 'ARRAY'
            && $fallbacks ne $FALLBACK_DEFAULT;
    }

# ---------------------------------------------------------------
# structured - send a system prompt and one user message, get back the
#   model's answer decoded from JSON against $schema (an output_config
#   format: { type => 'json_schema', schema => {...} }).
#   Returns (data, response); the response carries usage and the model that
#   answered, which differs from ours when a fallback took the request.
method structured (%arg) {
    croak 'structured needs system, user and schema'
            if grep { !defined $arg{$_} } qw{system user schema};

    my  $system                         = { type => 'text', text => $arg{system} };
    $system->{cache_control}            = { type => 'ephemeral' }
            if $arg{cache_system};

    my  $answer                         = $self->request ({
                                            system          => [ $system ],
                                            output_config   => { format => $arg{schema} },
                                            messages        => [ { role => 'user', content => $arg{user} } ],
                                            });

    my  $text                           = $self->text_of ($answer);
    my  $data                           = eval { JSON::PP->new->utf8 (0)->core_bools->decode ($text) }
            or croak "could not parse the model's JSON: $EVAL_ERROR";

    return ($data, $answer);
    }

# request - POST one Messages API body; model, max_tokens, fallbacks and
#   effort are filled in from the object unless the body sets them.
#   Returns the decoded response, or dies with one line saying what went
#   wrong. A refusal dies too: it arrives as a 200 with no usable content.
method request ($body) {
    my  %body                           = $body->%*;
    $body{model}                      //= $model;
    $body{max_tokens}                 //= $max_tokens;
    $body{fallbacks}                  //= $fallbacks if defined $fallbacks;
    if (defined $effort) {
        $body{output_config}            = { ($body{output_config} // {})->%* };
        $body{output_config}{effort}  //= $effort;
        }

    my  %header                         = ( 'content-type'      => 'application/json',
                                            'x-api-key'         => $self->_api_key (),
                                            'anthropic-version' => $API_VERSION,
                                            );
    $header{'anthropic-beta'}           = ref $body{fallbacks} ? $FALLBACK_BETA_LIST
                                                               : $FALLBACK_BETA_DEFAULT
            if defined $body{fallbacks};

    my  $res                            = $ua->post ($api_url, {
                                            headers => \%header,
                                            content => $JSON_OUT->encode (\%body),
                                            });
    die api_error ($res) if !$res->{success};

    my  $answer                         = $JSON_IN->decode ($res->{content});

    die "the model declined this request: "
                . ($answer->{stop_details}{explanation} // 'no explanation given') . "\n"
            if ($answer->{stop_reason} // q{}) eq 'refusal';

    carp "output hit max_tokens ($body{max_tokens}) and may be truncated"
            if ($answer->{stop_reason} // q{}) eq 'max_tokens';

    return $answer;
    }

# text_of - the text of a response's first text block. Thinking blocks come
#   back too (empty by default on current models) and are skipped.
method text_of ($answer) {
    my  ($block)                        = grep { $_->{type} eq 'text' } ($answer->{content} // [])->@*;
    croak 'no text block in the response' if !$block;
    return $block->{text};
    }

# _api_key - the key: the constructor's, the environment's, or the
#   'api_key = ...' line of conf_file, in that order
method _api_key () {
    return $api_key if $api_key;
    return $api_key = $ENV{ANTHROPIC_API_KEY} if $ENV{ANTHROPIC_API_KEY};

    croak 'no API key: pass api_key, set ANTHROPIC_API_KEY, or pass conf_file'
            if !$conf_file;
    open my $fh, '<', $conf_file
            or croak "set ANTHROPIC_API_KEY or put 'api_key = ...' in $conf_file";
    while (my $line = <$fh>) {
        next if $line =~ m{\A \s* (?: [#] | \z )}xms;
        my  ($k, $v)                    = split m{\s*=\s*}xms, $line, 2;
        next if !defined $v;
        chomp $v;
        $api_key                        = $v if $k eq 'api_key';
        }
    close $fh;

    croak "$conf_file has no 'api_key' line" if !$api_key;
    return $api_key;
    }

# ---------------------------------------------------------------
# api_error - one line saying what went wrong, from whatever the API gave us.
#   HTTP::Tiny reports its own failures (timeout, DNS, TLS) as status 599.
sub api_error ($res) {
    my  $status                         = $res->{status};
    my  $detail                         = eval {
                                            $JSON_IN->decode ($res->{content})->{error}{message};
                                            } // $res->{content} // q{};
    $detail                             =~ s{\s+}{ }gxms;
    $detail                             = substr $detail, 0, 300;

    return "network error talking to the API: $detail\n"           if $status == 599;
    return "the API rejected the key (401): $detail\n"             if $status == 401;
    return "rate limited (429); retry after "
            . ($res->{headers}{'retry-after'} // '?')
            . "s: $detail\n"                                       if $status == 429;
    return "the API rejected the request (400): $detail\n"         if $status == 400;
    return "the API is having trouble ($status): $detail\n"        if $status >= 500;
    return "API request failed ($status): $detail\n";
    }

__END__

=encoding utf8

=head1 NAME

MAD::Anthropic - a small client for the Anthropic Messages API

=head1 SYNOPSIS

    use Const::Fast;
    use MAD::Anthropic;

    const my $MODEL     => 'claude-opus-5-5';
    const my $CONF_FILE => "$ENV{HOME}/.config/shiftreport.conf";

    my $ai = MAD::Anthropic->new (
            model     => $MODEL,
            fallbacks => $MAD::Anthropic::FALLBACK_DEFAULT,
            conf_file => $CONF_FILE,
            );

    my ($data, $answer) = $ai->structured (
            system       => $prompt,
            cache_system => true,
            user         => $text,
            schema       => { type => 'json_schema', schema => \%schema },
            );

=head1 DESCRIPTION

One non-streaming request per call. No tool use, no streaming: add them
when something needs them.

Errors die with a single line ending in a newline, suitable for showing a
user as is. A refusal is an error. Hitting max_tokens is a warning.

=cut
