# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

=pod

---+ package Foswiki::Plugins::PermLinkPlugin

When developing a plugin it is important to remember that

Foswiki is tolerant of plugins that do not compile. In this case,
the failure will be silent but the plugin will not be available.
See %SYSTEMWEB%.InstalledPlugins for error messages.

__NOTE:__ Foswiki:Development.StepByStepRenderingOrder helps you decide which
rendering handler to use. When writing handlers, keep in mind that these may
be invoked

on included topics. For example, if a plugin generates links to the current
topic, these need to be generated before the =afterCommonTagsHandler= is run.
After that point in the rendering loop we have lost the information that
the text had been included from another topic.

=cut


package Foswiki::Plugins::PermLinkPlugin;
use strict;
use warnings;

require Foswiki::Func;       # The plugins API
require Foswiki::Plugins;    # For the API version

our $VERSION = '$Rev: 3193 $';
our $RELEASE = '0.9.0';
our $SHORTDESCRIPTION = 'Manages permanent links to topics.';
our $NO_PREFS_IN_TOPIC = 1;

sub initPlugin {
    # my ($topic, $web) = @_;

    Foswiki::Func::registerTagHandler('PERMLINK', \&handle_PERMLINK);
    Foswiki::Func::registerRESTHandler('view',   \&rest_view);
    Foswiki::Func::registerRESTHandler('deploy', \&rest_deploy);

    return 1;
}

sub get_topic_for_human {
    (my $id) = @_;

    # sanatize $id
    $id =~ s/[^A-Za-z0-9_.]//g;

    return get_topic_for_id( "PERM_ID_HUMAN", $id );
}

sub get_topic_for_md5 {
    (my $id) = @_;

    # sanatize $id
    $id =~ s/[^A-Fa-f0-9]//g;

    return get_topic_for_id( "PERM_ID_MD5", $id );
}

# a noobs implementation
sub get_topic_for_id {
    (my $method, my $id) = @_;


    my $webs = join(q{,}, Foswiki::Func::getListOfWebs());
    my $tml = "%SEARCH{ ";
    $tml   .= "search=\"preferences[name='" . $method . "' AND value='" . $id . "']\" ";
    $tml   .= 'type="query" ';
    $tml   .= 'web="'.$webs.'" ';
    $tml   .= 'format="$web.$topic" ';
    $tml   .= 'seperator="," ';
    $tml   .= 'nonoise="on" ';
    $tml   .= 'limit="1" ';
    $tml   .= "}%";

    my $topic = Foswiki::Func::expandCommonVariables( $tml );

    return $topic if Foswiki::Func::topicExists( q{}, $topic );
    return q{};
}

sub handle_PERMLINK {
    my($session, $params, $topic, $web) = @_;

    my ( $human, $md5 ) = (q{}, q{});
    my ( $meta, $text );

    my ( $theWeb, $theTopic ) = Foswiki::Func::normalizeWebTopicName( $web, $params->{topic} || $topic );
    my $theFormat = $params->{format} || '$url$md5';
    my $theURL    = $Foswiki::cfg{Plugins}{PermLinkPlugin}{shortURL} || "%SCRIPTURL{rest}%/PermLinkPlugin/view/";
    my $theWarn   = $params->{warn}   || '1';
    my $revno;
    if ( $theWarn =~ m/off/ ) { $theWarn = 0; }


    # checking some pre-conditions
    if ( not Foswiki::Func::topicExists( $theWeb, $theTopic ) ) {
        if ($theWarn) { return '%MAKETEXT{"Error: topic does not exist"}%' }
        else { return q{} }
    }
    if ( not Foswiki::Func::checkAccessPermission("VIEW", Foswiki::Func::getCanonicalUserID(), undef, $theTopic, $theWeb ) ) {
        if ($theWarn) { return '%MAKETEXT{"Error: access denied"}%' }
        else { return q{} }
    }

    # getting the IDs
    ( $meta, $text ) = Foswiki::Func::readTopic( $theWeb, $theTopic );
    my @prefs = $meta->find( 'PREFERENCE' );
    foreach my $pref ( @prefs ) {
        if ( $pref->{name} eq 'PERM_ID_HUMAN' ) { $human = $pref->{value}; };
        if ( $pref->{name} eq 'PERM_ID_MD5' )   { $md5   = $pref->{value}; };
    }
    if ( not ($human and $md5) ) {
        if ($theWarn) { return '%MAKETEXT{"Error: no IDs found, please edit/save this topic"}%' }
        else { return q{} }
    }

    if ($Foswiki::Plugins::VERSION < 2.1) {
        $revno = $session->{store}->getRevisionNumber($theWeb, $theTopic);
    } else {
        $revno = $meta->getMaxRevNo();
    }

    # formatting the output
    $theFormat =~ s/\$md5/$md5/ge;
    $theFormat =~ s/\$human/$human/ge;
    $theFormat =~ s/\$url/$theURL/ge;
    $theFormat =~ s/\$rev/"--".$revno/ge;
    $theFormat = expandStandardEscapes( $theFormat );

    return $theFormat;
}

sub get_id_human {
    my ( $web, $topic ) = @_;
    $topic ||= $Foswiki::Plugins::SESSION->{topicName};
    $web   ||= $Foswiki::Plugins::SESSION->{webName};
    $web =~ s#/.#_#g;

    my $candidate = $web . "_" . $topic;
    while ( get_topic_for_human( $candidate ) ) {
        my $time = time();
        $time = int( $time - (rand() * 1000) );
        $candidate = $web . "_" . $topic . "_" . $time;
    }

    return $candidate;
}

sub get_id_md5 {
    my ( $web, $topic ) = @_;
    $topic ||= $Foswiki::Plugins::SESSION->{topicName};
    $web   ||= $Foswiki::Plugins::SESSION->{webName};

    use Digest::MD5;
    return Digest::MD5::md5_hex( $web . $topic . time() );
}

sub write_id {
    my ( $web, $topic, $human, $md5, $no_check ) = @_;
    $topic    ||= $Foswiki::Plugins::SESSION->{topicName};
    $web      ||= $Foswiki::Plugins::SESSION->{webName};
    $no_check ||= 0;

    # check some pre-conditions
    unless ( $no_check ) {
        return 0 if not Foswiki::Func::topicExists( $web, $topic );
        return 0 if not Foswiki::Func::checkAccessPermission("CHANGE", Foswiki::Func::getCanonicalUserID(), undef, $topic, $web );
    }

    $human ||= get_id_human( $web, $topic );
    $md5   ||= get_id_md5( $web, $topic );

    my ( $meta, $text ) = Foswiki::Func::readTopic( $web, $topic );

    # return FALSE on existing ID
    my @prefs = $meta->find( 'PREFERENCE' );
    foreach my $pref ( @prefs ) {
        return 0 if ( $pref->{name} =~ m/PERM_ID_/ );
    }

    $meta->putKeyed( 'PREFERENCE', { name => "PERM_ID_HUMAN", title => "PERM_ID_HUMAN", value => $human, type=>"Local" } );
    $meta->putKeyed( 'PREFERENCE', { name => "PERM_ID_MD5",   title => "PERM_ID_MD5",   value => $md5,   type=>"Local" } );

    my $oops = Foswiki::Func::saveTopic( $web, $topic, $meta, $text );
    return 0 if $oops;

    return 1;
}

sub myGetRequestObject {
    my $object;

    if ($Foswiki::Plugins::VERSION < 2.1) {
        $object = Foswiki::Func::getCgiQuery();
    } else {
        $object = Foswiki::Func::getRequestObject();
    }

    return $object;
}

sub rest_view {
    my ($session) = @_;

    my $uri = myGetRequestObject()->uri();

    # get revision number from uri
    my $rev = 0;
    if ( $uri =~ m/--(\d+)$/ ) {
        $rev = $1;
        $uri =~ s/--\d+$//;
    };

    # get ID from uri
    my $id = q{};
    if ( $uri =~ m/\/([^\/]+)$/ ) {
      $id = $1;
    };

    # resolve ID
    my ( $web, $topic ) = ( q{}, q{} );
    if ( $id =~ m/^[A-Fa-f0-9]{32}$/ ) {
        $topic = get_topic_for_md5($id);
    } else {
        $topic = get_topic_for_human($id);
    }
    if ( !$topic ) {
        $session->{response}->status( "404 Topic not found" );
        return "<h1>404 Topic not found</h1>";
    }
    ( $web, $topic ) = Foswiki::Func::normalizeWebTopicName(q{}, $topic);

    my $redirect_url = Foswiki::Func::getScriptUrl( $web, $topic, "view" );
    if ($rev) { $redirect_url .= "?rev=$rev"; }

    Foswiki::Func::redirectCgiQuery( undef, $redirect_url, 1 );
    return "Redirecting to $redirect_url \n\n";
}

sub rest_deploy {
    my ($session) = @_;
    my $retval = "Deploying IDs... <br />";
    my $isSetWeb = myGetRequestObject()->param("web") || 0;

    if ( not Foswiki::Func::isAnAdmin() ) {
        $session->{response}->status( "403 Forbidden: You need to be an admin to do that." );
        return "<h1>403 Forbidden: You need to be an admin to do that.</h1>";
    }

    if ( not $isSetWeb ) {
        $session->{response}->status( "400 Missing parameter: web" );
        return "<h1>400 Missing parameter: web</h1>";
    }

    # sanatizing web parameter
    $isSetWeb =~ s/[^A-Za-z0-9-_.\/]//g;
    $isSetWeb =~ m/^(.*)$/;

    if ( (not $1) or (not Foswiki::Func::webExists( $isSetWeb )) ) {
        $session->{response}->status( "404 Web not found" );
        return "<h1>404 Web not found</h1>";
    } else {
      $isSetWeb = $1;
    }

    $session->{response}->status( "200 Ok" );

    my @topicList = Foswiki::Func::getTopicList( $isSetWeb );
    foreach my $topic (@topicList) {
        if ( write_id($isSetWeb, $topic, undef, undef, 1) ) {
            $retval .= "<font color='green'>$isSetWeb.$topic: ok</font> <br />";
        } else {
            $retval .= "<font color='red'>$isSetWeb.$topic: error</font>  <br />";
        }
    }

    return $retval;
}

sub beforeSaveHandler {
    my ( $text, $topic, $web, $meta ) = @_;

    # return on existing ID -> nothing more to do
    my @prefs = $meta->find( 'PREFERENCE' );
    foreach my $pref ( @prefs ) {
        return q{} if ( $pref->{name} =~ m/PERM_ID_/ );
    }

    my $human = get_id_human( $web, $topic );
    my $md5   = get_id_md5( $web, $topic );

    $meta->putKeyed( 'PREFERENCE', { name => "PERM_ID_HUMAN", title => "PERM_ID_HUMAN", value => $human, type=>"Local" } );
    $meta->putKeyed( 'PREFERENCE', { name => "PERM_ID_MD5",   title => "PERM_ID_MD5",   value => $md5,   type=>"Local" } );

    return q{};
}


# taken from Foswiki.pm
# should be exported to Func
sub expandStandardEscapes {
    my $text = shift;
    $text =~ s/\$n\(\)/\n/gos;    # expand '$n()' to new line
    $text =~ s/\$n([^A-Za-z]|$)/\n$1/gos;  # expand '$n' to new line
    $text =~ s/\$nop(\(\))?//gos;      # remove filler, useful for nested search
    $text =~ s/\$quot(\(\))?/\"/gos;   # expand double quote
    $text =~ s/\$percnt(\(\))?/\%/gos; # expand percent
    $text =~ s/\$dollar(\(\))?/\$/gos; # expand dollar
    $text =~ s/\$lt(\(\))?/\</gos;     # expand less than
    $text =~ s/\$gt(\(\))?/\>/gos;     # expand greater than
    $text =~ s/\$amp(\(\))?/\&/gos;    # expand ampersand
    return $text;
}

1;
__END__
This copyright information applies to the PermLinkPlugin:

# PermLinkPlugin is a
# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# For licensing info read LICENSE file in the Foswiki root.
