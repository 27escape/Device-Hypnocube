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

use Test::More tests => 3;

BEGIN { use_ok('Device::Hypnocube'); }

my $cube = Device::Hypnocube->new( serial => '/dev/ttyS0' );
isa_ok( $cube, 'Device::Hypnocube' );

# we cannot test if the cube can connect to a hypnocube as not many people have them

SKIP: {

    if ( $ENV{AUTHOR_TESTING} ) {

        subtest 'authors_own' => sub {
            plan tests => 1;    # we need to add some data for the search tests
            ok( 1, "ready for more tests" );
        };
    }
    else {
        subtest 'not_author' => sub {
            plan tests => 1;
            ok( 1, "no more user tests" );
        };
    }
}

# -----------------------------------------------------------------------------
# completed all the tests
