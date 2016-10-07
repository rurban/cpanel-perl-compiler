package B::C::SaveCOW;

use strict;

use B::C::File qw( const );
use B::C::Helpers qw/cow_strlen_flags/;
use B::C::Save qw/get_max_string_len/;

use Exporter ();
our @ISA = qw(Exporter);

our @EXPORT_OK = qw/savepv/;

my %strtable;

sub savepv {
    my $pv = shift;
    my ( $cstring, $cur, $len, $utf8 ) = cow_strlen_flags($pv);

    return @{ $strtable{$cstring} } if defined $strtable{$cstring};
    
    my $ix = const()->add('FAKE_CONST');
    my $pvsym = sprintf( "cowpv%d", $ix );

    my $max_len = B::C::Save::get_max_string_len();
    if ( $max_len && $cur > $max_len ) {
        my $chars = join ', ', map { cchar $_ } split //, pack( "a*", $pv );
        const()->replace( $ix, sprintf( "Static const char %s[] = { %s };", $pvsym, $chars ) );
        $strtable{$cstring} = [ $pvsym, $cur, $len ];
    }
    else {
        const()->replace( $ix, sprintf( "Static const char %s[] = %s;", $pvsym, $cstring ) );
        $strtable{$cstring} = [ $pvsym, $cur, $len ];
    }
    return ( $pvsym, $cur, $len );    # NOTE: $cur is total size of the perl string. len would be the length of the C string.
}

1;