# ABSTRACT: Talk to a hypnocube over a serial link

=head1 NAME

 Device::Hypnocube::Serial

=head1 SYNOPSIS

my $conn = Device::Hypnocube::Serial->new( serial => '/dev/ttyS1');

=head1 DESCRIPTION

 Used internally by Device::Hypnocube
 taken from L<GPS::Serial> and repurposed, any errors are likely mine

 Copyright (c) 1999-2000 Joao Pedro Goncalves <joaop@sl.pt>. All rights reserved.
 This program is free software; you can redistribute it and/or
 modify it under the same terms as Perl itself.

=head1 AUTHOR

 Joao Pedro B Goncalves, joaop@sl.pt (L<GPS::Serial>)
 kevin mulholland, moodfarm@cpan.org (Device::HypnoCube::Serial)

=head1 VERSIONS

 v0.1  31/12/2010, initial work to change from L<GPS::Serial>

=head1 SEE ALSO

L<GPS::Serial>

Peter Bennett's GPS www and ftp directory:

    L<ftp://sundae.triumf.ca/pub/peter/index.html>
    L<http://vancouver-webpages.com/peter/idx_garmin.html>

=head1 Functions and Methods

=cut

package Device::Hypnocube::Serial ;

use 5.010 ;
use strict ;
use warnings ;

use vars qw( $OS_win $has_serialport $stty_path) ;

use constant DEFAULT_BAUD       => 38400 ;
use constant DEFAULT_TIMEOUT    => 10 ;

# -----------------------------------------------------------------------------

=head2 BEGIN

 initialise the object

=cut

BEGIN {

    #Taken from SerialPort/eg/any_os.plx

    #We try to use Device::SerialPort or
    #Win32::SerialPort, if it's not windows
    #and there's no Device::SerialPort installed,
    #then we just use the FileHandle module that
    #comes with perl

    $OS_win = ( $^O eq "MSWin32" ) ? 1 : 0 ;

    if ($OS_win) {
        eval "use Win32::SerialPort" ;
        die "Must have Win32::SerialPort correctly installed: $@\n" if ($@) ;
        $has_serialport++ ;
    }
    elsif ( eval q{ use Device::SerialPort; 1 } ) {
        $has_serialport++ ;
    }
    elsif ( eval q{ use POSIX qw(:termios_h); use FileHandle; 1} ) {
        # NOP
    }
    elsif ( -x "/bin/stty" ) {
        $stty_path = "/bin/stty" ;
    }
    else {
        die
          "Missing either POSIX, FileHandle, Device::SerialPort or /bin/stty" ;
    }
}    # End BEGIN


# -----------------------------------------------------------------------------

=head2 new

 instance the object

=cut

sub new {
    my $class = shift;
    my $param = shift ;

    my $port = $param->{serial} ||
    ($^O eq 'MSWin32'
     ? 'COM1'
     : ($^O =~ /^(?:(?:free|net|open)bsd|bsd(?:os|i))$/
        ? (-e '/dev/cuad0'
           ? '/dev/cuad0' # FreeBSD 6.x and later
           : '/dev/cuaa0'
          )
        : '/dev/ttyS1'
       )
    );

    my $self = bless {
        'port'          =>  $port
        , 'baud'        =>  DEFAULT_BAUD
        , 'timeout'     =>  $param->{timeout} || DEFAULT_TIMEOUT
        , 'verbose'     =>  $param->{verbose}
    } ;
    bless $self, $class;

    $self->connect unless $param->{do_not_init};

    return $self;
}

# -----------------------------------------------------------------------------

=head2 connect

 connect to the device, general interface

=cut

sub connect {
    my $self = shift ;
    return $self->serial if $self->serial ;

    if ( $OS_win || $has_serialport ) {
        $self->{serial} = $self->serialport_connect ;
    }
    elsif ( defined $stty_path ) {
        $self->{serial} = $self->stty_connect ;
    }
    else {
        $self->{serial} = $self->unix_connect ;
    }

    print "Using $$self{serialtype}\n" if $self->verbose ;
}

# -----------------------------------------------------------------------------

=head2 serialport_connect

 connect to the device using either Win32::SerialPort or Device::SerialPort

=cut

sub serialport_connect {
    my $self = shift ;
    my $PortObj = (
                    $OS_win
                    ? ( new Win32::SerialPort( $self->{port} ) )
                    : ( new Device::SerialPort( $self->{port} ) )
    ) || die "Can't open $$self{port}: $!\n" ;

    $PortObj->baudrate( $self->{baud} ) ;
    $PortObj->parity("none") ;
    $PortObj->databits(8) ;
    $PortObj->stopbits(1) ;
    $PortObj->read_interval(5) if $OS_win ;
    $PortObj->write_settings ;
    $self->{serialtype} = 'SerialPort' ;
    $PortObj ;
}

# -----------------------------------------------------------------------------

=head2 unix_connect

 connect to the device using unix methods

=cut

sub unix_connect {

    #This was adapted from a script on connecting to a sony DSS, credits to its author (lost his email)
    my $self = shift ;
    my $port = $self->{port} ;
    my $baud = $self->{baud} ;
    my ( $termios, $cflag, $lflag, $iflag, $oflag, $voice ) ;

    my $serial = new FileHandle("+>$port") || die "Could not open $port: $!\n" ;

    $termios = POSIX::Termios->new() ;
    $termios->getattr( $serial->fileno() ) || die "getattr: $!\n" ;
    $cflag = 0 | CS8() | CREAD() | CLOCAL() ;
    $lflag = 0 ;
    $iflag = 0 | IGNBRK() | IGNPAR() ;
    $oflag = 0 ;

    $termios->setcflag($cflag) ;
    $termios->setlflag($lflag) ;
    $termios->setiflag($iflag) ;
    $termios->setoflag($oflag) ;
    $termios->setattr( $serial->fileno(), TCSANOW() ) || die "setattr: $!\n" ;
    eval qq[
                  \$termios->setospeed(POSIX::B$baud) || die "setospeed: \$!\n";
                  \$termios->setispeed(POSIX::B$baud) || die "setispeed: \$!\n";
        ] ;

    die $@ if $@ ;

    $termios->setattr( $serial->fileno(), TCSANOW() ) || die "setattr: $!\n" ;

    $termios->getattr( $serial->fileno() ) || die "getattr: $!\n" ;
    for ( 0 .. NCCS() ) {
        if ( $_ == NCCS() ) {
            last ;
        }
        if ( $_ == VSTART() || $_ == VSTOP() ) {
            next ;
        }
        $termios->setcc( $_, 0 ) ;
    }
    $termios->setattr( $serial->fileno(), TCSANOW() ) || die "setattr: $!\n" ;

    $self->{serialtype} = 'FileHandle' ;
    $serial ;
}

# -----------------------------------------------------------------------------

=head2 stty_connect

 connect using a tty

=cut

sub stty_connect {
    my $self = shift ;
    my $port = $self->{port} ;
    my $baud = $self->{baud} ;
    my ( $termios, $cflag, $lflag, $iflag, $oflag, $voice ) ;

    if ( $^O eq 'freebsd' ) {
        my $cc =
          join( " ",
                map { "$_ undef" }
                         qw(eof eol eol2 erase erase2 werase kill quit susp dsusp lnext reprint status)
          ) ;
        system(
"$stty_path <$port cs8 cread clocal ignbrk ignpar ospeed $baud ispeed $baud $cc"
        ) ;
        warn "$stty_path failed" if $? ;
        system("$stty_path <$port -e") ;
    }
    else {    # linux
        my $cc =
          join( " ",
                map { "$_ undef" }
                         qw(eof eol eol2 erase werase kill intr quit susp start stop lnext rprnt flush)
          ) ;
        system(
"$stty_path <$port cs8 clocal -hupcl ignbrk ignpar ispeed $baud ospeed $baud $cc"
        ) ;
        die "$stty_path failed" if $? ;
        system("$stty_path <$port -a") ;
    }

    open( FH, "+>$port" ) or die "Could not open $port: $!\n" ;
    $self->{serialtype} = 'FileHandle' ;
    \*FH ;
}

# -----------------------------------------------------------------------------

=head2 read

  read a number of bytes from the port

=cut

sub read {

    #$self->_read(length)
    #reads packets from whatever you're listening from.
    #length defaults to 1

    my ( $self, $len ) = @_ ;
    $len ||= 1 ;

    $self->serial or die "Read from an uninitialized handle" ;

    # show we are using it
    $self->{activity} = 1 ;

    my $buf ;

    if ( $self->{serialtype} eq 'FileHandle' ) {
        sysread( $self->serial, $buf, $len ) ;
    }
    else {
        ( undef, $buf ) = $self->serial->read($len) ;
    }

    $self->{activity} = 0 ;

    return $buf ;
}

# -----------------------------------------------------------------------------

=head2 write

 write to the device

=cut

sub write {

    #$self->_write(buffer,length)
    #syswrite wrapper for the serial device
    #length defaults to buffer length

    my ( $self, $buf, $len, $offset ) = @_ ;
    $self->connect() or die "Write to an uninitialized handle" ;

    # show we are using it
    $self->{activity} = 1 ;

    $len ||= length($buf) ;

    $self->serial or die "Write to an uninitialized handle" ;

    if ( $self->{serialtype} eq 'FileHandle' ) {
        syswrite( $self->serial, $buf, $len, $offset || 0 ) ;
    }
    else {
        my $out_len = $self->serial->write($buf) ;
        warn "Write incomplete ($len != $out_len)\n" if ( $len != $out_len ) ;
    }
    $self->{activity} = 0 ;
}

# -----------------------------------------------------------------------------

=head2 serial

 get info about the connection

=cut

sub serial { shift->{serial} }

# -----------------------------------------------------------------------------

=head2 verbose

 show verbose reporting

=cut

sub verbose { shift->{verbose} }

# -----------------------------------------------------------------------------

1 ;

__END__

