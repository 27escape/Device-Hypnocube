#!/usr/bin/perl -w

=head1 NAME

app.t

=head1 DESCRIPTION

test Device::Hypnocube

=head1 AUTHOR

 kevin mulholland, moodfarm@cpan.org

=cut

use 5.10.0 ;
use strict;
use warnings;
use Try::Tiny;
use File::Basename;

use Test::More tests => 2;

BEGIN { use_ok('Device::Hypnocube'); }


# we cannot test if the cube can connect to a hypnocube as not many people have them

SKIP: {

    # if you do not have a serial port or access to it you cannot test
    if ( $ENV{AUTHOR_TESTING} ) {

        subtest 'has_tty' => sub {
            plan tests => 4;    # we need to add some data for the search tests
            my $cube = Device::Hypnocube->new( serial => '/dev/ttyS0' );
            isa_ok( $cube, 'Device::Hypnocube' );

            my @colors = $cube->get_color( 'brightred') ;
            ok( $colors[0] == 255 && !$colors[1] && !$colors[2], 'brightred is correct') ;
            my @rand = $cube->get_color( 'random') ; 
            ok( scalar( @rand) == 3 , 'we got some random color') ;
            my @rand2 = $cube->get_color( 'random') ;
            my $r = sprintf( "%03d%03d%03d", @rand) ;
            my $r2 = sprintf( "%03d%03d%03d", @rand2) ;
            cmp_ok( $r, 'ne', $r2 , 'we got a different random color') ;
            # no other tests as its pretty much all visual feedback
        };
    }
    else {
        subtest 'no_tty' => sub {
            plan tests => 1;
            ok( 1, "no more user tests" );
        };
    }
}

# -----------------------------------------------------------------------------
# completed all the tests
