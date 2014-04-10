# ABSTRACT: Control a hypnocube

=head1 NAME

 Device::Hypnocube

=head1 SYNOPSIS

    my $cube = Device::Hypnocube->new( serial => '/dev/ttyS1' );
    $cube->clear() ;
    $cube->xplane( 0, 'red') ;
    $cube->update() ;

=head1 DESCRIPTION

Control the 4x4x4 Hypnocube available from usb.brando.com
see also http://www.hypnocube.com/
I consider the front to be the side with the power and serial connectors
0,0,0 is then at bottom back left

=head1 AUTHOR

 kevin mulholland, moodfarm@cpan.org

=head1 VERSIONS

 v1.1  2014-03-05  adding in background processing
 v0.4  2013-05-03  use Moo and all that that entails
 v0.3  2011-03-14  open write perms of buffer file
 v0.2  2011-01-26  adding rate limiting
 v0.1  2010-12-31  initial work

=head1 Methods

=cut

package Device::Hypnocube;

use 5.010;
use strict;
use warnings;
use Moo;
use Time::HiRes qw( gettimeofday usleep);

# get the crc stuff, this is the function we need
use Digest::CRC qw( crcccitt );
use Data::Hexdumper;

# the bit that does the actual serial comms
use Device::Hypnocube::Serial;
use Path::Tiny;
use YAML::XS qw( Load Dump);
use Try::Tiny;

use constant HYPNOCUBE_SYNC       => 0xc0;
use constant HYPNOCUBE_ESC        => 0xdb;
use constant HYPNOCUBE_LAST_PKT   => 0x60;
use constant HYPNOCUBE_NEXT_PKT   => 0x40;
use constant HYPNOCUBE_CHALLENGE  => 0xabadc0de;
use constant HYPNOCUBE_MAX_PACKET => 50;           # max length of a packet to send

# these are the commands we can send to the device
use constant HYPNOCUBE_LOGIN  => 0;
use constant HYPNOCUBE_LOGOUT => 1;
use constant HYPNOCUBE_RESET  => 10;
use constant HYPNOCUBE_INFO   => 11;
use constant HYPNOCUBE_VERS   => 12;
use constant HYPNOCUBE_ERR    => 20;
use constant HYPNOCUBE_ACK    => 25;
use constant HYPNOCUBE_PING   => 60;
use constant HYPNOCUBE_FLIP   => 80;
use constant HYPNOCUBE_FRAME  => 81;
use constant HYPNOCUBE_PIXEL  => 81;

use constant X_SIZE      => 4;
use constant Y_SIZE      => 4;
use constant Z_SIZE      => 4;
use constant BUFFER_SIZE => X_SIZE * Y_SIZE * Z_SIZE;

use constant RATE_LIMIT_MSECS => 3333;    # 1/30 * 1e6

# where we will save the buffer between runs
use constant BUFFER_FILE => '/tmp/hypnocube.buffer';

my %errors = (
    0  => 'no error',
    1  => 'timeout ‐ too long of a delay between packets',
    2  => 'missing packet, followed by missing sequence number',
    3  => 'invalid checksum',
    4  => 'invalid type (2 and 3 defined for now)',
    5  => 'invalid sequence counter',
    6  => 'missing SYNC ‐ SYNC out of order (2 SYNC in a row, for example)',
    7  => 'invalid packet length',
    8  => 'invalid command',
    9  => 'invalid data (valid command)',
    10 => 'invalid ESC sequence ‐ illegal byte after ESC byte',
    11 => 'overflow ‐ too much data was fed in with the packets',
    12 => 'command not implemented (in case command deliberately no allowed)',
    13 => 'invalid login value'
);

my %colors = (
    black       => [ 0,    0,    0 ],
    lilac       => [ 0xf0, 0,    0xf0 ],
    orange      => [ 0xf0, 0x20, 0 ],
    amber       => [ 0xf0, 0x20, 0 ],
    warmwhite   => [ 0xa0, 0xa0, 0xa0 ],
    purple      => [ 0x10, 0,    0x10 ],
    lightpurple => [ 0x40, 0,    0x40 ],

    # colors are now generated
    # darkblue    => [ 0,    0,    0x10 ],
    # blue        => [ 0,    0,    0xf0 ],
    # cyan        => [ 0,    0x60, 0x60 ],
    # darkgreen   => [ 0,    0x10, 0 ],
    # green       => [ 0,    0xf0, 0 ],
    # red         => [ 0xf0, 0,    0 ],
    # darkred     => [ 0x10, 0,    0 ],
    # white       => [ 0xf0, 0xf0, 0xf0 ],
    # yellow      => [ 0xf0, 0xf0, 0 ],
    # magenta     => [ 0xa0, 0,    0xa0 ],
    pink => [ 0xf0, 0x00, 0x20 ]
);

# ----------------------------------------------------------------------------
# instance initialisation
# ----------------------------------------------------------------------------

has 'error_info' => (
    is => 'ro'

        # , isa           => 'HashRef'
    , init_arg => undef                # prevent setting this in initialisation
    , writer   => '_set_error_info'    # we want to be able to set this in this module only
);

has 'login_state' => (
    is => 'ro'

        #     , isa           => 'Integer'
    , init_arg => undef                # prevent setting this in initialisation
    ,
    default => sub {0},
    writer  => '_set_login_state' # we want to be able to set this in this module only
);

has 'device_info' => (
    is => 'ro'

        # , isa           => 'HashRef'
    , init_arg => undef                # prevent setting this in initialisation
    ,
    predicate => 'has_info',
    clearer   => '_clear_info',
    writer    => '_set_device_info'    # we want to be able to set this in this module only
);

# get _debug info out
has 'verbose' => (
    is => 'rw'

        #     , isa           => 'Integer'
    ,
    default => sub {0}
);

has 'buffer' => (
    is => 'ro'

        # , isa           => 'ArrayRef'
    , init_arg => undef    # prevent setting this in initialisation
    ,
    default => sub { [] },
    writer  => '_set_buffer'
);

# get the time as a float, including the microseconds
has 'last_rate_limit' => (
    is => 'rw'

        #     , isa           => 'Float'
    , init_arg => undef    # prevent setting this in initialisation
    ,
    default => sub { my ( $t, $u ) = gettimeofday(); $t + ( $u / 1000000 ); },
    writer => '_set_last_rate_limit'
);

# ----------------------------------------------------------------------------
# special method called BEFORE the class is properly instanced
# we can modify passed params if needed
around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;
    my $opt   = @_ % 2 ? die("Odd number of values passed where even is expected.") : {@_};

    # here we can extract and extra args we want to process but do not have
    # object variables for

    my @prefix = ( "dark", "mid", "", "bright" );

    # add extra color names for primaries and close relatives
    for ( my $i = 0; $i <= 3; $i++ ) {
        my $c = ( 64 * ( $i + 1 ) ) ;
        $c = $c > 256 ? 255 : $c ;
        my $p = $prefix[$i];
        $colors{ $p . "red" } = [ $c, 0, 0 ];
        $colors{ $p . "green" } = [ 0, $c, 0 ];
        $colors{ $p . "blue" } = [ 0, 0, $c ];

        $colors{ $p . "magenta" } = [ $c, 0, $c ];
        $colors{ $p . "yellow" } = [ $c, $c, 0 ];
        $colors{ $p . "cyan" } = [ 0, $c, $c ];
        $colors{ $p . "white" } = [ $c, $c, $c ];
    }

    # now build the class properly
    return $class->$orig(@_);
};

# ----------------------------------------------------------------------------

=head2 new

Establish a serial connection with the Hypnocube device

=head3 Parameters

=over 4

=item serial 

serial port device, eg /dev/ttyS1

=item timeout

timeout for serial connection, default 10s

=item verbose

output extra _debugging information

=item do_not_init

Do not connect to the hypnocube

=back

=cut

sub BUILD {
    my $self = shift;
    my $args = shift;

    # add the serial port if it was passed to us
    if ( $args->{serial} ) {

        # this should connect too
        $self->{serial} = Device::Hypnocube::Serial->new($args);
    }
    else {
        die "serial argument is required";
    }
}

# ----------------------------------------------------------------------------
# DEMOLISH
# called to as part of destroying the object

sub DEMOLISH {
    my $self = shift;
}

# ----------------------------------------------------------------------------
# instance variables and handlers
# some of these are the things being $self->send_data( HYPNOCUBE_ERR, 0)assed to new
# ----------------------------------------------------------------------------

# sub set_error {
#     my $self = shift;
#     my $code = shift;

#     my $errmsg = { code => $code, error => $errors{$code} };
#     $self->_set_error_info($errmsg);

#     $self->_debug("error: $errors{$code}");
# }

# ----------------------------------------------------------------------------

=head2 ping

 send a ping to the device, let it know that we are still here
 we need to keep doing this to stop it droping into auto display mode
 though in practice it seems like we do not need to do this

=cut

sub ping {
    my $self = shift;

    $self->_debug('ping');

    # if something is doing something with the serial thats as good as a ping
    return if ( $self->{serial}->{activity} );

    # no response possible from a ping, but then again there may be!
    $self->send_data( HYPNOCUBE_PING, '', 1 );
}

# ----------------------------------------------------------------------------

=head2 login

tell the device we want to use it

=cut

sub login {
    my $self = shift;

    $self->_debug('login');

    # no need to login again
    return if ( $self->login_state() );

    my $resp = $self->send_data( HYPNOCUBE_LOGIN, pack( 'N', HYPNOCUBE_CHALLENGE ) );

    if ( $resp->{cmd} == HYPNOCUBE_ACK || ( $resp->{cmd} == HYPNOCUBE_ERR && $self->error_info->{code} == 0 ) ) {
        $self->_set_login_state(1);

        #         $self->info() ;     # update the info
        my $hashref;
        if ( -f BUFFER_FILE ) {
            $hashref = Load( path(BUFFER_FILE)->slurp );
        }

        # use the buffer otherwise clear to black
        if ($hashref) {
            $self->_set_buffer($hashref);
            $self->update();
        }
        else {
            $self->clear('black');
            $self->update();
        }
    }
    else {
        $self->_debug( "resp " . $resp->{cmd} . " " . HYPNOCUBE_ERR . " code " . $self->error_info->{code} );
    }
}

# ----------------------------------------------------------------------------

=head2 logout

tell the device we are finished with it

=cut

sub logout {
    my $self = shift;

    $self->_debug('logout');

    # dont logout if we are not logged in
    return if ( !$self->login_state() );

    # don't wait for a response
    my $resp = $self->send_data( HYPNOCUBE_LOGOUT, '', 1 );

    $self->_set_login_state(0);

    # and dump what we know about the device
    $self->_clear_info();
}

# ----------------------------------------------------------------------------

=head2 info

Ask the device for info, also gets version, fetched during login

=cut

sub info {
    my $self = shift;
    my %info = ();

    return $self->device_info() if ( $self->has_info() );
    $self->_debug('info');

    my $resp = $self->send_data( HYPNOCUBE_INFO, pack( 'CC', 0, 0 ) );
    $info{name} = $resp->{payload};
    $resp = $self->send_data( HYPNOCUBE_INFO, pack( 'CC', 0, 1 ) );
    $info{desc} = $resp->{payload};
    $resp = $self->send_data( HYPNOCUBE_INFO, pack( 'CC', 0, 2 ) );
    $info{copyright} = $resp->{payload};
    $resp = $self->send_data( HYPNOCUBE_VERS, '' );

    ( $info{hw_major}, $info{hw_minor}, $info{sw_major}, $info{sw_minor}, $info{proto_major}, $info{proto_minor} ) = unpack( 'CCCCCC', $resp->{payload} );

    # set the info
    $self->_set_device_info( \%info );

    return \%info;
}

# ----------------------------------------------------------------------------

=head2 reset

reset the device

=cut

sub reset {
    my $self = shift;

    $self->_debug('reset');

    $self->send_data( HYPNOCUBE_RESET, '', 1 );
}

# ----------------------------------------------------------------------------

=head2 last_error

ask the device for the last error we caused

=cut

sub last_error {
    my $self = shift;

    $self->_debug('last_error');

    my $resp = $self->send_data( HYPNOCUBE_ERR, 0 );

    $self->set_error( unpack( 'C', $resp->{payload} ) );

    # and reset the error
    $self->send_data( HYPNOCUBE_ERR, -2 );
}

# ----------------------------------------------------------------------------
# _ack
# tell the device we got the data

sub _ack {
    my $self = shift;

    $self->_debug('_ack');

    my $resp = $self->send_data( HYPNOCUBE_ACK, '' );
}

# ----------------------------------------------------------------------------
# _rate_limit
# make sure that we do not send data too quickly, will pause before allowing
# more things to be sent

sub _rate_limit {
    my $self = shift;

    # get current time
    my ( $seconds, $microseconds ) = gettimeofday;

    # easier to play with as a float
    my $ftime = $seconds + ( $microseconds / 1000000 );
    my $lasttime = $self->last_rate_limit();

    # calc in big microsecs the time elapse since last time
    my $elapsed = ( $ftime - $lasttime ) * 1000000;

    # if we need to pause to make up the time, do it now
    if ( $elapsed < RATE_LIMIT_MSECS ) {
        my $pause = RATE_LIMIT_MSECS - $elapsed;
        usleep($pause);
    }

    # update the last update with now
    $self->_set_last_rate_limit($ftime);
}

# ----------------------------------------------------------------------------
# _get_response
# read stuff from the device

sub _get_response {
    my $self   = shift;
    my %packet = ();

    # if something is doing something wait till its over
    while ( $self->{serial}->{activity} ) {
        sleep(1);
    }

    # we read and discard till we get a sync frame
    my $tmp = '';
    while (1) {
        my $r = $self->{serial}->read(1);
        if ( !$r ) {
            sleep 1;
        }
        else {
            my $c = unpack( 'C', $r );
            if ( $c == HYPNOCUBE_SYNC ) {
                $packet{sync_head} = $c;
                last;
            }
            $tmp .= $r;
        }
    }

    $packet{type}   = unpack( 'C', $self->{serial}->read(1) );
    $packet{length} = unpack( 'C', $self->{serial}->read(1) );
    $packet{dest}   = unpack( 'C', $self->{serial}->read(1) );

    # split type into sequence and type
    $packet{sequence} = $packet{type} & 0x1f;
    $packet{type}     = $packet{type} & 0xe0;

    my $payload_fmt = 'C' x $packet{length};
    $packet{cmd} = unpack( $payload_fmt, $self->{serial}->read(1) );

    # payload is not unpacked the caller will have to do that
    $packet{payload}   = $self->{serial}->read( $packet{length} - 1 );
    $packet{chksum}    = unpack( 'n', $self->{serial}->read(2) );
    $packet{sync_tail} = unpack( 'C', $self->{serial}->read(1) );

    if ( $packet{cmd} == HYPNOCUBE_ERR ) {
        $self->set_error( unpack( 'C', $packet{payload} ) );
    }
    else {
        $self->set_error(0);
    }

    return \%packet;
}

# ----------------------------------------------------------------------------
# _build_packet
# build a packet to send to the device, the payload should already be in the right
# format, ie packed

sub _build_packet {
    my $self = shift;
    my ( $payload, $seq, $type ) = @_;
    my $sync = pack( 'C', HYPNOCUBE_SYNC );

    $seq %= 31;    # sequence count wraps at 32

    $self->_debug( "_build_packet\n" . hexdump( data => $payload, suppress_warnings => 1 ) );
    my $plen        = length($payload);
    my $payload_fmt = 'C' x $plen;

    # create the header, then add the data
    # top 3 bits show 224 end packet, 128 not last packet
    # next 5 bits show packet sequence number
    my $out = pack( 'C', ( $type ? HYPNOCUBE_LAST_PKT : HYPNOCUBE_NEXT_PKT ) + ( $seq & 0x1f ) ) . pack( 'C', $plen )    # length
        . pack( 'C', 0 )                                                                                                 # broadcast
        . $payload;                                                                                                      # already packed by caller

    # get the crc on everything so far
    my $crc = crcccitt($out);

    # add crc onto end
    $out .= pack( 'n', $crc );

    # now fixup the data so that it has bits replaced SYNC for ESC
    # ESC for ESC ESC
    my $newdata = '';
    my $fmt     = 'C' x length($out);
    my $count   = 0;
    for ( my $offset = 0; $offset < length($out); $offset++ ) {
        my $c = unpack( 'C', substr( $out, $offset, 1 ) );
        if ( $c == HYPNOCUBE_SYNC ) {
            $newdata .= pack( 'CC', HYPNOCUBE_ESC, HYPNOCUBE_ESC + 1 );
        }
        elsif ( $c == HYPNOCUBE_ESC ) {
            $newdata .= pack( 'CC', HYPNOCUBE_ESC,, HYPNOCUBE_ESC + 2 );
        }
        else {
            $newdata .= pack( 'C', $c );
        }
    }

    # replace out with the fixedup data add in crc then
    # wrap the sync framing bytes around the packet
    $out = $sync . $newdata . $sync;

    $self->_debug( "packet $seq\n" . hexdump( data => $out, suppress_warnings => 1 ) );

    return $out;
}

# ----------------------------------------------------------------------------

=head2 send_data

send stuff to the device
the payload should already be in the right format, ie packed

=cut

sub send_data {
    my $self = shift;
    my ( $cmd, $data, $noresp ) = @_;
    $self->_debug( 'send_data cmd ' . $cmd );
    $self->_debug( "data\n" . hexdump( data => $data, suppress_warnings => 1 ) ) if ($data);

    if ( !defined $cmd && !defined $data ) {
        $self->_debug('no command specified');
        return {};
    }

    $data ||= '';
    my $seq = 0;

    # make sure we do not send data too quickly
    $self->_rate_limit();

    # add the command to send onto the front of the data
    $data = pack( 'C', $cmd ) . $data;
    my $last_packet_flag = 0;
    while ( !$last_packet_flag ) {
        my $size = length($data);
        if ( $size > HYPNOCUBE_MAX_PACKET ) {
            $size = HYPNOCUBE_MAX_PACKET;
        }
        else {
            $last_packet_flag = 1;
        }

        # get bytes to send
        my $send = substr( $data, 0, $size );

        # shift data along a bit
        $data = substr( $data, $size );

        my $packet = $self->_build_packet( $send, $seq, $last_packet_flag );
        $self->{serial}->write( $packet, length($packet) );
        $seq++;
    }

    my $resp;

    # now get the response if we want it
    $resp = $self->_get_response() if ( !$noresp );

    return $resp;
}

# ----------------------------------------------------------------------------

=head2 update

update the display on the cube

=cut

sub update {
    my $self = shift;

    my @bytes;

    $self->_debug('update');
    if ( !$self->login_state() ) {
        $self->_debug('not possible, login first');
        return 0;
    }

    # get the packed display buffer
    @bytes = @{ $self->get_bytes() };
    if ( scalar(@bytes) && defined $bytes[0] ) {
        my $str = pack( 'C' x scalar(@bytes), @bytes );

        $self->_debug( "-" x 79 );
        my $resp = $self->send_data( HYPNOCUBE_FRAME, $str );
        $self->_debug( "-" x 79 );

        if ( $resp->{cmd} == HYPNOCUBE_ACK ) {

            # we send the frame then flip the buffer to 'on'
            $self->flip();

            # save the data to a file for later retrieval if needed
            path(BUFFER_FILE)->spew( Dump( $self->buffer() ) );

            # just in case different users use this, allow group write too
            chmod( 0664, BUFFER_FILE );
        }

        return $resp->{cmd} == HYPNOCUBE_ACK;
    }
    else {
        return 0;
    }
}

# ----------------------------------------------------------------------------

=head2 flip

flip display buffer

=cut

sub flip {
    my $self = shift;
    $self->_debug('flip');
    $self->send_data( HYPNOCUBE_FLIP, '', 1 );
}

# ----------------------------------------------------------------------------

=head2 list_colors

show what colors are available

=cut

sub list_colors {
    my $self = shift;
    return keys %colors;
}

# ----------------------------------------------------------------------------

=head2 get_color

determine the colors or use a default

=cut

sub get_color {
    my $self = shift;
    my ( $color, $green, $blue, $default ) = @_;

    if ( defined $color && $color =~ /^(?:0[xX]|#)([[:xdigit:]]+)$/ && !defined $green && !defined $blue ) {
        my $c = $1;
        if ( length($c) == 2 ) {
            $color = $green = $blue = hex($c);
        }
        elsif ( length($c) == 6 ) {
            $c =~ /([[:xdigit:]]{2})([[:xdigit:]]{2})([[:xdigit:]]{2})/;
            $color = hex($1);
            $green = hex($2);
            $blue  = hex($3);
        }
        else {
            $self->_debug("bad hex color specified must be like #ab34f0 or 0xab34f0");
            $color = $default;
        }
    }

    if ( defined $color && $color =~ /^\d+/ && !defined $green && !defined $blue ) {
        $green = $blue = $color;
    }
    elsif ( !defined $color && !defined $green && !defined $blue ) {
        $self->_debug("no color using default");
        $color = $default;
    }
    elsif ( !$colors{$color} && !defined $green && !defined $blue ) {
        $self->_debug("unknown color $color, using white");
        $color = 'white';
    }
    ( $color, $green, $blue ) = @{ $colors{$color} } if ( $colors{$color} );

    # say "$color, $green, $blue" ;

    return ( $color, $green, $blue );
}

# ----------------------------------------------------------------------------

=head2 clear

clear the display to a block of color

=cut

sub clear {
    my $self = shift;
    my ( $color, $green, $blue ) = @_;

    my @buff = ();

    ( $color, $green, $blue ) = $self->get_color( $color, $green, $blue, 'black' );

    foreach my $i ( 0 .. ( BUFFER_SIZE - 1 ) ) {
        push @buff, [ $color, $green, $blue ];
    }
    $self->_set_buffer( \@buff );
}

# ----------------------------------------------------------------------------

=head2 set_buffer

set the buffer from an array of

=cut

sub set_buffer {
    my $self = shift;
    my ($buf) = @_;

    # assume buffer is correct size
    $self->_set_buffer($buf);
}

# ----------------------------------------------------------------------------

=head2 get_buffer

get the buffer

=cut

sub get_buffer {
    my $self = shift;

    return $self->buffer;
}

# ----------------------------------------------------------------------------

=head2 buffer_offset

calculate the offset into a display buffer for a given pixel
returns the offset

=cut

sub buffer_offset {
    my $self = shift;
    my ( $x, $y, $z ) = @_;

    # limit size, wrap around
    $x %= X_SIZE;
    $y %= Y_SIZE;
    $z %= Z_SIZE;

    # get x other way around
    $x = X_SIZE - 1 - $x;

    return ( $y * Z_SIZE * Y_SIZE ) + ( $z * Y_SIZE ) + $x;
}

# ----------------------------------------------------------------------------

=head2 pixel

set a pixel in the display to a color
if green blue undef then color looks up in colors, if color missing then
error returned and nothing set
return 0 OK, 1 error

=cut

sub pixel {
    my $self = shift;
    my ( $x, $y, $z, $color, $green, $blue ) = @_;

    if ( !defined $x || !defined $y || !defined $z || $x < 0 || $y < 0 || $z < 0 ) {
        $self->_debug('bad pixel args');
        return 1;
    }

    # get the color or default to white
    ( $color, $green, $blue ) = $self->get_color( $color, $green, $blue, 'white' );

    # get the colors if we are using a named color
    if ( defined $color && !defined $green && !defined $blue ) {
        my $t = $color;
        ( $color, $green, $blue ) = @{ $colors{$color} };
    }

    # make sure we are writing correct things to the buffer
    if ( int($color) == $color && int($green) == $green && int($blue) == $blue ) {

        # set the pixel
        my $offset = $self->buffer_offset( $x, $y, $z );
        $self->{buffer}[$offset] = [ $color, $green, $blue ];
    }
    else {
        $self->_debug("One of the colors does not evaluate to a number");
    }
    return 0;
}

# ----------------------------------------------------------------------------

=head2 xplane

set one place of the display to be a single color
plane should be 0..Y_SIZE, ie 0..3
return 0 OK, 1 error, 2 out of range

=cut

sub xplane {
    my $self = shift;
    my ( $plane, $color, $green, $blue ) = @_;

    return 2 if ( !defined $plane || $plane < 0 || $plane > Y_SIZE - 1 );

    try {
        for ( my $x = 0; $x < X_SIZE; $x++ ) {
            for ( my $z = 0; $z < Z_SIZE; $z++ ) {
                $self->pixel( $x, $plane, $z, $color, $green, $blue );
            }
        }
    }
    catch {};
}

# ----------------------------------------------------------------------------

=head2 yplane

set one place of the display to be a single color
plane should be 0..Y_SIZE, ie 0..3
return 0 OK, 1 error, 2 out of range

=cut

sub yplane {
    my $self = shift;
    my ( $plane, $color, $green, $blue ) = @_;

    return 2 if ( !defined $plane || $plane < 0 || $plane > X_SIZE - 1 );

    for ( my $y = 0; $y < Y_SIZE; $y++ ) {
        for ( my $z = 0; $z < X_SIZE; $z++ ) {
            $self->pixel( $plane, $y, $z, $color, $green, $blue );
        }
    }
}

# ----------------------------------------------------------------------------

=head2 zplane

set one plane of the display to be a single color
plane should be 0..Z_SIZE, ie 0..3
return 0 OK, 1 error, 2 out of range

=cut

sub zplane {
    my $self = shift;
    my ( $plane, $color, $green, $blue ) = @_;

    return 2 if ( !defined $plane || $plane < 0 || $plane > Z_SIZE - 1 );

    for ( my $x = 0; $x < X_SIZE; $x++ ) {
        for ( my $y = 0; $y < Y_SIZE; $y++ ) {
            $self->pixel( $x, $y, $plane, $color, $green, $blue );
        }
    }
}

# ----------------------------------------------------------------------------

=head2 get_bytes

get the buffer as an arayref of bytes suitable for throwing at the hypnocube

=cut

sub get_bytes {
    my $self   = shift;
    my $count  = 0;
    my $last_b = 0;
    my @bytes  = ();

    try {
        foreach my $pix ( @{ $self->buffer() } ) {

            # get the rgb values
            my ( $r, $g, $b ) = @$pix;

            # we only want the most significant 4 bits of a byte
            $r = ( $r >> 4 ) & 0xf;
            $g = ( $g >> 4 ) & 0xf;
            $b = ( $b >> 4 ) & 0xf;

            # only save on every other pixel
            if ( $count & 1 ) {

                # save next 2 byes of data, b+r then g+b
                push @bytes, ( $last_b << 4 ) + $r;
                push @bytes, ( $g << 4 ) + $b;
            }
            else {
                # save first byes of data, r+g
                push @bytes, ( $r << 4 ) + $g;
                $last_b = $b;
            }
            $count++;
            last if ( $count >= BUFFER_SIZE );
        }
    }
    catch {
        $self->_debug($_);
        @bytes = undef;
    };
    return \@bytes;
}

# ----------------------------------------------------------------------------
#_debug
# write sa debug msg to STDERR

sub _debug {
    my $self = shift;
    my ( $msg, $type ) = @_;

    print STDERR "$msg\n" if ( $self->verbose() );
}

# -----------------------------------------------------------------------------

1;

__END__

