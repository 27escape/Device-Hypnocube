#!/usr/bin/perl -w

=head1 NAME

app.t

=head1 DESCRIPTION

test Device::Hypnocube

=head1 AUTHOR

 kevin mulholland, moodfarm@cpan.org

=cut

use strict;
use warnings;
use Try::Tiny;
use File::Basename;

use Test::More tests => 2;

BEGIN { use_ok('Device::Hypnocube'); }


# we cannot test if the cube can connect to a hypnocube as not many people have them

SKIP: {

    # if you do not have a serial port or access to it you cannot test
    if ( $ENV{HAS_TTY} ) {

        subtest 'has_tty' => sub {
            plan tests => 1;    # we need to add some data for the search tests
            my $cube = Device::Hypnocube->new( serial => '/dev/ttyS0' );
            isa_ok( $cube, 'Device::Hypnocube' );
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
