package MT::Plugin::OMV::YahooSearchStringUnits;
########################################################################
#   YahooSearchStringUnits - Suggestion with Yahoo!'s related searching word web service
#   @see http://developer.yahoo.co.jp/search/webunit/V1/webunitSearch.html
#           Copyright (c) 2008 Piroli YUKARINOMIYA (MagicVox)
#           @see http://www.magicvox.net/archive/2008/04141429/

use strict;
use MT;
use MT::Util qw( encode_url );
use LWP::UserAgent;
use Cache::File;
use XML::Simple;
#use Data::Dumper;#DEBUG

### End point of Yahoo! web service
use constant YAHOO_API_ENDPOINT =>      'http://api.search.yahoo.co.jp/AssistSearchService/V1/webunitSearch';

### default expire time of cached content
use constant DEFAULT_EXPIRE =>          '2 weeks';



### Register as a plugin
use vars qw( $MYNAME $VERSION );
$MYNAME = 'YahooSearchStringUnits';
$VERSION = '0.10';

use base qw( MT::Plugin );
my $plugin = __PACKAGE__->new({
    name => $MYNAME,
    version => $VERSION,
    id => $MYNAME,
    key => $MYNAME,
    description => <<PERLHEREDOC,
Suggestion with Yahoo!&apos;s related searching word web service
PERLHEREDOC
    doc_link => 'http://www.magicvox.net/archive/2008/04141429/',
    author_name => 'Piroli YUKARINOMIYA',
    author_link => 'http://www.magicvox.net/',
    # Configurations
    system_config_template => \&_tmpl_system_config,
    settings => new MT::PluginSettings([
        ['yahoo_appid', { Default => undef, Scope => 'system' }],
    ]),
});
MT->add_plugin( $plugin );

sub instance { $plugin }

### Regist handlers
sub init_registry {
    my( $plugin ) = @_;
    $plugin->registry({
        tags => {
            block => {
                'YahooSearchStringUnits' => \&_hdlr_yahoo_search_string_units,
                'YahooSuggestedSearchStringsHeader?' => \&_hdlr_yahoo_suggested_search_strings_header,
                'YahooSuggestedSearchStringsFooter?' => \&_hdlr_yahoo_suggested_search_strings_footer,
            },
            function => {
                'YahooSuggestedSearchStrings' => \&_hdlr_yahoo_suggested_search_strings
            },
        },
    });
}



### Plugin configurations
sub _tmpl_system_config {
    return <<PERLHEREDOC;
<mtapp:setting id="yahoo_appid" label="Yahoo! Application ID">
  <input type="text" size="20" name="yahoo_appid" id="yahoo_appid" value="<TMPL_VAR NAME=YAHOO_APPID ESCAPE=HTML>" />
</mtapp:setting>
PERLHEREDOC
}



### <YahooSearchStringUnits> container tag
sub _hdlr_yahoo_search_string_units {
    my( $ctx, $args, $cond ) = @_;

    ### Search query strings
    my( $hdlr ) = $ctx->handler_for( 'SearchString' )
        or return $ctx->error( "Can't use in except search result template" );
    my $search_string = $hdlr->( @_ )
        or return '';
    length $search_string
        or return '';
#return $search_string;#DEBUG

    ### Yahoo! application ID
    my $yahoo_appid = &instance->get_config_value( 'yahoo_appid' )
        or return $ctx->error( "You need to get and configure your Yahoo! application ID for $MYNAME" );
#return $yahoo_appid;#DEBUG

    my $yahoo_result;
    my $cache = &get_cache_instance
        or return $ctx->error( 'Failed to initialize a component - Cache::File' );
    unless( defined( $yahoo_result = $cache->get( $search_string ))) {
        ### Retrieve with Yahoo!'s web service
        my $ua = new LWP::UserAgent
            or return $ctx->error( 'Failed to initialize a component - LWP::UserAgent' );
        $ua->agent( __PACKAGE__. '/'. $VERSION );
        my %params = (
            appid => $yahoo_appid,
            query => encode_url( $search_string ),
            results => int $args->{lastn} || 1,
        );
        my $url = YAHOO_API_ENDPOINT. '?'. join '&', map { $_. '='. $params{$_} } keys %params;
        my $res = $ua->get( $url )
            or return '';
        $res->is_success
            or return '';   # but HTTP errors
        $yahoo_result = $res->content
            or return '';   # empty content

        ### Store the retrieved contents from Yahoo! into cache
        $cache->set( $search_string, $yahoo_result, DEFAULT_EXPIRE );
    }
#return '<pre>'. $yahoo_result. '</pre>';#DEBUG

    ### Parse the results
    my $xs = new XML::Simple
        or return $ctx->error( 'Failed to initialize a component - XML::Simple' );
    my $ref = $xs->XMLin( $yahoo_result )
        or return '';
#return '<pre>'. Dumper( $ref ). '</pre>';#DEBUG
    $ref->{totalResultsReturned}
        or return '';
    my @results = ref $ref->{Result} ? @{$ref->{Result}} : ( $ref->{Result} );

    ### Build the tokens
    my $builder = $ctx->stash( 'builder' );
    my $tokens = $ctx->stash( 'tokens' );
    my @out = ();
    foreach my $cnt (0..$#results) {
        local $ctx->{__stash}{__PACKAGE__. '::Result'} = $results[$cnt];
        local $ctx->{__stash}{__PACKAGE__. '::Header'} = $cnt == 0;
        local $ctx->{__stash}{__PACKAGE__. '::Footer'} = $cnt == $#results;
        defined( my $out = $builder->build( $ctx, $tokens, $cond ))
            or return $ctx->error( $builder->errstr );
        push @out, $out;
    }
    return join $args->{glue} || '', @out;
}

### <$MTYahooSuggestedSearchStrings$> tag
sub _hdlr_yahoo_suggested_search_strings {
    $_[0]->{__stash}{__PACKAGE__. '::Result'} || '';
}

### <MTYahooSuggestedSearchStringsHeader/Footer> conditional tag
sub _hdlr_yahoo_suggested_search_strings_header {
    $_[0]->{__stash}{__PACKAGE__. '::Header'} || 0;
}

sub _hdlr_yahoo_suggested_search_strings_footer {
    $_[0]->{__stash}{__PACKAGE__. '::Footer'} || 0;
}



### Handling <Cache::File> as singleton
use MT::Request;
sub get_cache_instance {
    my $r = MT::Request->instance;
    my $cache = $r->cache( __PACKAGE__. '::cache' );
    unless( defined $cache ) {
        $cache = Cache::File->new(
                cache_root => &get_cache_dir,
                lock_level => Cache::File::LOCK_LOCAL(),
                cache_depth => 2,
                );
        $r->cache( __PACKAGE__. '::cache', $cache );
    }
    $cache;
}

sub get_cache_dir {
    my $path = &instance->{full_path};
    -d $path
        ? "${path}/$MYNAME"
        : "${path}.cache";
}

1;